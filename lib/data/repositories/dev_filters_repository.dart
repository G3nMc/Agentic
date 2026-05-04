import 'dart:convert';
import 'dart:io';

import 'settings_repository.dart';

/// Persists user-configured filesystem filter lists, scoped per working
/// directory so different projects can have independent rules. The four
/// lists drive the orchestrator's discovery tools (list_files /
/// list_files_recursive / search_in_files / find_files); read_file and
/// write_file are intentionally NOT gated by these filters so the model
/// can still operate on a specific path the user mentions.
///
/// Storage: piggy-backs on the existing key/value `settings` table via
/// SettingsRepository. Each list is stored as a JSON-encoded string under
/// a key built from the working directory hash:
///
///   `dev.filters.<sha8>.exclude_dirs`
///   `dev.filters.<sha8>.include_dirs`
///   `dev.filters.<sha8>.exclude_files`
///   `dev.filters.<sha8>.include_files`
///
/// The hash isolates per-project settings without making the keys huge.
class DevFiltersRepository {
  DevFiltersRepository._();

  static final DevFiltersRepository instance = DevFiltersRepository._();

  static const String _kPrefix = 'dev.filters';
  static const String kExcludeDirs = 'exclude_dirs';
  static const String kIncludeDirs = 'include_dirs';
  static const String kExcludeFiles = 'exclude_files';
  static const String kIncludeFiles = 'include_files';

  static const List<String> kAllCategories = <String>[
    kExcludeDirs,
    kIncludeDirs,
    kExcludeFiles,
    kIncludeFiles,
  ];

  /// 8-character hex digest of the absolute, normalised working directory.
  /// FNV-1a 32-bit — stable across runs, no extra dependency, plenty of
  /// distribution for the handful of project folders a single user will
  /// open in this app. (Cryptographic strength isn't needed: this just
  /// namespaces settings keys.)
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
    // Resolve to an absolute, OS-canonical form so different spellings of
    // the same folder map to the same hash.
    try {
      p = Directory(p).absolute.path;
    } catch (_) {
      // Fall through with the raw string — Directory ctor never throws on
      // valid Dart strings, but keep this defensive in case of mocking.
    }
    if (Platform.isWindows) p = p.toLowerCase();
    while (p.endsWith(Platform.pathSeparator)) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _key(String workingDir, String category) =>
      '$_kPrefix.${_hashOf(workingDir)}.$category';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Returns the saved list for [category] (one of the kExclude/kInclude
  /// constants), or an empty list when nothing is saved yet.
  Future<List<String>> getList(String workingDir, String category) async {
    assert(kAllCategories.contains(category),
        'Unknown filter category: $category');
    final raw = await SettingsRepository.instance.get(_key(workingDir, category));
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return [
        for (final item in decoded)
          if (item is String && item.trim().isNotEmpty) item.trim(),
      ];
    } catch (_) {
      return const <String>[];
    }
  }

  /// Loads all four lists for [workingDir]. Used by OrchestratorManager
  /// when writing the filters JSON file the Python side reads at startup.
  Future<Map<String, List<String>>> getAll(String workingDir) async {
    final result = <String, List<String>>{};
    for (final cat in kAllCategories) {
      result[cat] = await getList(workingDir, cat);
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Writes
  // ---------------------------------------------------------------------------

  /// Persists [items] for [category] under [workingDir]. Empty / blank
  /// entries are dropped before save so the on-disk JSON stays clean.
  Future<void> setList(
    String workingDir,
    String category,
    List<String> items,
  ) async {
    assert(kAllCategories.contains(category),
        'Unknown filter category: $category');
    final cleaned = <String>[
      for (final raw in items)
        if (raw.trim().isNotEmpty) raw.trim(),
    ];
    if (cleaned.isEmpty) {
      await SettingsRepository.instance.delete(_key(workingDir, category));
      return;
    }
    await SettingsRepository.instance.set(
      _key(workingDir, category),
      jsonEncode(cleaned),
    );
  }

  /// Convenience: dumps every list for [workingDir] to a JSON object
  /// matching the shape Python's `PathFilter.from_config` expects.
  Future<String> toFiltersJson(String workingDir) async {
    final all = await getAll(workingDir);
    return jsonEncode({
      for (final entry in all.entries) entry.key: entry.value,
    });
  }
}
