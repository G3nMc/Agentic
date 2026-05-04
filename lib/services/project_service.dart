import 'dart:io';
import 'package:file_picker/file_picker.dart';

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
  static const String _settingsKey = 'project_folder';

  static final ProjectService _instance = ProjectService._internal();
  factory ProjectService() => _instance;
  ProjectService._internal();

  String? _currentPath;
  bool _loaded = false;

  /// The folder the orchestrator should target. Falls back to
  /// `Directory.current.path` only until [init] has loaded the persisted
  /// value (or if the user has never picked one).
  String get currentPath => _currentPath ?? Directory.current.path;

  /// True when a folder has been explicitly chosen (and persisted) by the
  /// user. False means the getter is falling back to `Directory.current`,
  /// which is almost certainly not what the user wants.
  bool get hasExplicitFolder => _currentPath != null;

  /// Loads the persisted project folder, if any. Safe to call multiple
  /// times — only the first invocation hits the DB.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    final saved = await SettingsRepository.instance.get(_settingsKey);
    if (saved != null && saved.isNotEmpty && Directory(saved).existsSync()) {
      _currentPath = saved;
    }
  }

  Future<String?> pickProjectFolder() async {
    return await FilePicker.getDirectoryPath();
  }

  /// Sets and persists the project folder. The caller is expected to also
  /// restart the orchestrator so it picks up the new `--base-path`.
  Future<void> setProjectFolder(String path) async {
    _currentPath = path;
    await SettingsRepository.instance.set(_settingsKey, path);
  }
}
