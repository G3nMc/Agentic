import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/conversation.dart';

class ConversationRepository {
  ConversationRepository._();

  static final ConversationRepository instance = ConversationRepository._();

  Future<List<Conversation>> listAll() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "conversations",
      orderBy: "updated_at DESC",
    );
    print('[DEBUG] listAll() returned ${rows.length} conversations');
    return rows.map(Conversation.fromMap).toList();
  }

  Future<Conversation?> getById(String id) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "conversations",
      where: "id = ?",
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Conversation.fromMap(rows.first);
  }

  Future<void> insert(Conversation conversation) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "conversations",
      conversation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateTitle(String id, String title) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      "conversations",
      {"title": title, "updated_at": now},
      where: "id = ?",
      whereArgs: [id],
    );
  }

  Future<void> updateModel(String id, String modelId) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      "conversations",
      {"model_id": modelId, "updated_at": now},
      where: "id = ?",
      whereArgs: [id],
    );
  }

  Future<void> touch(String id) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      "conversations",
      {"updated_at": now},
      where: "id = ?",
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final db = await AppDatabase.instance.database;
    try {
      // Delete messages first (explicit delete, not relying on cascade)
      final deletedMessages = await db.delete("messages", where: "conversation_id = ?", whereArgs: [id]);
      print('[DEBUG] Deleted $deletedMessages messages for conversation $id');

      // Then delete the conversation
      final deletedConv = await db.delete("conversations", where: "id = ?", whereArgs: [id]);
      print('[DEBUG] Deleted $deletedConv conversations with id $id');

      if (deletedConv == 0) {
        print('[DEBUG] WARNING: No conversations were deleted!');
      }
    } catch (e) {
      print('[ERROR] Failed to delete conversation $id: $e');
      rethrow;
    }
  }
}
