import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../services/llm_service.dart';
import '../database/app_database.dart';

class BackendSettingsRepository {
  BackendSettingsRepository._();

  static final BackendSettingsRepository instance = BackendSettingsRepository._();

  static const String _kActive = "active_backend";
  static const String _kLocalUrl = "local_server_url";
  static const String _kOllamaUrl = "ollama_base_url";
  static const String _kOllamaModel = "ollama_model";
  static const String _kOllamaPythonBridgeUrl = "ollama_python_bridge_url";
  static const String _kOllamaTemperature = "ollama_temperature";
  static const String _kOllamaNumPredict = "ollama_num_predict";
  static const String _kOllamaNumCtx = "ollama_num_ctx";
  static const String _kOllamaApiKey = "ollama_api_key";
  static const String _kGroqApiKey = "groq_api_key";
  static const String _kGroqModel = "groq_model";
  static const String _kGroqTemperature = "groq_temperature";
  static const String _kGroqMaxTokens = "groq_max_tokens";

  static const double defaultGroqTemperature = 0.7;
  static const int defaultGroqMaxTokens = 4096;

  // Defaults kept in sync with bin/orchestrator.py. Small enough for
  // phi3:mini to stay responsive but big enough for real coding tasks.
  static const double defaultOllamaTemperature = 0.2;
  static const int defaultOllamaNumPredict = 2048;
  static const int defaultOllamaNumCtx = 4096;

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
    return parseBackend(stored);
  }

  /// Parse the stored enum string back to an `LlmBackend`.
  /// The previous implementation only checked `contains("local")`, which
  /// silently mapped `orchestrator` back to `huggingFace`.
  @visibleForTesting
  LlmBackend parseBackend(String stored) {
    // Stored as `LlmBackend.<variant>` (legacy) or just `<variant>` (current).
    // Accept both shapes.
    final name = stored.contains('.') ? stored.split('.').last : stored;
    switch (name) {
      case 'orchestrator':
        return LlmBackend.orchestrator;
      case 'local':
        return LlmBackend.local;
      case 'ollama':
        return LlmBackend.ollama;
      case 'ollamaPython':
        return LlmBackend.ollamaPython;
      case 'ollamaOrchestrator':
        return LlmBackend.ollamaOrchestrator;
      case 'groq':
        return LlmBackend.groq;
      case 'groqOrchestrator':
        return LlmBackend.groqOrchestrator;
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

  // ---------------------------------------------------------------------------
  // Ollama settings
  // ---------------------------------------------------------------------------

  Future<String?> getOllamaBaseUrl() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "backend_settings",
      where: "id = ?",
      whereArgs: [_kOllamaUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first["value"] as String?;
  }

  Future<void> setOllamaBaseUrl(String url) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "backend_settings",
      {"id": _kOllamaUrl, "value": url},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getOllamaModel() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "backend_settings",
      where: "id = ?",
      whereArgs: [_kOllamaModel],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first["value"] as String?;
  }

  Future<void> setOllamaModel(String name) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "backend_settings",
      {"id": _kOllamaModel, "value": name},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<double> getOllamaTemperature() async {
    final v = await _readString(_kOllamaTemperature);
    return double.tryParse(v ?? '') ?? defaultOllamaTemperature;
  }

  Future<void> setOllamaTemperature(double value) =>
      _writeString(_kOllamaTemperature, value.toString());

  Future<int> getOllamaNumPredict() async {
    final v = await _readString(_kOllamaNumPredict);
    return int.tryParse(v ?? '') ?? defaultOllamaNumPredict;
  }

  Future<void> setOllamaNumPredict(int value) =>
      _writeString(_kOllamaNumPredict, value.toString());

  Future<int> getOllamaNumCtx() async {
    final v = await _readString(_kOllamaNumCtx);
    return int.tryParse(v ?? '') ?? defaultOllamaNumCtx;
  }

  Future<void> setOllamaNumCtx(int value) =>
      _writeString(_kOllamaNumCtx, value.toString());

  /// API key for cloud-hosted Ollama-compatible endpoints.
  /// Empty / null means local daemon with no auth.
  Future<String?> getOllamaApiKey() => _readString(_kOllamaApiKey);
  Future<void> setOllamaApiKey(String key) =>
      _writeString(_kOllamaApiKey, key);

  // ---------------------------------------------------------------------------
  // Groq settings
  // ---------------------------------------------------------------------------

  Future<String?> getGroqApiKey() => _readString(_kGroqApiKey);
  Future<void> setGroqApiKey(String key) => _writeString(_kGroqApiKey, key);

  Future<String?> getGroqModel() => _readString(_kGroqModel);
  Future<void> setGroqModel(String model) => _writeString(_kGroqModel, model);

  Future<double> getGroqTemperature() async {
    final v = await _readString(_kGroqTemperature);
    return double.tryParse(v ?? '') ?? defaultGroqTemperature;
  }
  Future<void> setGroqTemperature(double v) =>
      _writeString(_kGroqTemperature, v.toString());

  Future<int> getGroqMaxTokens() async {
    final v = await _readString(_kGroqMaxTokens);
    return int.tryParse(v ?? '') ?? defaultGroqMaxTokens;
  }
  Future<void> setGroqMaxTokens(int v) =>
      _writeString(_kGroqMaxTokens, v.toString());

  Future<String?> _readString(String key) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "backend_settings",
      where: "id = ?",
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first["value"] as String?;
  }

  Future<void> _writeString(String key, String value) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "backend_settings",
      {"id": key, "value": value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> getOllamaPythonBridgeUrl() async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      "backend_settings",
      where: "id = ?",
      whereArgs: [_kOllamaPythonBridgeUrl],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first["value"] as String?;
  }

  Future<void> setOllamaPythonBridgeUrl(String url) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      "backend_settings",
      {"id": _kOllamaPythonBridgeUrl, "value": url},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
