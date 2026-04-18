import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/local_server_config.dart';

class LocalServerConfigRepository {
  LocalServerConfigRepository._();

  static final LocalServerConfigRepository instance = LocalServerConfigRepository._();

  Future<LocalServerConfig?> getByModelId(String modelId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "local_server_configs",
      where: "model_id = ?",
      whereArgs: [modelId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LocalServerConfig.fromMap(rows.first);
  }

  Future<List<LocalServerConfig>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "local_server_configs",
      orderBy: "created_at DESC",
    );
    return rows.map(LocalServerConfig.fromMap).toList();
  }

  Future<void> upsert(LocalServerConfig config) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "local_server_configs",
      config.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String modelId) async {
    final db = await AppDatabase.instance.database;
    await db.delete(
      "local_server_configs",
      where: "model_id = ?",
      whereArgs: [modelId],
    );
  }

  Future<void> setEnabled(String modelId, bool enabled) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      "local_server_configs",
      {"is_enabled": enabled ? 1 : 0},
      where: "model_id = ?",
      whereArgs: [modelId],
    );
  }
}
