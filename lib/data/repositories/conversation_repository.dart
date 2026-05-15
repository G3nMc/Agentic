import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import '../models/conversation.dart';
import '../../services/project_service.dart';

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

  Future<List<Conversation>> listByBackend(String backend) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "conversations",
      where: "backend = ?",
      whereArgs: [backend],
      orderBy: "updated_at DESC",
    );
    return rows.map(Conversation.fromMap).toList();
  }

  Future<void> updateBackend(String id, String backend) async {
    final db = await AppDatabase.instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      "conversations",
      {"backend": backend, "updated_at": now},
      where: "id = ?",
      whereArgs: [id],
    );
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

    // Best-effort: also remove the per-conversation Team Mode folder so
    // boards/artifacts/worker logs don't pile up after the chat is gone.
    // Failure is non-fatal — the chat row is already gone and we don't
    // want a filesystem error to look like a delete failure to the UI.
    await _deleteTeamSessionFolder(id);

    // Same for the orchestrator log file written by OrchestratorManager.
    await _deleteOrchestratorLogFile(id);
  }

  /// Remove `<project>/.agent/team/<conversation_id>/` if it exists.
  /// Mirrors `bin/agent/team/paths.py:delete_session()` on the Python side.
  Future<void> _deleteTeamSessionFolder(String conversationId) async {
    if (conversationId.isEmpty) return;
    // Apply the same sanitization the Python side uses — refuse to
    // remove anything outside a sane single-segment session id, and
    // never wipe the legacy `_default` folder via this path.
    final safeRe = RegExp(r'^[A-Za-z0-9._-]+$');
    if (!safeRe.hasMatch(conversationId)) return;
    if (conversationId == '_default') return;

    try {
      final basePath = ProjectService().currentPath;
      final sep = Platform.pathSeparator;
      final folder = Directory(
        '$basePath$sep.agent${sep}team$sep$conversationId',
      );
      if (await folder.exists()) {
        await folder.delete(recursive: true);
        print('[DEBUG] Removed team folder for conversation $conversationId');
      }
    } catch (e) {
      print('[DEBUG] Team folder cleanup skipped for $conversationId: $e');
    }
  }

  /// Remove `<project>/logs/<conversation_id>.log` if it exists.
  /// Called from [delete] so chat deletion also cleans up the orchestrator log.
  Future<void> _deleteOrchestratorLogFile(String conversationId) async {
    if (conversationId.isEmpty) return;
    final safeRe = RegExp(r'^[A-Za-z0-9._-]+$');
    if (!safeRe.hasMatch(conversationId)) return;
    if (conversationId == '_default') return;

    try {
      final basePath = ProjectService().currentPath;
      final sep = Platform.pathSeparator;
      final file = File(
        '$basePath${sep}logs$sep$conversationId.log',
      );
      if (await file.exists()) {
        await file.delete();
        print('[DEBUG] Removed orchestrator log for conversation $conversationId');
      }
    } catch (e) {
      print('[DEBUG] Orchestrator log cleanup skipped for $conversationId: $e');
    }
  }
}
