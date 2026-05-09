import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/context_summary.dart';

class ContextSummaryRepository {
  ContextSummaryRepository._();

  static final ContextSummaryRepository instance = ContextSummaryRepository._();

  /// Save or update a context summary
  Future<void> save(ContextSummary summary) async {
    final db = await AppDatabase.instance.database;
    
    await db.insert(
      'context_summaries',
      summary.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get context summary by conversation ID
  Future<ContextSummary?> getByConversationId(String conversationId) async {
    final db = await AppDatabase.instance.database;
    
    final maps = await db.query(
      'context_summaries',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    
    if (maps.isEmpty) return null;
    return ContextSummary.fromMap(maps.first);
  }

  /// Delete context summary by conversation ID
  Future<void> deleteByConversationId(String conversationId) async {
    final db = await AppDatabase.instance.database;
    
    await db.delete(
      'context_summaries',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }

  /// Delete all context summaries
  Future<void> deleteAll() async {
    final db = await AppDatabase.instance.database;
    await db.delete('context_summaries');
  }
}