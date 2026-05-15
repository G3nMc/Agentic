import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';

/// Singleton holding the user-selected project folder. The orchestrator's
/// `--base-path` is derived from this — every relative path the model asks
/// to read/write is resolved against it.
///
/// Persisted to the settings table so a folder picked once survives app
/// restarts. Without persistence, a fresh launch falls back to
/// `Directory.current` — which under an Inno Setup install is the install
/// directory (e.g. `%LOCALAPPDATA%\Programs\Agentic`), not the user's project.
class ProjectService {
  static const String _legacySettingsKey = 'project_folder';
  static const String _projectsSettingsKey = 'project_folders';
  static const String _lastProjectSettingsKey = 'last_project_folder';

  static final ProjectService _instance = ProjectService._internal();
  factory ProjectService() => _instance;
  ProjectService._internal();

  String? _currentPath;
  List<String> _projectFolders = const [];
  bool _loaded = false;
  final ValueNotifier<String?> currentPathNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<List<String>> projectFoldersNotifier =
      ValueNotifier<List<String>>(const []);

  /// The folder the orchestrator should target. Falls back to
  /// `Directory.current.path` only until [init] has loaded the persisted
  /// value (or if the user has never picked one).
  String get currentPath => _currentPath ?? Directory.current.path;

  String? get activeProjectKey => _currentPath;

  List<String> get projectFolders => List.unmodifiable(_projectFolders);

  /// True when a folder has been explicitly chosen (and persisted) by the
  /// user. False means the getter is falling back to `Directory.current`,
  /// which is almost certainly not what the user wants.
  bool get hasExplicitFolder => _currentPath != null;

  /// Loads the persisted project folder, if any. Safe to call multiple
  /// times — only the first invocation hits the DB.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    SettingsRepository.projectKeyProvider = () => _currentPath;

    final savedProjectsRaw =
        await SettingsRepository.instance.get(_projectsSettingsKey);
    final projects = <String>[];
    if (savedProjectsRaw != null && savedProjectsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedProjectsRaw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is String) {
              final normalised = normalisePath(item);
              if (normalised.isNotEmpty &&
                  Directory(normalised).existsSync() &&
                  !projects.contains(normalised)) {
                projects.add(normalised);
              }
            }
          }
        }
      } catch (_) {
        // Ignore corrupt project-list settings and fall through to migration.
      }
    }

    final legacy = await SettingsRepository.instance.get(_legacySettingsKey);
    if (legacy != null && legacy.isNotEmpty) {
      final normalised = normalisePath(legacy);
      if (normalised.isNotEmpty &&
          Directory(normalised).existsSync() &&
          !projects.contains(normalised)) {
        projects.add(normalised);
      }
    }

    _projectFolders = projects;
    projectFoldersNotifier.value = List.unmodifiable(_projectFolders);

    final last = await SettingsRepository.instance.get(_lastProjectSettingsKey);
    final preferred = last == null ? null : normalisePath(last);
    if (preferred != null &&
        preferred.isNotEmpty &&
        projects.contains(preferred) &&
        Directory(preferred).existsSync()) {
      _currentPath = preferred;
    } else if (projects.isNotEmpty) {
      _currentPath = projects.first;
    }
    currentPathNotifier.value = _currentPath;
  }

  /// Opens a native folder-picker dialog and returns the chosen path, or null
  /// if the user cancelled. Does NOT persist — call [addProjectFolder] or
  /// [setProjectFolder] afterwards.
  Future<String?> pickProjectFolder() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select project folder',
    );
    if (picked == null || picked.isEmpty) return null;
    return normalisePath(picked);
  }

  Future<void> addProjectFolder(String path, {bool select = true}) async {
    await init();
    final normalised = normalisePath(path);
    if (normalised.isEmpty) return;
    final next = [..._projectFolders];
    if (!next.contains(normalised)) {
      next.add(normalised);
    }
    _projectFolders = next;
    if (select) {
      _currentPath = normalised;
    }
    await _persist();
  }

  /// Sets and persists the project folder. The caller is expected to also
  /// restart the orchestrator so it picks up the new `--base-path`.
  Future<void> setProjectFolder(String path) async {
    await addProjectFolder(path, select: true);
  }

  /// Switch to an already-known project folder. No-op when [path] is already
  /// active. Returns true if a switch occurred.
  Future<bool> selectProjectFolder(String path) async {
    await init();
    final normalised = normalisePath(path);
    if (normalised.isEmpty || !_projectFolders.contains(normalised)) return false;
    if (_currentPath == normalised) return false;
    _currentPath = normalised;
    await _persist();
    return true;
  }

  Future<void> updateProjectFolder(String oldPath, String newPath) async {
    await init();
    final oldNormalised = normalisePath(oldPath);
    final newNormalised = normalisePath(newPath);
    if (newNormalised.isEmpty) return;

    final next = <String>[];
    for (final path in _projectFolders) {
      final candidate = path == oldNormalised ? newNormalised : path;
      if (!next.contains(candidate)) next.add(candidate);
    }
    if (!next.contains(newNormalised)) next.add(newNormalised);
    _projectFolders = next;
    if (_currentPath == oldNormalised) {
      _currentPath = newNormalised;
    }
    await _persist();
  }

  Future<void> removeProjectFolder(String path) async {
    await init();
    final normalised = normalisePath(path);
    _projectFolders = [
      for (final p in _projectFolders)
        if (p != normalised) p,
    ];
    if (_currentPath == normalised) {
      _currentPath = _projectFolders.isNotEmpty ? _projectFolders.first : null;
    }
    await _persist();
  }

  Future<void> _persist() async {
    await SettingsRepository.instance.set(
      _projectsSettingsKey,
      jsonEncode(_projectFolders),
    );
    if (_currentPath == null || _currentPath!.isEmpty) {
      await SettingsRepository.instance.delete(_lastProjectSettingsKey);
    } else {
      await SettingsRepository.instance.set(
        _lastProjectSettingsKey,
        _currentPath!,
      );
      // Keep the legacy key updated so older app builds still reopen the last
      // selected folder.
      await SettingsRepository.instance.set(_legacySettingsKey, _currentPath!);
    }
    projectFoldersNotifier.value = List.unmodifiable(_projectFolders);
    currentPathNotifier.value = _currentPath;
  }

  static String normalisePath(String path) {
    var p = path.trim();
    if (p.isEmpty) return '';
    try {
      p = Directory(p).absolute.path;
    } catch (_) {}
    while (p.length > 1 && p.endsWith(Platform.pathSeparator)) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
