import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

class SettingsRepository {
  SettingsRepository._();

  static final SettingsRepository instance = SettingsRepository._();

  static const String keyHfToken = "hf_token";
  static const String keySelectedModelId = "selected_model_id";

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

  Future<String?> getHfToken() => get(keyHfToken);
  Future<void> setHfToken(String token) => set(keyHfToken, token);

  Future<String?> getSelectedModelId() => get(keySelectedModelId);
  Future<void> setSelectedModelId(String modelId) => set(keySelectedModelId, modelId);
}
