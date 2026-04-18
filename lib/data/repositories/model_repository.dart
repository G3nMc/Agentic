import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/hf_model.dart';

class ModelRepository {
  ModelRepository._();

  static final ModelRepository instance = ModelRepository._();

  Future<List<HfModel>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "models",
      orderBy: "is_favorite DESC, created_at DESC",
    );
    return rows.map(HfModel.fromMap).toList();
  }

  Future<HfModel?> getById(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "models",
      where: "id = ?",
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HfModel.fromMap(rows.first);
  }

  Future<void> upsert(HfModel model) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "models",
      model.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.database;
    await db.delete("models", where: "id = ?", whereArgs: [id]);
  }

  Future<void> setFavorite(String id, bool isFavorite) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      "models",
      {"is_favorite": isFavorite ? 1 : 0},
      where: "id = ?",
      whereArgs: [id],
    );
  }
}
