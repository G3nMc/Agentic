import 'package:sqflite/sqflite.dart';

import '../../services/secure_storage_service.dart';
import '../database/app_database.dart';

class SettingsRepository {
  SettingsRepository._();

  static final SettingsRepository instance = SettingsRepository._();

  /// Provided by ProjectService after startup. Generic settings remain global;
  /// callers that need per-project state use the explicit `*ForProject`
  /// helpers below.
  static String? Function()? projectKeyProvider;

  static const String keyHfToken = "hf_token";
  static const String keySelectedModelId = "selected_model_id";

  /// Absolute path to the Flutter SDK root (the directory that contains
  /// `bin/flutter`). When set, the orchestrator subprocess is launched
  /// with `<flutter_sdk_path>/bin` prepended to PATH so tools like
  /// `flutter analyze` resolve without depending on the user's shell PATH.
  static const String keyFlutterSdkPath = "flutter_sdk_path";

  /// Absolute path to the Python interpreter used to launch the
  /// orchestrator subprocess. When set, overrides the platform default
  /// (`python` on Windows, `python3` elsewhere). Useful when the PATH
  /// Python is the wrong version or missing dependencies.
  static const String keyPythonPath = "python_path";

  Future<String?> getFlutterSdkPath() => get(keyFlutterSdkPath);
  Future<void> setFlutterSdkPath(String path) => set(keyFlutterSdkPath, path);
  Future<void> clearFlutterSdkPath() => delete(keyFlutterSdkPath);

  Future<String?> getPythonPath() => get(keyPythonPath);
  Future<void> setPythonPath(String path) => set(keyPythonPath, path);
  Future<void> clearPythonPath() => delete(keyPythonPath);

  /// Generic methods for non-sensitive settings still using the DB
  Future<String?> get(String key) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "settings",
      columns: ["value"],
      where: "key = ?",
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first["value"] as String?;
  }

  Future<void> set(String key, String value) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "settings",
      {"key": key, "value": value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String key) async {
    final db = await AppDatabase.instance.database;
    await db.delete("settings", where: "key = ?", whereArgs: [key]);
  }

  Future<String?> getForProject(String key) async {
    final scoped = _projectScopedKey(key);
    if (scoped == key) return get(key);
    final scopedValue = await get(scoped);
    return (scopedValue ?? get(key)) as Future<String?>;
  }

  Future<void> setForProject(String key, String value) {
    return set(_projectScopedKey(key), value);
  }

  Future<void> deleteForProject(String key) {
    return delete(_projectScopedKey(key));
  }

  String _projectScopedKey(String key) {
    final projectKey = projectKeyProvider?.call();
    if (projectKey == null || projectKey.trim().isEmpty) return key;
    return 'project.$projectKey::$key';
  }

  // --- Secure Storage Delegations ---

  Future<String?> getHfToken() => SecureStorageService.instance.getToken();
  Future<void> setHfToken(String token) => SecureStorageService.instance.saveToken(token);

  Future<String?> getSelectedModelId() async {
    final scoped = await getForProject(keySelectedModelId);
    if (scoped != null) return scoped;
    return SecureStorageService.instance.getModelId();
  }

  Future<void> setSelectedModelId(String modelId) async {
    await setForProject(keySelectedModelId, modelId);
    await SecureStorageService.instance.saveModelId(modelId);
  }
}
