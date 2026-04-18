import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/message.dart';

class MessageRepository {
  MessageRepository._();

  static final MessageRepository instance = MessageRepository._();

  Future<List<ChatMessage>> listByConversation(String conversationId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "messages",
      where: "conversation_id = ?",
      whereArgs: [conversationId],
      orderBy: "created_at ASC",
    );
    return rows.map(ChatMessage.fromMap).toList();
  }

  Future<void> insert(ChatMessage message) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "messages",
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteByConversation(String conversationId) async {
    final db = await AppDatabase.instance.database;
    await db.delete(
      "messages",
      where: "conversation_id = ?",
      whereArgs: [conversationId],
    );
  }

  Future<void> deleteById(String id) async {
    final db = await AppDatabase.instance.database;
    await db.delete("messages", where: "id = ?", whereArgs: [id]);
  }
}
