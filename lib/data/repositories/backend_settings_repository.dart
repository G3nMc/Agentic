import 'package:sqflite/sqflite.dart';

import '../../services/llm_service.dart';
import '../database/app_database.dart';

class BackendSettingsRepository {
  BackendSettingsRepository._();

  static final BackendSettingsRepository instance = BackendSettingsRepository._();

  static const String _kActive = "active_backend";
  static const String _kLocalUrl = "local_server_url";

  Future<LlmBackend> getActiveBackend() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "backend_settings",
      where: "id = ?",
      whereArgs: [_kActive],
      limit: 1,
    );
    if (rows.isEmpty) return LlmBackend.huggingFace;
    final stored = (rows.first["value"] as String?) ?? "";
    return _parseBackend(stored);
  }

  /// Parse the stored enum string back to an `LlmBackend`.
  /// The previous implementation only checked `contains("local")`, which
  /// silently mapped `orchestrator` back to `huggingFace`.
  LlmBackend _parseBackend(String stored) {
    // Stored as `LlmBackend.huggingFace` / `LlmBackend.local` / `LlmBackend.orchestrator`.
    // Accept either the full enum name or just the variant name.
    final name = stored.contains('.') ? stored.split('.').last : stored;
    switch (name) {
      case 'orchestrator':
        return LlmBackend.orchestrator;
      case 'local':
        return LlmBackend.local;
      case 'huggingFace':
      default:
        return LlmBackend.huggingFace;
    }
  }

  Future<void> setActiveBackend(LlmBackend backend) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "backend_settings",
      {
        "id": _kActive,
        // Use the enum name directly so parsing is symmetric and robust.
        "value": backend.name,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getLocalServerUrl() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "backend_settings",
      where: "id = ?",
      whereArgs: [_kLocalUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first["value"] as String?;
  }

  Future<void> setLocalServerUrl(String url) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "backend_settings",
      {
        "id": _kLocalUrl,
        "value": url,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
