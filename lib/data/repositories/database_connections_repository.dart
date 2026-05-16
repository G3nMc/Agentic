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
/// indicator (mariadb or sqlite).
///
/// Storage: uses the existing key/value `settings` table via
/// SettingsRepository. The connections are stored as a JSON-encoded list
/// under the key `dev.database_connections`. Each entry has:
///   - key: the connection name (used to reference it in db_query tool)
///   - value: the connection string (MariaDB) or file path (SQLite)
///   - type: 'mariadb' or 'sqlite'
class DatabaseConnectionsRepository {
  DatabaseConnectionsRepository._();

  static final DatabaseConnectionsRepository instance =
      DatabaseConnectionsRepository._();

  static const String _kConnectionsKey = 'dev.database_connections';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns all configured database connections.
  Future<List<DatabaseConnection>> getAll() async {
    final raw = await SettingsRepository.instance.get(_kConnectionsKey);
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

  /// Returns a specific connection by key, or null if not found.
  Future<DatabaseConnection?> getByKey(String key) async {
    final all = await getAll();
    try {
      return all.firstWhere((c) => c.key == key);
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Persists the entire list of connections.
  Future<void> setAll(List<DatabaseConnection> connections) async {
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
      await SettingsRepository.instance.delete(_kConnectionsKey);
      return;
    }
    await SettingsRepository.instance.set(
      _kConnectionsKey,
      jsonEncode([for (final c in cleaned) c.toJson()]),
    );
  }

  /// Adds or updates a single connection.
  Future<void> upsert(DatabaseConnection connection) async {
    final all = await getAll();
    final existingIndex = all.indexWhere((c) => c.key == connection.key);
    if (existingIndex >= 0) {
      all[existingIndex] = connection;
    } else {
      all.add(connection);
    }
    await setAll(all);
  }

  /// Removes a connection by key.
  Future<void> removeByKey(String key) async {
    final all = await getAll();
    final filtered = all.where((c) => c.key != key).toList();
    await setAll(filtered);
  }

  /// Serialise the configured connections as a JSON array and write it to
  /// [path], so the Python orchestrator can load them via
  /// `--db-connections-config`. The file always exists after this call —
  /// even with zero connections we write `[]` so the orchestrator's loader
  /// has a definitive answer instead of falling back to "file not found".
  Future<void> writeConfigJson(String path) async {
    final all = await getAll();
    final payload = jsonEncode([for (final c in all) c.toJson()]);
    await File(path).writeAsString(payload, flush: true);
  }
}
