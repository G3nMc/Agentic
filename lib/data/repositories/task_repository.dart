import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/conversation_task.dart';

/// Persistence for the TASK COMPLIANCE task list, keyed by conversation.
class TaskRepository {
  TaskRepository._();

  static final TaskRepository instance = TaskRepository._();

  /// Load every task that belongs to ``conversationId`` ordered by the
  /// model-assigned ``task_id``. Empty list when the conversation never
  /// emitted a plan (free-form / OPEN mode chats).
  Future<List<ConversationTask>> listByConversation(String conversationId) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'conversation_tasks',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'task_id ASC',
    );
    return rows.map(ConversationTask.fromMap).toList(growable: false);
  }

  /// Persist a newly proposed plan: overwrites the existing rows for
  /// the conversation. Called when the orchestrator emits a
  /// ``tasks_proposed`` event (either the very first plan or a replan).
  Future<void> replacePlan(
    String conversationId,
    List<ConversationTask> tasks,
  ) async {
    final db = await AppDatabase.instance.database;
    final batch = db.batch();
    batch.delete(
      'conversation_tasks',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    for (final t in tasks) {
      batch.insert(
        'conversation_tasks',
        t.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Apply a ``task_status`` event. Updates the matching row's status,
  /// note, timestamps and iteration counter. Silently ignored when no
  /// such ``task_id`` exists in the plan.
  Future<void> applyStatusUpdate({
    required String conversationId,
    required int taskId,
    required TaskStatus status,
    String? note,
    int? now,
  }) async {
    final db = await AppDatabase.instance.database;
    final ts = now ?? DateTime.now().millisecondsSinceEpoch;
    final updates = <String, Object?>{
      'status': status.value,
      'note': note ?? '',
      'updated_at': ts,
    };
    if (status == TaskStatus.inProgress) {
      updates['started_at'] = ts;
    }
    if (status.isTerminal) {
      updates['completed_at'] = ts;
    }
    await db.update(
      'conversation_tasks',
      updates,
      where: 'conversation_id = ? AND task_id = ?',
      whereArgs: [conversationId, taskId],
    );
  }

  /// Increment the iteration counter for a task by one. Useful so the
  /// UI can show how many model turns the current task consumed.
  Future<void> bumpIterations({
    required String conversationId,
    required int taskId,
  }) async {
    final db = await AppDatabase.instance.database;
    await db.rawUpdate(
      'UPDATE conversation_tasks '
      'SET iterations_used = iterations_used + 1, updated_at = ? '
      'WHERE conversation_id = ? AND task_id = ?',
      [DateTime.now().millisecondsSinceEpoch, conversationId, taskId],
    );
  }

  /// Delete all tasks for a conversation (called when the user deletes
  /// the chat — also handled by ON DELETE CASCADE, kept here for
  /// explicit "Reset plan" semantics in the UI).
  Future<void> deleteByConversation(String conversationId) async {
    final db = await AppDatabase.instance.database;
    await db.delete(
      'conversation_tasks',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
  }
}
