import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../models/conversation_turn.dart';

/// Persistence for the per-chat turn journal (`conversation_turns`).
///
/// A row is opened when a prompt is dispatched and closed when the turn
/// finishes. Rows still marked [ConversationTurnStatus.running] at start-up
/// belong to a session that was killed mid-answer: they are reaped as
/// `aborted` so the UI can flag the interrupted turn instead of pretending it
/// never existed.
class ConversationTurnRepository {
  ConversationTurnRepository._();

  static final ConversationTurnRepository instance = ConversationTurnRepository._();

  Future<String> start({
    required String conversationId,
    required String prompt,
    String? backend,
    String? modelId,
  }) async {
    final db = await AppDatabase.instance.database;
    final id = const Uuid().v4();
    await db.insert('conversation_turns', {
      'id': id,
      'conversation_id': conversationId,
      'status': ConversationTurnStatus.running.name,
      'prompt': prompt,
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'ended_at': null,
      'error': null,
      'backend': backend,
      'model_id': modelId,
    });
    return id;
  }

  Future<void> finish(
    String turnId, {
    required ConversationTurnStatus status,
    String? error,
  }) async {
    final db = await AppDatabase.instance.database;
    await db.update(
      'conversation_turns',
      {
        'status': status.name,
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'error': error,
      },
      where: 'id = ?',
      whereArgs: [turnId],
    );
  }

  /// Most recent turn for [conversationId], or null when the chat has none.
  Future<ConversationTurn?> latestForConversation(String conversationId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'conversation_turns',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ConversationTurn.fromMap(rows.first);
  }

  /// Close every row that is still `running` — those belong to a process that
  /// died without completing the turn (app crash, forced quit, kill).
  Future<int> reapRunning() async {
    final db = await AppDatabase.instance.database;
    return db.update(
      'conversation_turns',
      {
        'status': ConversationTurnStatus.aborted.name,
        'ended_at': DateTime.now().millisecondsSinceEpoch,
        'error': 'app terminated',
      },
      where: 'status = ?',
      whereArgs: [ConversationTurnStatus.running.name],
    );
  }
}