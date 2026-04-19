import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../../services/secure_storage_service.dart';

class SettingsRepository {
  SettingsRepository._();

  static final SettingsRepository instance = SettingsRepository._();

  static const String keyHfToken = "hf_token";
  static const String keySelectedModelId = "selected_model_id";

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

  // --- Secure Storage Delegations ---

  Future<String?> getHfToken() => SecureStorageService.instance.getToken();
  Future<void> setHfToken(String token) => SecureStorageService.instance.saveToken(token);

  Future<String?> getSelectedModelId() => SecureStorageService.instance.getModelId();
  Future<void> setSelectedModelId(String modelId) => SecureStorageService.instance.saveModelId(modelId);
}