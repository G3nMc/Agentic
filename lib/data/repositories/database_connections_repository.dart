import 'dart:convert';
import 'dart:io';

import 'settings_repository.dart';

/// Represents a single database connection configuration.
class DatabaseConnection {
  final String key;
  final String value;
  final String type; // 'mariadb', 'sqlserver', or 'sqlite'

  DatabaseConnection({
    required this.key,
    required this.value,
    required this.type,
  });

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        'type': type,
      };

  static DatabaseConnection fromJson(Map<String, dynamic> json) =>
      DatabaseConnection(
        key: json['key'] as String,
        value: json['value'] as String,
        type: json['type'] as String,
      );
}

/// Persists user-configured database connection strings/paths for the
/// database tool. Connections are stored as key-value pairs with a type
/// indicator (mariadb, sqlserver, or sqlite).
///
/// Storage: uses the existing key/value `settings` table via
/// SettingsRepository. Connections are scoped per working directory using
/// an 8-character hash of the absolute, normalised path, so different
/// projects can have independent connection sets. The key pattern is:
///
///   `dev.database_connections.<sha8>`
///
/// Each entry has:
///   - key: the connection name (used to reference it in db_query tool)
///   - value: the connection string (MariaDB/SQL Server) or file path (SQLite)
///   - type: 'mariadb', 'sqlserver', or 'sqlite'
class DatabaseConnectionsRepository {
  DatabaseConnectionsRepository._();

  static final DatabaseConnectionsRepository instance =
      DatabaseConnectionsRepository._();

  static const String _kPrefix = 'dev.database_connections';

  /// 8-character hex digest of the absolute, normalised working directory.
  /// FNV-1a 32-bit — stable across runs, no extra dependency.
  String _hashOf(String workingDir) {
    final norm = _normalise(workingDir);
    final bytes = utf8.encode(norm);
    int hash = 0x811C9DC5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _normalise(String workingDir) {
    var p = workingDir.trim();
    if (p.isEmpty) return p;
    try {
      p = Directory(p).absolute.path;
    } catch (_) {
      // Fall through with the raw string.
    }
    if (Platform.isWindows) p = p.toLowerCase();
    while (p.endsWith(Platform.pathSeparator)) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _key(String workingDir) => '$_kPrefix.${_hashOf(workingDir)}';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns all configured database connections for [workingDir].
  Future<List<DatabaseConnection>> getAll(String workingDir) async {
    final raw = await SettingsRepository.instance.get(_key(workingDir));
    if (raw == null || raw.isEmpty) return const <DatabaseConnection>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <DatabaseConnection>[];
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>)
            DatabaseConnection.fromJson(item),
      ];
    } catch (_) {
      return const <DatabaseConnection>[];
    }
  }

  /// Returns a specific connection by key for [workingDir], or null if not found.
  Future<DatabaseConnection?> getByKey(String workingDir, String key) async {
    final all = await getAll(workingDir);
    try {
      return all.firstWhere((c) => c.key == key);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Persists the entire list of connections for [workingDir].
  Future<void> setAll(String workingDir, List<DatabaseConnection> connections) async {
    final cleaned = <DatabaseConnection>[
      for (final c in connections)
        if (c.key.trim().isNotEmpty && c.value.trim().isNotEmpty)
          DatabaseConnection(
            key: c.key.trim(),
            value: c.value.trim(),
            type: c.type,
          ),
    ];
    if (cleaned.isEmpty) {
      await SettingsRepository.instance.delete(_key(workingDir));
      return;
    }
    await SettingsRepository.instance.set(
      _key(workingDir),
      jsonEncode([for (final c in cleaned) c.toJson()]),
    );
  }

  /// Adds or updates a single connection for [workingDir].
  Future<void> upsert(String workingDir, DatabaseConnection connection) async {
    final all = await getAll(workingDir);
    final existingIndex = all.indexWhere((c) => c.key == connection.key);
    if (existingIndex >= 0) {
      all[existingIndex] = connection;
    } else {
      all.add(connection);
    }
    await setAll(workingDir, all);
  }

  /// Removes a connection by key for [workingDir].
  Future<void> removeByKey(String workingDir, String key) async {
    final all = await getAll(workingDir);
    final filtered = all.where((c) => c.key != key).toList();
    await setAll(workingDir, filtered);
  }

  /// Serialise the configured connections for [workingDir] as a JSON array
  /// and write it to [path], so the Python orchestrator can load them via
  /// `--db-connections-config`. The file always exists after this call —
  /// even with zero connections we write `[]` so the orchestrator's loader
  /// has a definitive answer instead of falling back to "file not found".
  Future<void> writeConfigJson(String path, {required String workingDir}) async {
    final all = await getAll(workingDir);
    final payload = jsonEncode([for (final c in all) c.toJson()]);
    await File(path).writeAsString(payload, flush: true);
  }
}
