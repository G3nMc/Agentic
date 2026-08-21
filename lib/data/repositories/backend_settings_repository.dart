import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../services/llm_service.dart';
import '../../services/project_service.dart';
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
  static const String _kOllamaAutoNumCtx = "ollama_auto_num_ctx";
  static const String _kOllamaApiKey = "ollama_api_key";
  static const String _kGroqApiKey = "groq_api_key";
  static const String _kGroqModel = "groq_model";
  static const String _kGroqTemperature = "groq_temperature";
  static const String _kGroqMaxTokens = "groq_max_tokens";
  static const String _kGroqTpmLimit = "groq_tpm_limit";

  static const String _kGeminiApiKey = "gemini_api_key";
  static const String _kGeminiModel = "gemini_model";
  static const String _kGeminiTemperature = "gemini_temperature";
  static const String _kGeminiMaxTokens = "gemini_max_tokens";
  static const String _kGeminiModels = "gemini_models";
  static const String _kGeminiTpmLimit = "gemini_tpm_limit";

  static const String _kOpenRouterApiKey = "openrouter_api_key";
  static const String _kOpenRouterModel = "openrouter_model";
  static const String _kOpenRouterTemperature = "openrouter_temperature";
  static const String _kOpenRouterMaxTokens = "openrouter_max_tokens";
  static const String _kOpenRouterContextLimit = "openrouter_context_limit";
  static const String _kOpenRouterTpmLimit = "openrouter_tpm_limit";

  static const String _kGithubApiKey = "github_api_key";
  static const String _kGithubModel = "github_model";
  static const String _kGithubTemperature = "github_temperature";
  static const String _kGithubMaxTokens = "github_max_tokens";
  static const String _kGithubTpmLimit = "github_tpm_limit";
  static const String _kGithubDisableTools = "github_disable_tools";

  // /api/generate backend (custom Ollama-compatible endpoint)
  static const String _kGenerateBaseUrl = "generate_base_url";
  static const String _kGenerateModel = "generate_model";
  static const String _kGenerateTemperature = "generate_temperature";
  static const String _kGenerateNumPredict = "generate_num_predict";
  static const String _kGenerateNumCtx = "generate_num_ctx";
  static const String _kGenerateApiKey = "generate_api_key";
  static const String _kGenerateThinking = "generate_thinking";

  static const double defaultGenerateTemperature = 0.7;
  static const int defaultGenerateNumPredict = 2048;
  static const int defaultGenerateNumCtx = 4096;

  static const double defaultGroqTemperature = 0.7;
  static const int defaultGroqMaxTokens = 4096;

  static const String defaultGeminiModel = "gemini-2.5-flash";
  static const double defaultGeminiTemperature = 0.2;
  static const int defaultGeminiMaxTokens = 2048;
  static const List<String> defaultGeminiModels = [
    'gemini-2.5-flash',
    'gemini-2.5-pro',
    'gemini-2.5-flash-lite',
  ];

  static const double defaultOpenRouterTemperature = 0.7;
  static const int defaultOpenRouterMaxTokens = 4096;

  static const double defaultGithubTemperature = 0.7;
  static const int defaultGithubMaxTokens = 4096;

  // Defaults kept in sync with bin/orchestrator.py. Small enough for
  // phi3:mini to stay responsive but big enough for real coding tasks.
  static const double defaultOllamaTemperature = 0.2;
  static const int defaultOllamaNumPredict = 2048;
  static const int defaultOllamaNumCtx = 4096;

  Future<LlmBackend> getActiveBackend() async {
    final stored = await _readString(_kActive) ?? "";
    // Non-orchestrator backends are no longer exposed in the UI —
    // coerce them to their closest orchestrator equivalent so an
    // existing stored value doesn't break the dropdown.
    return _toOrchestratorVariant(parseBackend(stored));
  }

  /// Map direct backends to their orchestrator-backed equivalent.
  /// Orchestrator variants are passed through unchanged.
  LlmBackend _toOrchestratorVariant(LlmBackend b) {
    switch (b) {
      case LlmBackend.huggingFace:
      case LlmBackend.local:
        return LlmBackend.orchestrator;
      case LlmBackend.ollama:
      case LlmBackend.ollamaPython:
      case LlmBackend.ollamaGenerate:
        return LlmBackend.ollamaOrchestrator;
      case LlmBackend.groq:
        return LlmBackend.groqOrchestrator;
      case LlmBackend.openRouter:
        return LlmBackend.openRouterOrchestrator;
      case LlmBackend.orchestrator:
      case LlmBackend.ollamaOrchestrator:
      case LlmBackend.groqOrchestrator:
      case LlmBackend.geminiOrchestrator:
      case LlmBackend.openRouterOrchestrator:
      case LlmBackend.githubOrchestrator:
        return b;
    }
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
      case 'geminiOrchestrator':
        return LlmBackend.geminiOrchestrator;
      case 'openRouter':
        return LlmBackend.openRouter;
      case 'openRouterOrchestrator':
        return LlmBackend.openRouterOrchestrator;
      case 'githubOrchestrator':
        return LlmBackend.githubOrchestrator;
      case 'ollamaGenerate':
        return LlmBackend.ollamaGenerate;
      case 'huggingFace':
      default:
        return LlmBackend.huggingFace;
    }
  }

  Future<void> setActiveBackend(LlmBackend backend) async {
    // Use the enum name directly so parsing is symmetric and robust.
    await _writeString(_kActive, backend.name);
  }

  Future<String?> getLocalServerUrl() => _readString(_kLocalUrl);

  Future<void> setLocalServerUrl(String url) => _writeString(_kLocalUrl, url);

  // ---------------------------------------------------------------------------
  // Ollama settings
  // ---------------------------------------------------------------------------

  Future<String?> getOllamaBaseUrl() => _readString(_kOllamaUrl);

  Future<void> setOllamaBaseUrl(String url) => _writeString(_kOllamaUrl, url);

  Future<String?> getOllamaModel() => _readString(_kOllamaModel);

  Future<void> setOllamaModel(String name) => _writeString(_kOllamaModel, name);

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

  /// Auto-calibrate the history budget from the model's first API
  /// response. When ON, the orchestrator reads the actual
  /// prompt_eval_count and clamps the internal history token budget
  /// to that real value. Defaults to false.
  Future<bool> getOllamaAutoNumCtx() async {
    final v = await _readString(_kOllamaAutoNumCtx);
    return (v ?? '').toLowerCase() == 'true';
  }
  Future<void> setOllamaAutoNumCtx(bool value) =>
      _writeString(_kOllamaAutoNumCtx, value.toString());

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

  /// Tokens-per-minute rate limit for Groq (0 = unlimited). Applied when
  /// the orchestrator wraps the backend in its rate-limited decorator.
  Future<int> getGroqTpmLimit() async {
    final v = await _readString(_kGroqTpmLimit);
    return int.tryParse(v ?? '') ?? 0;
  }
  Future<void> setGroqTpmLimit(int v) =>
      _writeString(_kGroqTpmLimit, v.toString());

  // ---------------------------------------------------------------------------
  // Gemini settings
  // ---------------------------------------------------------------------------

  Future<String?> getGeminiApiKey() => _readString(_kGeminiApiKey);
  Future<void> setGeminiApiKey(String key) => _writeString(_kGeminiApiKey, key);

  Future<String?> getGeminiModel() => _readString(_kGeminiModel);
  Future<void> setGeminiModel(String model) =>
      _writeString(_kGeminiModel, model);

  Future<double> getGeminiTemperature() async {
    final v = await _readString(_kGeminiTemperature);
    return double.tryParse(v ?? '') ?? defaultGeminiTemperature;
  }
  Future<void> setGeminiTemperature(double v) =>
      _writeString(_kGeminiTemperature, v.toString());

  Future<int> getGeminiMaxTokens() async {
    final v = await _readString(_kGeminiMaxTokens);
    return int.tryParse(v ?? '') ?? defaultGeminiMaxTokens;
  }
  Future<void> setGeminiMaxTokens(int v) =>
      _writeString(_kGeminiMaxTokens, v.toString());

  Future<int> getGeminiTpmLimit() async {
    final v = await _readString(_kGeminiTpmLimit);
    return int.tryParse(v ?? '') ?? 0;
  }
  Future<void> setGeminiTpmLimit(int v) =>
      _writeString(_kGeminiTpmLimit, v.toString());

  Future<List<String>> getGeminiModels() async {
    final raw = await _readString(_kGeminiModels);
    if (raw == null || raw.trim().isEmpty) {
      return List<String>.from(defaultGeminiModels);
    }
    return raw
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> setGeminiModels(List<String> models) =>
      _writeString(_kGeminiModels, models.join('\n'));

  // ---------------------------------------------------------------------------
  // OpenRouter settings
  // ---------------------------------------------------------------------------

  Future<String?> getOpenRouterApiKey() => _readString(_kOpenRouterApiKey);
  Future<void> setOpenRouterApiKey(String key) =>
      _writeString(_kOpenRouterApiKey, key);

  Future<String?> getOpenRouterModel() => _readString(_kOpenRouterModel);
  Future<void> setOpenRouterModel(String model) =>
      _writeString(_kOpenRouterModel, model);

  Future<double> getOpenRouterTemperature() async {
    final v = await _readString(_kOpenRouterTemperature);
    return double.tryParse(v ?? '') ?? defaultOpenRouterTemperature;
  }
  Future<void> setOpenRouterTemperature(double v) =>
      _writeString(_kOpenRouterTemperature, v.toString());

  Future<int> getOpenRouterMaxTokens() async {
    final v = await _readString(_kOpenRouterMaxTokens);
    return int.tryParse(v ?? '') ?? defaultOpenRouterMaxTokens;
  }
  Future<void> setOpenRouterMaxTokens(int v) =>
      _writeString(_kOpenRouterMaxTokens, v.toString());

  /// Context window budget used by the OpenRouter orchestrator for history
  /// trimming. The provider still enforces its own model limit.
  Future<int> getOpenRouterContextLimit() async {
    final v = await _readString(_kOpenRouterContextLimit);
    return int.tryParse(v ?? '') ?? 128000;
  }

  Future<void> setOpenRouterContextLimit(int v) {
    if (v <= 0) {
      throw ArgumentError.value(v, 'v', 'must be greater than zero');
    }
    return _writeString(_kOpenRouterContextLimit, v.toString());
  }

  Future<int> getOpenRouterTpmLimit() async {
    final v = await _readString(_kOpenRouterTpmLimit);
    return int.tryParse(v ?? '') ?? 0;
  }
  Future<void> setOpenRouterTpmLimit(int v) =>
      _writeString(_kOpenRouterTpmLimit, v.toString());

  // ---------------------------------------------------------------------------
  // GitHub Models settings
  // ---------------------------------------------------------------------------

  Future<String?> getGithubApiKey() => _readString(_kGithubApiKey);
  Future<void> setGithubApiKey(String key) =>
      _writeString(_kGithubApiKey, key);

  Future<String?> getGithubModel() => _readString(_kGithubModel);
  Future<void> setGithubModel(String model) =>
      _writeString(_kGithubModel, model);

  Future<double> getGithubTemperature() async {
    final v = await _readString(_kGithubTemperature);
    return double.tryParse(v ?? '') ?? defaultGithubTemperature;
  }
  Future<void> setGithubTemperature(double v) =>
      _writeString(_kGithubTemperature, v.toStringAsFixed(2));

  Future<double> getHuggingFaceTemperature() async {
    final v = await _readString('huggingface.temperature');
    return double.tryParse(v ?? '') ?? 0.1;
  }

  Future<double> getGitHubTemperature() async {
    final v = await _readString(_kGithubTemperature);
    return double.tryParse(v ?? '') ?? defaultGithubTemperature;
  }

  Future<int> getGithubMaxTokens() async {
    final v = await _readString(_kGithubMaxTokens);
    return int.tryParse(v ?? '') ?? defaultGithubMaxTokens;
  }
  Future<void> setGithubMaxTokens(int v) =>
      _writeString(_kGithubMaxTokens, v.toString());

  Future<int> getGithubTpmLimit() async {
    final v = await _readString(_kGithubTpmLimit);
    return int.tryParse(v ?? '') ?? 0;
  }
  Future<void> setGithubTpmLimit(int v) =>
      _writeString(_kGithubTpmLimit, v.toString());

  /// Whether the GitHub orchestrator should run in plain-chat mode
  /// (skip the tool loop, don't send the `tools` array). Auto-toggled
  /// by the Settings UI based on the selected model's catalog
  /// `capabilities`, but the user can override.
  Future<bool> getGithubDisableTools() async {
    final v = await _readString(_kGithubDisableTools);
    return v == '1' || v == 'true';
  }
  Future<void> setGithubDisableTools(bool v) =>
      _writeString(_kGithubDisableTools, v ? '1' : '0');

  // ---------------------------------------------------------------------------
  // /api/generate backend settings
  // ---------------------------------------------------------------------------

  Future<String?> getGenerateBaseUrl() => _readString(_kGenerateBaseUrl);
  Future<void> setGenerateBaseUrl(String url) =>
      _writeString(_kGenerateBaseUrl, url);

  Future<String?> getGenerateModel() => _readString(_kGenerateModel);
  Future<void> setGenerateModel(String model) =>
      _writeString(_kGenerateModel, model);

  Future<double> getGenerateTemperature() async {
    final v = await _readString(_kGenerateTemperature);
    return double.tryParse(v ?? '') ?? defaultGenerateTemperature;
  }
  Future<void> setGenerateTemperature(double v) =>
      _writeString(_kGenerateTemperature, v.toString());

  Future<int> getGenerateNumPredict() async {
    final v = await _readString(_kGenerateNumPredict);
    return int.tryParse(v ?? '') ?? defaultGenerateNumPredict;
  }
  Future<void> setGenerateNumPredict(int v) =>
      _writeString(_kGenerateNumPredict, v.toString());

  Future<int> getGenerateNumCtx() async {
    final v = await _readString(_kGenerateNumCtx);
    return int.tryParse(v ?? '') ?? defaultGenerateNumCtx;
  }
  Future<void> setGenerateNumCtx(int v) =>
      _writeString(_kGenerateNumCtx, v.toString());

  Future<String?> getGenerateApiKey() => _readString(_kGenerateApiKey);
  Future<void> setGenerateApiKey(String key) =>
      _writeString(_kGenerateApiKey, key);

  Future<bool> getGenerateThinking() async {
    final v = await _readString(_kGenerateThinking);
    return v == 'true';
  }
  Future<void> setGenerateThinking(bool enabled) =>
      _writeString(_kGenerateThinking, enabled.toString());

  Future<String?> _readString(String key) async {
    final scopedKey = _scopedKey(key);
    if (scopedKey != key) {
      final scoped = await _readRaw(scopedKey);
      if (scoped != null) return scoped;
    }
    return _readRaw(key);
  }

  Future<String?> _readRaw(String key) async {
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
      {"id": _scopedKey(key), "value": value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  String _scopedKey(String key) {
    final projectKey = ProjectService().activeProjectKey;
    if (projectKey == null || projectKey.trim().isEmpty) return key;
    return 'project.$projectKey::$key';
  }

  Future<String?> getOllamaPythonBridgeUrl() =>
      _readString(_kOllamaPythonBridgeUrl);

  Future<void> setOllamaPythonBridgeUrl(String url) =>
      _writeString(_kOllamaPythonBridgeUrl, url);
}
