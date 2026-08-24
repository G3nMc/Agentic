import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../data/repositories/settings_repository.dart';

/// Singleton holding the user-selected project folders.
///
/// Internal paths always remain native to the current OS so File/Directory
/// APIs keep working correctly. Paths exposed to the orchestrator are always
/// converted to Linux-style paths.
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

  final ValueNotifier<List<String>> projectFoldersNotifier = ValueNotifier<List<String>>(const []);

  /// Converts a Windows path to a Linux-style path.
  ///
  /// Example:
  /// C:\Users\Gentian\AsPro\RED
  /// -> /Users/Gentian/AsPro/RED
  static String windowsToLinuxPath(String path) {
    if (path.isEmpty) return path;

    var result = path.replaceAll('\\', '/');

    final match = RegExp(r'^[A-Za-z]:/(.*)$').firstMatch(result);
    if (match != null) {
      result = '/${match.group(1)}';
    }

    return result;
  }

  /// The active project path exposed to the orchestrator.
  ///
  /// Always returned as Linux-style path.
  String get currentPath => _currentPath ?? Directory.current.path;

  /// The active project key exposed as Linux-style path.
  String? get activeProjectKey => _currentPath;

  /// Project folders exposed as Linux-style paths.
  List<String> get projectFolders => List.unmodifiable(_projectFolders);

  /// True when a folder has been explicitly selected.
  bool get hasExplicitFolder => _currentPath != null;

  /// Loads persisted project folders.
  Future<void> init() async {
    if (_loaded) return;

    _loaded = true;

    SettingsRepository.projectKeyProvider = () => _currentPath;

    final savedProjectsRaw = await SettingsRepository.instance.get(_projectsSettingsKey);

    final projects = <String>[];

    if (savedProjectsRaw != null && savedProjectsRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(savedProjectsRaw);

        if (decoded is List) {
          for (final item in decoded) {
            if (item is String) {
              final normalised = normalisePath(item);

              if (normalised.isNotEmpty && Directory(normalised).existsSync() && !projects.contains(normalised)) {
                projects.add(normalised);
              }
            }
          }
        }
      } catch (_) {
        // Ignore corrupt project-list settings.
      }
    }

    final legacy = await SettingsRepository.instance.get(_legacySettingsKey);

    if (legacy != null && legacy.isNotEmpty) {
      final normalised = normalisePath(legacy);

      if (normalised.isNotEmpty && Directory(normalised).existsSync() && !projects.contains(normalised)) {
        projects.add(normalised);
      }
    }

    _projectFolders = projects;

    final last = await SettingsRepository.instance.get(_lastProjectSettingsKey);

    final preferred = last == null ? null : normalisePath(last);

    if (preferred != null && preferred.isNotEmpty && projects.contains(preferred) && Directory(preferred).existsSync()) {
      _currentPath = preferred;
    } else if (projects.isNotEmpty) {
      _currentPath = projects.first;
    }

    _updateNotifiers();
  }

  /// Opens the native folder-picker dialog.
  ///
  /// Returns a native OS path. The path is converted to Linux style only
  /// when exposed through the service.
  Future<String?> pickProjectFolder() async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select project folder',
    );

    if (picked == null || picked.isEmpty) return null;

    return normalisePath(picked);
  }

  Future<void> addProjectFolder(
    String path, {
    bool select = true,
  }) async {
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

  Future<void> setProjectFolder(String path) async {
    await addProjectFolder(path, select: true);
  }

  Future<bool> selectProjectFolder(String path) async {
    await init();

    final normalised = normalisePath(path);

    if (normalised.isEmpty || !_projectFolders.contains(normalised)) {
      return false;
    }

    if (_currentPath == normalised) {
      return false;
    }

    _currentPath = normalised;

    await _persist();

    return true;
  }

  Future<void> updateProjectFolder(
    String oldPath,
    String newPath,
  ) async {
    await init();

    final oldNormalised = normalisePath(oldPath);
    final newNormalised = normalisePath(newPath);

    if (newNormalised.isEmpty) return;

    final next = <String>[];

    for (final path in _projectFolders) {
      final candidate = path == oldNormalised ? newNormalised : path;

      if (!next.contains(candidate)) {
        next.add(candidate);
      }
    }

    if (!next.contains(newNormalised)) {
      next.add(newNormalised);
    }

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
      await SettingsRepository.instance.delete(
        _lastProjectSettingsKey,
      );
    } else {
      await SettingsRepository.instance.set(
        _lastProjectSettingsKey,
        _currentPath!,
      );

      await SettingsRepository.instance.set(
        _legacySettingsKey,
        _currentPath!,
      );
    }

    _updateNotifiers();
  }

  void _updateNotifiers() {
    currentPathNotifier.value = _currentPath;

    projectFoldersNotifier.value = List.unmodifiable(
      _projectFolders,
    );
  }

  /// Normalises a path while preserving the native OS path format.
  ///
  /// This method must NOT convert to Linux format because the returned value
  /// is used with Directory/File APIs.
  static String normalisePath(String path) {
    var p = path.trim();

    if (p.isEmpty) return '';

    try {
      p = Directory(p).absolute.path;
    } catch (_) {}

    while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
      p = p.substring(0, p.length - 1);
    }

    return p;
  }
}
