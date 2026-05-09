import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/constants/api_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/agent_credentials.dart';
import '../../data/models/hf_model.dart';
import '../../data/repositories/agent_credentials_repository.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/dev_filters_repository.dart';
import '../../data/repositories/model_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/project_service.dart';
import '../../services/groq_service.dart';
import '../../services/llm_service.dart';
import '../../services/ollama_generate_service.dart';
import '../../services/ollama_manager.dart';
import '../../services/ollama_python_manager.dart';
import '../../services/ollama_service.dart';
import '../../services/ollama_library_service.dart';
import '../../services/github_models_service.dart';
import '../../services/openrouter_service.dart';
import '../../services/orchestrator_manager.dart';
import '../widgets/agent_workflow_settings.dart';
import '../widgets/local_server_config_widget.dart';
import '../widgets/token_count_picker.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _agentTokenController = TextEditingController();
  final TextEditingController _newModelController = TextEditingController();
  final TextEditingController _localServerUrlController = TextEditingController();

  List<HfModel> _models = [];
  String? _selectedModelId;
  bool _obscureToken = true;
  bool _obscureAgentToken = true;
  bool _loading = true;
  LlmBackend _activeBackend = LlmBackend.huggingFace;
  String? _localServerUrl;

  // Settings side-nav: 0 = Model Settings, 1 = Orchestrator,
  // 2 = Workflow Agents, 3 = Developer (debug-only).
  int _settingsSection = 0;

  // Developer / installer panel state.
  bool _installerBusy = false;
  final List<String> _installerLog = [];
  final ScrollController _installerLogScroll = ScrollController();

  // External-tools paths (Flutter SDK + Python interpreter). Loaded from
  // SettingsRepository when the Developer panel opens; saved on demand.
  final TextEditingController _flutterSdkPathController =
      TextEditingController();
  final TextEditingController _pythonPathController = TextEditingController();
  bool _externalPathsLoaded = false;

  // Filesystem filter lists (per working directory). Loaded once when the
  // Developer panel opens; saved per-list when the user clicks Save on
  // that list's row. The four categories drive the orchestrator's
  // discovery tools (list_files / search_in_files / find_files /
  // list_files_recursive). read_file and write_file are NOT filtered —
  // explicit paths the user mentions still work even if matched here.
  List<String> _excludeDirs = [];
  List<String> _includeDirs = [];
  List<String> _excludeFiles = [];
  List<String> _includeFiles = [];
  bool _filtersLoaded = false;
  String? _filtersWorkingDir;

  // Orchestrator log persistence
  List<String> _persistedLog = [];
  File? _logFile;

  // Orchestrator control state (only relevant when LlmBackend.orchestrator).
  bool _orchestratorBusy = false;
  final List<String> _orchestratorLog = [];

  // Ollama control state (only relevant when LlmBackend.ollama).
  final TextEditingController _ollamaUrlController = TextEditingController();
  final TextEditingController _ollamaApiKeyController = TextEditingController();
  final TextEditingController _ollamaPullController = TextEditingController();
  bool _ollamaApiKeyVisible = false;
  Timer? _ollamaApiKeySaveTimer;
  bool _ollamaBusy = false;
  // In-progress pull tracking — populated only while a download is running.
  CancelToken? _ollamaPullCancelToken;
  String? _ollamaPullingModel;
  int _ollamaPullCompleted = 0;
  int _ollamaPullTotal = 0;
  bool _ollamaPullCancelled = false;
  final List<String> _ollamaLog = [];
  String? _ollamaBinaryVersion; // null => not detected yet or missing
  bool _ollamaServerUp = false;
  List<String> _ollamaInstalledModels = const [];
  List<OllamaCatalogModel> _ollamaCatalog = const [];
  bool _ollamaCatalogLoading = false;
  final ScrollController _ollamaCatalogScrollController = ScrollController();
  // Library scrape (ollama.com/library) — separate from the local catalog.
  List<OllamaLibraryModel> _ollamaLibrary = const [];
  bool _ollamaLibraryLoading = false;
  String? _ollamaLibraryError;
  final ScrollController _ollamaLibraryScrollController = ScrollController();
  final TextEditingController _ollamaLibraryFilterController =
      TextEditingController();
  String _ollamaLibraryFilter = '';
  String? _ollamaSelectedModel;
  final TextEditingController _ollamaPythonUrlController = TextEditingController();
  bool _ollamaPythonBusy = false;
  final List<String> _ollamaPythonLog = [];
  String? _pythonVersion;
  String? _ollamaPythonPackageVersion;
  bool _ollamaPythonBridgeUp = false;

  // Ollama generation parameters (sent to the orchestrator subprocess as
  // CLI flags and to the direct Ollama chat path as `options`).
  double _ollamaTemperature = BackendSettingsRepository.defaultOllamaTemperature;
  int _ollamaNumPredict = BackendSettingsRepository.defaultOllamaNumPredict;
  int _ollamaNumCtxValue = BackendSettingsRepository.defaultOllamaNumCtx;
  final TextEditingController _ollamaNumPredictController = TextEditingController();
  final TextEditingController _ollamaNumCtxController = TextEditingController();

  // Groq settings
  final TextEditingController _groqApiKeyController = TextEditingController();
  bool _groqApiKeyVisible = false;
  Timer? _groqApiKeySaveTimer;
  List<String> _groqModels = GroqService.fallbackModels;
  String? _groqSelectedModel;
  bool _groqLoadingModels = false;
  double _groqTemperature = BackendSettingsRepository.defaultGroqTemperature;
  final TextEditingController _groqMaxTokensController = TextEditingController();
  Timer? _groqMaxTokensSaveTimer;
  final TextEditingController _groqTpmLimitController = TextEditingController();
  Timer? _groqTpmLimitSaveTimer;
  List<GroqModel> _groqCatalog = const [];
  final ScrollController _groqCatalogScrollController = ScrollController();

  // Gemini settings
  List<String> _geminiModels = List<String>.from(
    BackendSettingsRepository.defaultGeminiModels,
  );
  final TextEditingController _geminiNewModelController =
      TextEditingController();
  final TextEditingController _geminiApiKeyController = TextEditingController();
  bool _geminiApiKeyVisible = false;
  Timer? _geminiApiKeySaveTimer;
  String? _geminiSelectedModel;
  double _geminiTemperature = BackendSettingsRepository.defaultGeminiTemperature;
  final TextEditingController _geminiMaxTokensController = TextEditingController();
  Timer? _geminiMaxTokensSaveTimer;
  final TextEditingController _geminiTpmLimitController = TextEditingController();
  Timer? _geminiTpmLimitSaveTimer;

  // OpenRouter settings
  final TextEditingController _openRouterApiKeyController = TextEditingController();
  bool _openRouterApiKeyVisible = false;
  Timer? _openRouterApiKeySaveTimer;
  List<OpenRouterModel> _openRouterCatalog = const [];
  List<String> _openRouterModels = const [];
  String? _openRouterSelectedModel;
  bool _openRouterLoadingModels = false;
  double _openRouterTemperature = BackendSettingsRepository.defaultOpenRouterTemperature;
  final TextEditingController _openRouterMaxTokensController = TextEditingController();
  Timer? _openRouterMaxTokensSaveTimer;
  final TextEditingController _openRouterTpmLimitController = TextEditingController();
  Timer? _openRouterTpmLimitSaveTimer;
  final ScrollController _openRouterCatalogScrollController = ScrollController();
  // Sort state for the OpenRouter catalog table — null = original (id) order.
  String? _orSortColumn; // 'priceIn' | 'priceOut'
  bool _orSortAsc = true;

  // GitHub Models settings
  final TextEditingController _githubApiKeyController = TextEditingController();
  bool _githubApiKeyVisible = false;
  Timer? _githubApiKeySaveTimer;
  List<GithubModel> _githubCatalog = const [];
  List<String> _githubModels = GithubModelsService.fallbackModels;
  String? _githubSelectedModel;
  bool _githubLoadingModels = false;
  double _githubTemperature = BackendSettingsRepository.defaultGithubTemperature;
  final TextEditingController _githubMaxTokensController = TextEditingController();
  Timer? _githubMaxTokensSaveTimer;
  final TextEditingController _githubTpmLimitController = TextEditingController();
  Timer? _githubTpmLimitSaveTimer;
  // Dedicated controller for the catalog ListView so the Scrollbar can
  // attach to a real ScrollPosition (avoids the PrimaryScrollController
  // assertion on desktop when the catalog list is short).
  final ScrollController _githubCatalogScrollController = ScrollController();

  // /api/generate backend settings
  final TextEditingController _generateBaseUrlController = TextEditingController();
  final TextEditingController _generateModelController = TextEditingController();
  final TextEditingController _generateApiKeyController = TextEditingController();
  final TextEditingController _generateNumPredictController = TextEditingController();
  final TextEditingController _generateNumCtxController = TextEditingController();
  bool _generateApiKeyVisible = false;
  double _generateTemperature = BackendSettingsRepository.defaultGenerateTemperature;
  bool _generateThinking = false;
  Timer? _generateBaseUrlSaveTimer;
  Timer? _generateModelSaveTimer;

  // Debounce timers for auto-saving fields as the user types.
  Timer? _tokenSaveTimer;
  Timer? _agentTokenSaveTimer;
  Timer? _localServerUrlSaveTimer;
  Timer? _ollamaUrlSaveTimer;
  Timer? _ollamaPythonUrlSaveTimer;
  Timer? _ollamaNumPredictSaveTimer;
  Timer? _ollamaNumCtxSaveTimer;

  List<TextSpan> _buildModelTextSpans(String modelId) {
    const baseStyle = TextStyle(fontSize: 13, color: AppTheme.textPrimary);
    if (!modelId.contains(':free')) {
      return [TextSpan(text: modelId, style: baseStyle)];
    }
    final parts = modelId.split(':free');
    final spans = <TextSpan>[];
    for (int i = 0; i < parts.length; i++) {
      spans.add(TextSpan(text: parts[i], style: baseStyle));
      if (i < parts.length - 1) {
        spans.add(const TextSpan(
          text: ':free',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white,
            fontWeight: FontWeight.bold,
            backgroundColor: AppTheme.accentMarrone,
          ),
        ));
      }
    }
    return spans;
  }

  @override
  void initState() {
    super.initState();
    _load();
    _initLogFile();
  }

  @override
  void dispose() {
    _tokenSaveTimer?.cancel();
    _agentTokenSaveTimer?.cancel();
    _localServerUrlSaveTimer?.cancel();
    _ollamaUrlSaveTimer?.cancel();
    _ollamaPythonUrlSaveTimer?.cancel();
    _ollamaNumPredictSaveTimer?.cancel();
    _ollamaNumCtxSaveTimer?.cancel();
    _ollamaApiKeySaveTimer?.cancel();
    _tokenController.dispose();
    _agentTokenController.dispose();
    _newModelController.dispose();
    _localServerUrlController.dispose();
    _flutterSdkPathController.dispose();
    _pythonPathController.dispose();
    _ollamaUrlController.dispose();
    _ollamaApiKeyController.dispose();
    _ollamaPullController.dispose();
    _ollamaCatalogScrollController.dispose();
    _ollamaLibraryScrollController.dispose();
    _ollamaLibraryFilterController.dispose();
    _ollamaPythonUrlController.dispose();
    _ollamaNumPredictController.dispose();
    _ollamaNumCtxController.dispose();
    _groqApiKeySaveTimer?.cancel();
    _groqMaxTokensSaveTimer?.cancel();
    _groqTpmLimitSaveTimer?.cancel();
    _groqApiKeyController.dispose();
    _groqMaxTokensController.dispose();
    _groqTpmLimitController.dispose();
    _groqCatalogScrollController.dispose();
    _geminiApiKeySaveTimer?.cancel();
    _geminiMaxTokensSaveTimer?.cancel();
    _geminiTpmLimitSaveTimer?.cancel();
    _geminiApiKeyController.dispose();
    _geminiNewModelController.dispose();
    _geminiMaxTokensController.dispose();
    _geminiTpmLimitController.dispose();
    _openRouterApiKeySaveTimer?.cancel();
    _openRouterMaxTokensSaveTimer?.cancel();
    _openRouterTpmLimitSaveTimer?.cancel();
    _openRouterApiKeyController.dispose();
    _openRouterMaxTokensController.dispose();
    _openRouterTpmLimitController.dispose();
    _openRouterCatalogScrollController.dispose();
    _githubApiKeySaveTimer?.cancel();
    _githubMaxTokensSaveTimer?.cancel();
    _githubTpmLimitSaveTimer?.cancel();
    _githubApiKeyController.dispose();
    _githubMaxTokensController.dispose();
    _githubTpmLimitController.dispose();
    _githubCatalogScrollController.dispose();
    _generateBaseUrlSaveTimer?.cancel();
    _generateModelSaveTimer?.cancel();
    _generateBaseUrlController.dispose();
    _generateModelController.dispose();
    _generateApiKeyController.dispose();
    _generateNumPredictController.dispose();
    _generateNumCtxController.dispose();
    super.dispose();
  }

  // ---- Orchestrator log file (rolling 2 000-line buffer) --------------------

  Future<void> _initLogFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _logFile = File('${dir.path}/orchestrator_log.txt');
      if (await _logFile!.exists()) {
        final lines = await _logFile!.readAsLines();
        if (mounted) setState(() => _persistedLog = List<String>.from(lines));
      }
    } catch (_) {}
  }

  Future<void> _appendToLogFile(String line) async {
    if (_logFile == null) return;
    try {
      await _logFile!.writeAsString('$line\n', mode: FileMode.append);
      var lines = await _logFile!.readAsLines();
      if (lines.length > 2000) {
        lines = lines.sublist(lines.length - 2000);
        await _logFile!.writeAsString('${lines.join('\n')}\n');
      }
      if (mounted) setState(() => _persistedLog = List<String>.from(lines));
    } catch (_) {}
  }

  // ---- Debounced auto-save handlers -----------------------------------------

  void _scheduleHfTokenSave(String value) {
    _tokenSaveTimer?.cancel();
    _tokenSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      await SettingsRepository.instance.setHfToken(value.trim());
    });
  }

  void _scheduleAgentTokenSave(String value) {
    _agentTokenSaveTimer?.cancel();
    _agentTokenSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final v = value.trim();
      if (v.isEmpty) return;
      await AgentCredentialsRepository.instance.saveCredentials(AgentCredentials(hfToken: v));
    });
  }

  void _scheduleLocalServerUrlSave(String value) {
    _localServerUrlSaveTimer?.cancel();
    _localServerUrlSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final v = value.trim();
      if (v.isEmpty) return;
      await BackendSettingsRepository.instance.setLocalServerUrl(v);
    });
  }

  void _scheduleOllamaUrlSave(String value) {
    _ollamaUrlSaveTimer?.cancel();
    _ollamaUrlSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final v = value.trim();
      if (v.isEmpty) return;
      await BackendSettingsRepository.instance.setOllamaBaseUrl(v);
    });
  }

  void _scheduleGroqMaxTokensSave(String value) {
    _groqMaxTokensSaveTimer?.cancel();
    _groqMaxTokensSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim());
      if (v != null && v > 0) {
        await BackendSettingsRepository.instance.setGroqMaxTokens(v);
      }
    });
  }

  void _scheduleGroqTpmLimitSave(String value) {
    _groqTpmLimitSaveTimer?.cancel();
    _groqTpmLimitSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim()) ?? 0;
      // 0 is a valid value (= unlimited); just clamp negatives to 0.
      await BackendSettingsRepository.instance
          .setGroqTpmLimit(v < 0 ? 0 : v);
    });
  }

  void _scheduleGroqApiKeySave(String value) {
    _groqApiKeySaveTimer?.cancel();
    _groqApiKeySaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final trimmed = value.trim();
      await BackendSettingsRepository.instance.setGroqApiKey(trimmed);
      if (trimmed.isNotEmpty) _refreshGroqModels(trimmed);
    });
  }

  void _scheduleGeminiApiKeySave(String value) {
    _geminiApiKeySaveTimer?.cancel();
    _geminiApiKeySaveTimer = Timer(const Duration(milliseconds: 600), () async {
      await BackendSettingsRepository.instance.setGeminiApiKey(value.trim());
    });
  }

  void _scheduleGeminiMaxTokensSave(String value) {
    _geminiMaxTokensSaveTimer?.cancel();
    _geminiMaxTokensSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim());
      if (v != null && v > 0) {
        await BackendSettingsRepository.instance.setGeminiMaxTokens(v);
      }
    });
  }

  void _scheduleOpenRouterApiKeySave(String value) {
    _openRouterApiKeySaveTimer?.cancel();
    _openRouterApiKeySaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final trimmed = value.trim();
      await BackendSettingsRepository.instance.setOpenRouterApiKey(trimmed);
      await _refreshOpenRouterModels(trimmed);
    });
  }

  void _scheduleOpenRouterMaxTokensSave(String value) {
    _openRouterMaxTokensSaveTimer?.cancel();
    _openRouterMaxTokensSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim());
      if (v != null && v > 0) {
        await BackendSettingsRepository.instance.setOpenRouterMaxTokens(v);
      }
    });
  }

  void _scheduleGeminiTpmLimitSave(String value) {
    _geminiTpmLimitSaveTimer?.cancel();
    _geminiTpmLimitSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim()) ?? 0;
      await BackendSettingsRepository.instance
          .setGeminiTpmLimit(v < 0 ? 0 : v);
    });
  }

  void _scheduleOpenRouterTpmLimitSave(String value) {
    _openRouterTpmLimitSaveTimer?.cancel();
    _openRouterTpmLimitSaveTimer =
        Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim()) ?? 0;
      await BackendSettingsRepository.instance
          .setOpenRouterTpmLimit(v < 0 ? 0 : v);
    });
  }

  Future<void> _refreshGroqModels(String apiKey) async {
    if (!mounted) return;
    setState(() => _groqLoadingModels = true);
    final catalog = await GroqService.instance.listCatalog(apiKey);
    final models = catalog.isEmpty
        ? GroqService.fallbackModels
        : catalog.map((m) => m.id).toList();
    if (!mounted) return;
    setState(() {
      _groqCatalog = catalog;
      _groqModels = models;
      if (!models.contains(_groqSelectedModel)) {
        _groqSelectedModel = models.first;
      }
      _groqLoadingModels = false;
    });
    await BackendSettingsRepository.instance.setGroqModel(_groqSelectedModel ?? models.first);
  }

  Future<void> _refreshOpenRouterModels(String apiKey) async {
    if (!mounted) return;
    setState(() => _openRouterLoadingModels = true);

    List<OpenRouterModel> catalog = const [];
    if (apiKey.trim().isNotEmpty) {
      catalog = await OpenRouterService.instance.listCatalog(apiKey);
    }

    List<String> models = catalog.map((m) => m.id).toList();

    final selected = _openRouterSelectedModel?.trim() ?? '';
    if (selected.isNotEmpty && !models.contains(selected)) {
      models = [selected, ...models];
    }

    final String? nextSelected = models.isEmpty
        ? null
        : (models.contains(_openRouterSelectedModel)
            ? _openRouterSelectedModel
            : models.first);

    if (!mounted) return;
    setState(() {
      _openRouterCatalog = catalog;
      _openRouterModels = models;
      _openRouterSelectedModel = nextSelected;
      _openRouterLoadingModels = false;
    });
    if (nextSelected != null) {
      await BackendSettingsRepository.instance.setOpenRouterModel(nextSelected);
    }
  }

  void _scheduleGithubApiKeySave(String value) {
    _githubApiKeySaveTimer?.cancel();
    _githubApiKeySaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final trimmed = value.trim();
      await BackendSettingsRepository.instance.setGithubApiKey(trimmed);
      await _refreshGithubCatalog(trimmed);
    });
  }

  void _scheduleGithubMaxTokensSave(String value) {
    _githubMaxTokensSaveTimer?.cancel();
    _githubMaxTokensSaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim());
      if (v != null && v > 0) {
        await BackendSettingsRepository.instance.setGithubMaxTokens(v);
      }
    });
  }

  void _scheduleGithubTpmLimitSave(String value) {
    _githubTpmLimitSaveTimer?.cancel();
    _githubTpmLimitSaveTimer =
        Timer(const Duration(milliseconds: 600), () async {
      final v = int.tryParse(value.trim()) ?? 0;
      await BackendSettingsRepository.instance
          .setGithubTpmLimit(v < 0 ? 0 : v);
    });
  }

  Future<void> _refreshGithubCatalog(String apiKey) async {
    if (!mounted) return;
    setState(() => _githubLoadingModels = true);

    List<GithubModel> catalog = const [];
    if (apiKey.trim().isNotEmpty) {
      catalog = await GithubModelsService.instance.listCatalog(apiKey);
    }
    // Show every model in the dropdown — non-tool-capable ones (phi-4,
    // base Mistral, etc.) work as plain reasoning chat. The Settings UI
    // automatically writes `githubDisableTools=true` for those so the
    // orchestrator skips the tool loop and the `tools=[...]` payload.
    List<String> models = catalog.map((m) => m.id).toList();
    if (models.isEmpty) models = GithubModelsService.fallbackModels;

    final selected = _githubSelectedModel?.trim() ?? '';
    if (selected.isNotEmpty && !models.contains(selected)) {
      models = [selected, ...models];
    }
    final nextSelected = models.contains(_githubSelectedModel)
        ? (_githubSelectedModel ?? models.first)
        : models.first;

    if (!mounted) return;
    setState(() {
      _githubCatalog = catalog;
      _githubModels = models;
      _githubSelectedModel = nextSelected;
      _githubLoadingModels = false;
    });
    await BackendSettingsRepository.instance.setGithubModel(nextSelected);
    // Sync the plain-chat flag with the (possibly auto-changed) selection.
    final cat = catalog.firstWhere(
      (m) => m.id == nextSelected,
      orElse: () => GithubModel.fromJson(const {}),
    );
    final disable =
        cat.id.isNotEmpty && !GithubModelsService.supportsToolCalling(cat);
    await BackendSettingsRepository.instance.setGithubDisableTools(disable);
  }

  Widget _groqControlPanel() {
    return _section(
      title: '⚡ Groq Cloud',
      subtitle: 'Ultra-fast inference on Groq LPU hardware. '
          'Get a free API key at console.groq.com',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // API Key
          TextField(
            controller: _groqApiKeyController,
            obscureText: !_groqApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'Groq API Key',
              hintText: 'gsk_...',
              helperText: 'Free key from console.groq.com/keys',
              suffixIcon: IconButton(
                icon: Icon(
                  _groqApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(() => _groqApiKeyVisible = !_groqApiKeyVisible),
              ),
            ),
            onChanged: _scheduleGroqApiKeySave,
          ),
          const SizedBox(height: 16),

          // Model selector
          Row(
            children: [
              const Text('Model', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              Expanded(
                child: _groqLoadingModels
                    ? const LinearProgressIndicator()
                    : DropdownButton<String>(
                        isExpanded: true,
                        value: _groqModels.contains(_groqSelectedModel) ? _groqSelectedModel : _groqModels.first,
                        items: _groqModels
                            .map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m, style: const TextStyle(fontSize: 13)),
                                ))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _groqSelectedModel = v);
                          await BackendSettingsRepository.instance.setGroqModel(v);
                          if (OrchestratorManager.instance.isRunning) {
                            await OrchestratorManager.instance.stop();
                          }
                        },
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh model list',
                onPressed: _groqApiKeyController.text.trim().isNotEmpty ? () => _refreshGroqModels(_groqApiKeyController.text.trim()) : null,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Temperature
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text('Temperature', style: TextStyle(fontSize: 13)),
              ),
              Expanded(
                child: Slider(
                  value: _groqTemperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  label: _groqTemperature.toStringAsFixed(2),
                  onChanged: (v) async {
                    setState(() => _groqTemperature = v);
                    await BackendSettingsRepository.instance.setGroqTemperature(v);
                  },
                ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  _groqTemperature.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          Text(
            'Lower = focused/deterministic. Higher = creative/varied. '
            'Groq default: 1.0. Recommended for chat: 0.6–0.9.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),

          // Max completion tokens
          TokenCountPicker(
            controller: _groqMaxTokensController,
            presets: TokenCountPicker.maxTokensPresets,
            labelText: 'Max completion tokens',
            hintText: '4096',
            helperText:
                'Reply-length cap only. Groq bills per emitted output token, so raising this just allows longer '
                'answers — it does not pre-charge you. Groq models support 8K–32K output depending on the model.',
            onChanged: _scheduleGroqMaxTokensSave,
          ),
          const SizedBox(height: 12),

          // Tokens-per-minute rate limit (orchestrator side)
          TextField(
            controller: _groqTpmLimitController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'TPM limit (0 = unlimited)',
              hintText: '0',
              helperText:
                  'Tokens-per-minute cap for the orchestrator. Free tier '
                  'Groq models typically allow 6000–8000 TPM. When set, the '
                  'orchestrator queues oversize requests and auto-trims '
                  'history that would exceed the minute budget.',
              suffixText: 'TPM',
            ),
            onChanged: _scheduleGroqTpmLimitSave,
          ),
          const SizedBox(height: 24),
          _groqCatalogTable(),
        ],
      ),
    );
  }

  // Groq catalog table — column geometry mirrors the GitHub one.
  // Groq's `/models` endpoint exposes id, owner, active, context window,
  // and max completion tokens — no pricing — so the column set is trimmed
  // to what's actually returned.
  static const int _kGroqColFlexName = 6;
  static const int _kGroqColFlexOwner = 3;
  static const int _kGroqColFlexCtx = 2;
  static const int _kGroqColFlexMaxOut = 2;
  static const double _kGroqColWidthActive = 36;
  static const double _kGroqColWidthTools = 36;

  static const List<Widget> _kGroqCatalogHeaderCells = [
    Expanded(
      flex: _kGroqColFlexName,
      child: Text('Name / ID',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGroqColFlexOwner,
      child: Text('Owner',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGroqColFlexCtx,
      child: Text('Context',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.right),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGroqColFlexMaxOut,
      child: Text('Max out',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.right),
    ),
    SizedBox(width: 8),
    SizedBox(
      width: _kGroqColWidthActive,
      child: Text('Active',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center),
    ),
    SizedBox(width: 8),
    SizedBox(
      width: _kGroqColWidthTools,
      child: Text('Tools',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center),
    ),
  ];

  Future<void> _copyGroqCatalog() async {
    if (_groqCatalog.isEmpty) return;
    final buf = StringBuffer()
      ..writeln([
        'id',
        'owner',
        'context_window',
        'max_completion_tokens',
        'active',
        'tools',
      ].join('\t'));
    for (final m in _groqCatalog) {
      buf.writeln([
        m.id,
        m.ownedBy,
        m.contextWindow?.toString() ?? '',
        m.maxCompletionTokens?.toString() ?? '',
        m.active ? 'yes' : 'no',
        GroqService.supportsToolCalling(m.id) ? 'yes' : 'no',
      ].join('\t'));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${_groqCatalog.length} Groq models to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _groqCatalogTable() {
    if (_groqCatalog.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _groqLoadingModels
              ? 'Loading catalog…'
              : 'No catalog loaded. Save an API key or click refresh to fetch '
                  'the model catalog from api.groq.com.',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.list_alt, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Catalog (${_groqCatalog.length} models)',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy all rows as TSV',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.copy_all, size: 16),
                  onPressed: _copyGroqCatalog,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              border: Border(
                top: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
                bottom: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: _kGroqCatalogHeaderCells,
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: Scrollbar(
              controller: _groqCatalogScrollController,
              child: ListView.separated(
                controller: _groqCatalogScrollController,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _groqCatalog.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  thickness: 1,
                  color: AppTheme.accentDarkMarrone.withAlpha(30),
                ),
                itemBuilder: (ctx, i) {
                  final m = _groqCatalog[i];
                  final tools = GroqService.supportsToolCalling(m.id);
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: _kGroqColFlexName,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.id,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                                softWrap: true,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGroqColFlexOwner,
                          child: Text(
                            m.ownedBy,
                            style: const TextStyle(fontSize: 12),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGroqColFlexCtx,
                          child: Text(
                            m.contextWindow?.toString() ?? '—',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGroqColFlexMaxOut,
                          child: Text(
                            m.maxCompletionTokens?.toString() ?? '—',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kGroqColWidthActive,
                          child: Center(
                            child: Icon(
                              m.active
                                  ? Icons.check_circle
                                  : Icons.remove_circle_outline,
                              size: 16,
                              color: m.active ? Colors.green : Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kGroqColWidthTools,
                          child: Center(
                            child: Icon(
                              tools
                                  ? Icons.check_circle
                                  : Icons.remove_circle_outline,
                              size: 16,
                              color: tools ? Colors.green : Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _openRouterModelOptions() {
    return _openRouterModels;
  }

  Widget _openRouterControlPanel() {
    final modelOptions = _openRouterModelOptions();
    final selectedModel = modelOptions.contains(_openRouterSelectedModel)
        ? _openRouterSelectedModel
        : (modelOptions.isEmpty ? null : modelOptions.first);

    return _section(
      title: 'OpenRouter',
      subtitle: 'OpenAI-compatible routing across providers like OpenAI, '
          'Anthropic, Google, and more. Use provider-prefixed model IDs '
          'such as `openai/gpt-5-mini`.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _openRouterApiKeyController,
            obscureText: !_openRouterApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'OpenRouter API Key',
              hintText: 'sk-or-v1-...',
              helperText: 'Create one at openrouter.ai/keys',
              suffixIcon: IconButton(
                icon: Icon(
                  _openRouterApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(
                  () => _openRouterApiKeyVisible = !_openRouterApiKeyVisible,
                ),
              ),
            ),
            onChanged: _scheduleOpenRouterApiKeySave,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Model', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              Expanded(
                child: _openRouterLoadingModels
                    ? const LinearProgressIndicator()
                    : modelOptions.isEmpty
                    ? Text(
                        _openRouterApiKeyController.text.trim().isEmpty
                            ? 'Save an API key to load the model catalog.'
                            : 'No models available — refresh to retry.',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey[600]),
                      )
                    : DropdownButton<String>(
                        isExpanded: true,
                        value: selectedModel,
                        items: modelOptions
                            .map((m) {
                              final cat = _openRouterCatalog.firstWhere(
                                (c) => c.id == m,
                                orElse: () =>
                                    OpenRouterModel.fromJson(const {}),
                              );
                              final tools = cat.id.isEmpty
                                  ? true
                                  : OpenRouterService.supportsToolCalling(cat);
                              return DropdownMenuItem<String>(
                                value: m,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: RichText(
                                        overflow: TextOverflow.ellipsis,
                                        text: TextSpan(
                                          children: _buildModelTextSpans(m),
                                        ),
                                      ),
                                    ),
                                    if (!tools) ...[
                                      const SizedBox(width: 4),
                                      const Tooltip(
                                        message:
                                            'No tool calling — chat / reasoning only.\n'
                                            'Filesystem tools won\'t work with this model.',
                                        child: Icon(
                                            Icons.warning_amber_rounded,
                                            size: 14,
                                            color: Colors.orange),
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            }).toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _openRouterSelectedModel = v);
                          await BackendSettingsRepository.instance.setOpenRouterModel(v);
                          if (OrchestratorManager.instance.isRunning) {
                            await OrchestratorManager.instance.stop();
                          }
                        },
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh model list',
                onPressed: () => _refreshOpenRouterModels(
                  _openRouterApiKeyController.text.trim(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Need a model not shown here? Use the chat-header model picker to '
            'type any valid OpenRouter model ID manually.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text('Temperature', style: TextStyle(fontSize: 13)),
              ),
              Expanded(
                child: Slider(
                  value: _openRouterTemperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  label: _openRouterTemperature.toStringAsFixed(2),
                  onChanged: (v) async {
                    setState(() => _openRouterTemperature = v);
                    await BackendSettingsRepository.instance.setOpenRouterTemperature(v);
                  },
                ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  _openRouterTemperature.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TokenCountPicker(
            controller: _openRouterMaxTokensController,
            presets: TokenCountPicker.maxTokensPresets,
            labelText: 'Max completion tokens',
            hintText: '4096',
            helperText:
                'Reply-length cap only — OpenRouter uses `max_tokens`. The provider manages the full context '
                'window itself; you are billed per emitted output token, so larger values do not pre-charge.',
            onChanged: _scheduleOpenRouterMaxTokensSave,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _openRouterTpmLimitController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'TPM limit (0 = unlimited)',
              hintText: '0',
              helperText: 'Tokens-per-minute cap applied by the orchestrator. Set to stay under the provider/free-tier limit.',
              suffixText: 'TPM',
            ),
            onChanged: _scheduleOpenRouterTpmLimitSave,
          ),
          const SizedBox(height: 24),
          _openRouterCatalogTable(),
        ],
      ),
    );
  }

  // OpenRouter catalog table — same column-flex pattern as the GitHub one.
  static const int _kOrColFlexName = 6;
  static const int _kOrColFlexCtx = 2;
  static const int _kOrColFlexMaxOut = 2;
  static const int _kOrColFlexPriceIn = 3;
  static const int _kOrColFlexPriceOut = 3;
  static const int _kOrColFlexModalities = 3;
  static const double _kOrColWidthTools = 36;
  static const double _kOrColWidthPage = 36;

  void _toggleOrSort(String column) {
    setState(() {
      if (_orSortColumn == column) {
        _orSortAsc = !_orSortAsc;
      } else {
        _orSortColumn = column;
        _orSortAsc = true;
      }
    });
  }

  Widget _orSortableHeader(String label, String column) {
    final active = _orSortColumn == column;
    final icon = !active
        ? Icons.unfold_more
        : (_orSortAsc ? Icons.arrow_upward : Icons.arrow_downward);
    return InkWell(
      onTap: () => _toggleOrSort(column),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: active ? AppTheme.accentMarrone : null,
              ),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 2),
          Icon(icon,
              size: 12,
              color: active ? AppTheme.accentMarrone : Colors.grey),
        ],
      ),
    );
  }

  List<Widget> _orCatalogHeaderCells() => [
        const Expanded(
          flex: _kOrColFlexName,
          child: Text('Name / ID',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        const Expanded(
          flex: _kOrColFlexCtx,
          child: Text('Context',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              textAlign: TextAlign.right),
        ),
        const SizedBox(width: 8),
        const Expanded(
          flex: _kOrColFlexMaxOut,
          child: Text('Max out',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              textAlign: TextAlign.right),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: _kOrColFlexPriceIn,
          child: _orSortableHeader('In \$/Mtok', 'priceIn'),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: _kOrColFlexPriceOut,
          child: _orSortableHeader('Out \$/Mtok', 'priceOut'),
        ),
        const SizedBox(width: 8),
        const Expanded(
          flex: _kOrColFlexModalities,
          child: Text('Modalities',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 8),
        const SizedBox(
          width: _kOrColWidthTools,
          child: Text('Tools',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
        const SizedBox(width: 8),
        const SizedBox(
          width: _kOrColWidthPage,
          child: Text('Page',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center),
        ),
      ];

  String _formatPricePerMillion(double? perToken) {
    if (perToken == null) return '—';
    final perM = perToken * 1000000;
    if (perM == 0) return 'free';
    if (perM >= 100) return perM.toStringAsFixed(0);
    if (perM >= 1) return perM.toStringAsFixed(2);
    return perM.toStringAsFixed(3);
  }

  /// Renders a single price cell. When `highlightFree` is true and the value
  /// is exactly zero, the word "free" gets a green rounded pill.
  Widget _orPriceCell(double? perToken, {required bool highlightFree}) {
    final text = _formatPricePerMillion(perToken);
    if (text == 'free' && highlightFree) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.green.shade600,
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Text(
            'free',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      );
    }
    return Text(
      text,
      style: const TextStyle(fontSize: 12),
      textAlign: TextAlign.right,
    );
  }

  Future<void> _copyOpenRouterCatalog() async {
    final rows = _sortedOpenRouterCatalog();
    if (rows.isEmpty) return;
    final buf = StringBuffer()
      ..writeln([
        'id',
        'name',
        'context',
        'max_out',
        'in_per_mtok',
        'out_per_mtok',
        'modalities_in',
        'modalities_out',
        'tools',
      ].join('\t'));
    for (final m in rows) {
      buf.writeln([
        m.id,
        m.name,
        m.contextLength?.toString() ?? '',
        m.maxCompletionTokens?.toString() ?? '',
        _formatPricePerMillion(m.promptPricePerToken),
        _formatPricePerMillion(m.completionPricePerToken),
        m.inputModalities.join(','),
        m.outputModalities.join(','),
        OpenRouterService.supportsToolCalling(m) ? 'yes' : 'no',
      ].join('\t'));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied ${rows.length} OpenRouter models to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<OpenRouterModel> _sortedOpenRouterCatalog() {
    if (_orSortColumn == null) return _openRouterCatalog;
    final list = [..._openRouterCatalog];
    double key(OpenRouterModel m) {
      final v = _orSortColumn == 'priceIn'
          ? m.promptPricePerToken
          : m.completionPricePerToken;
      // Sort missing prices to the bottom regardless of direction.
      if (v == null) return _orSortAsc ? double.infinity : double.negativeInfinity;
      return v;
    }
    list.sort((a, b) {
      final c = key(a).compareTo(key(b));
      return _orSortAsc ? c : -c;
    });
    return list;
  }

  Widget _openRouterCatalogTable() {
    if (_openRouterCatalog.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _openRouterLoadingModels
              ? 'Loading catalog…'
              : 'No catalog loaded. Save an API key or click refresh to fetch '
                  'the model catalog from openrouter.ai.',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.list_alt, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Catalog (${_openRouterCatalog.length} models)',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy all rows as TSV',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.copy_all, size: 16),
                  onPressed: _copyOpenRouterCatalog,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              border: Border(
                top: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
                bottom: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: _orCatalogHeaderCells(),
            ),
          ),
          Builder(builder: (_) {
            final sorted = _sortedOpenRouterCatalog();
            return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: Scrollbar(
              controller: _openRouterCatalogScrollController,
              child: ListView.separated(
                controller: _openRouterCatalogScrollController,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: sorted.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  thickness: 1,
                  color: AppTheme.accentDarkMarrone.withAlpha(30),
                ),
                itemBuilder: (ctx, i) {
                  final m = sorted[i];
                  final tools = OpenRouterService.supportsToolCalling(m);
                  final modalities = m.inputModalities.isEmpty
                      ? '—'
                      : m.inputModalities.join(', ');
                  final bothFree = (m.promptPricePerToken ?? -1) == 0 &&
                      (m.completionPricePerToken ?? -1) == 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: _kOrColFlexName,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.name.isNotEmpty ? m.name : m.id,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                                softWrap: true,
                              ),
                              Text(
                                m.id,
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary),
                                softWrap: true,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOrColFlexCtx,
                          child: Text(
                            m.contextLength?.toString() ?? '—',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOrColFlexMaxOut,
                          child: Text(
                            m.maxCompletionTokens?.toString() ?? '—',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOrColFlexPriceIn,
                          child: _orPriceCell(m.promptPricePerToken,
                              highlightFree: bothFree),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOrColFlexPriceOut,
                          child: _orPriceCell(m.completionPricePerToken,
                              highlightFree: bothFree),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOrColFlexModalities,
                          child: Text(
                            modalities,
                            style: const TextStyle(fontSize: 12),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kOrColWidthTools,
                          child: Center(
                            child: Icon(
                              tools
                                  ? Icons.check_circle
                                  : Icons.remove_circle_outline,
                              size: 16,
                              color: tools ? Colors.green : Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kOrColWidthPage,
                          child: Center(
                            child: IconButton(
                              tooltip: m.htmlUrl.isEmpty
                                  ? 'No marketplace URL'
                                  : 'Copy ${m.htmlUrl} to clipboard',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 28, minHeight: 28),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              onPressed: m.htmlUrl.isEmpty
                                  ? null
                                  : () async {
                                      await Clipboard.setData(
                                          ClipboardData(text: m.htmlUrl));
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Copied URL: ${m.htmlUrl}'),
                                          duration:
                                              const Duration(seconds: 2),
                                        ),
                                      );
                                    },
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
          }),
        ],
      ),
    );
  }

  Widget _githubControlPanel() {
    final modelOptions = _githubModels.isNotEmpty
        ? _githubModels
        : GithubModelsService.fallbackModels;
    final selectedModel = modelOptions.contains(_githubSelectedModel)
        ? _githubSelectedModel
        : modelOptions.first;

    return _section(
      title: 'GitHub Models',
      subtitle: 'OpenAI-compatible inference via models.github.ai. '
          'Use a fine-grained PAT with `models:read` scope. Model IDs are '
          'publisher-prefixed, e.g. `openai/gpt-4o-mini`.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _githubApiKeyController,
            obscureText: !_githubApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'GitHub PAT (models:read)',
              hintText: 'github_pat_...',
              helperText:
                  'Create one at github.com/settings/personal-access-tokens/new',
              suffixIcon: IconButton(
                icon: Icon(
                  _githubApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(
                  () => _githubApiKeyVisible = !_githubApiKeyVisible,
                ),
              ),
            ),
            onChanged: _scheduleGithubApiKeySave,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Model', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              Expanded(
                child: _githubLoadingModels
                    ? const LinearProgressIndicator()
                    : DropdownButton<String>(
                        isExpanded: true,
                        value: selectedModel,
                        items: modelOptions
                            .map(
                              (m) {
                                final cat = _githubCatalog.firstWhere(
                                    (c) => c.id == m,
                                    orElse: () => GithubModel.fromJson(const {}));
                                final tools =
                                    GithubModelsService.supportsToolCalling(cat);
                                return DropdownMenuItem<String>(
                                  value: m,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(m,
                                            style:
                                                const TextStyle(fontSize: 13),
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                      if (!tools && cat.id.isNotEmpty) ...[
                                        const SizedBox(width: 4),
                                        const Tooltip(
                                          message:
                                              'No tool calling — chat / reasoning only.\n'
                                              'Filesystem tools will be disabled for this model.',
                                          child: Icon(Icons.warning_amber_rounded,
                                              size: 14, color: Colors.orange),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            )
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _githubSelectedModel = v);
                          await BackendSettingsRepository.instance
                              .setGithubModel(v);
                          if (OrchestratorManager.instance.isRunning) {
                            await OrchestratorManager.instance.stop();
                          }
                          // Auto-toggle plain-chat mode for non-tool models so
                          // the orchestrator skips the tool loop on next start.
                          final cat = _githubCatalog.firstWhere(
                              (c) => c.id == v,
                              orElse: () => GithubModel.fromJson(const {}));
                          final disable = cat.id.isNotEmpty &&
                              !GithubModelsService.supportsToolCalling(cat);
                          await BackendSettingsRepository.instance
                              .setGithubDisableTools(disable);
                        },
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh catalog from models.github.ai',
                onPressed: () => _refreshGithubCatalog(
                  _githubApiKeyController.text.trim(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'All catalog models are listed. Models marked with ⚠️ don\'t '
            'support tool calling — they\'re fine for plain chat / reasoning, '
            'but filesystem tools will be auto-disabled for them.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text('Temperature', style: TextStyle(fontSize: 13)),
              ),
              Expanded(
                child: Slider(
                  value: _githubTemperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  label: _githubTemperature.toStringAsFixed(2),
                  onChanged: (v) async {
                    setState(() => _githubTemperature = v);
                    await BackendSettingsRepository.instance
                        .setGithubTemperature(v);
                  },
                ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  _githubTemperature.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TokenCountPicker(
            controller: _githubMaxTokensController,
            presets: TokenCountPicker.maxTokensPresets,
            labelText: 'Max completion tokens',
            hintText: '4096',
            helperText:
                'Reply-length cap only — GitHub Models uses `max_tokens`. The full context window is managed by '
                'the provider. Bigger values just allow longer answers; you are metered per emitted output token.',
            onChanged: _scheduleGithubMaxTokensSave,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _githubTpmLimitController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'TPM limit (0 = unlimited)',
              hintText: '0',
              helperText:
                  'Tokens-per-minute cap applied by the orchestrator. '
                  'GitHub Models has per-tier rate limits — see the catalog table below.',
              suffixText: 'TPM',
            ),
            onChanged: _scheduleGithubTpmLimitSave,
          ),
          const SizedBox(height: 24),
          _githubCatalogTable(),
        ],
      ),
    );
  }

  // Catalog table column geometry — flex units for text columns,
  // fixed pixel widths for the icon-only ones. Tweaking these reflows
  // the whole table without touching the rendering code.
  static const int _kGithubColFlexName = 6;
  static const int _kGithubColFlexPublisher = 3;
  static const int _kGithubColFlexSummary = 11;
  static const int _kGithubColFlexTier = 2;
  static const int _kGithubColFlexMaxIn = 2;
  static const int _kGithubColFlexMaxOut = 2;
  static const double _kGithubColWidthTools = 36;
  static const double _kGithubColWidthPage = 36;

  static const List<Widget> _kGithubCatalogHeaderCells = [
    Expanded(
      flex: _kGithubColFlexName,
      child: Text('Name / ID',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGithubColFlexPublisher,
      child: Text('Publisher',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGithubColFlexSummary,
      child: Text('Summary',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGithubColFlexTier,
      child: Text('Tier',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGithubColFlexMaxIn,
      child: Text('Max in',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.right),
    ),
    SizedBox(width: 8),
    Expanded(
      flex: _kGithubColFlexMaxOut,
      child: Text('Max out',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.right),
    ),
    SizedBox(width: 8),
    SizedBox(
      width: _kGithubColWidthTools,
      child: Text('Tools',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center),
    ),
    SizedBox(width: 8),
    SizedBox(
      width: _kGithubColWidthPage,
      child: Text('Page',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center),
    ),
  ];

  Future<void> _copyGithubCatalog() async {
    if (_githubCatalog.isEmpty) return;
    final buf = StringBuffer()
      ..writeln([
        'id',
        'name',
        'publisher',
        'summary',
        'tier',
        'max_in',
        'max_out',
        'tools',
        'html_url',
      ].join('\t'));
    for (final m in _githubCatalog) {
      buf.writeln([
        m.id,
        m.name,
        m.publisher,
        m.summary.replaceAll('\t', ' ').replaceAll('\n', ' '),
        m.rateLimitTier,
        m.maxInputTokens?.toString() ?? '',
        m.maxOutputTokens?.toString() ?? '',
        GithubModelsService.supportsToolCalling(m) ? 'yes' : 'no',
        m.htmlUrl,
      ].join('\t'));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Copied ${_githubCatalog.length} GitHub models to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _githubCatalogTable() {
    if (_githubCatalog.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _githubLoadingModels
              ? 'Loading catalog…'
              : 'No catalog loaded. Save a PAT or click refresh to fetch '
                  'the model catalog from models.github.ai.',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.list_alt, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Catalog (${_githubCatalog.length} models)',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Copy all rows as TSV',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.copy_all, size: 16),
                  onPressed: _copyGithubCatalog,
                ),
              ],
            ),
          ),
          // Header row — flex-based so it fills the available width and
          // matches each data row's column widths exactly.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              border: Border(
                top: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
                bottom: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: _kGithubCatalogHeaderCells,
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: Scrollbar(
              controller: _githubCatalogScrollController,
              child: ListView.separated(
                controller: _githubCatalogScrollController,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _githubCatalog.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  thickness: 1,
                  color: AppTheme.accentDarkMarrone.withAlpha(30),
                ),
                itemBuilder: (ctx, i) {
                  final m = _githubCatalog[i];
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Name / ID — wraps onto multiple lines.
                        Expanded(
                          flex: _kGithubColFlexName,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.name.isNotEmpty ? m.name : m.id,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                                softWrap: true,
                              ),
                              Text(
                                m.id,
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: AppTheme.textSecondary),
                                softWrap: true,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGithubColFlexPublisher,
                          child: Text(
                            m.publisher,
                            style: const TextStyle(fontSize: 12),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Summary — full-width wrapping, no truncation.
                        Expanded(
                          flex: _kGithubColFlexSummary,
                          child: Text(
                            m.summary,
                            style: const TextStyle(fontSize: 12, height: 1.3),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGithubColFlexTier,
                          child: Text(
                            m.rateLimitTier,
                            style: const TextStyle(fontSize: 12),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGithubColFlexMaxIn,
                          child: Text(
                            m.maxInputTokens?.toString() ?? '—',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kGithubColFlexMaxOut,
                          child: Text(
                            m.maxOutputTokens?.toString() ?? '—',
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kGithubColWidthTools,
                          child: Center(
                            child: Icon(
                              GithubModelsService.supportsToolCalling(m)
                                  ? Icons.check_circle
                                  : Icons.remove_circle_outline,
                              size: 16,
                              color: GithubModelsService.supportsToolCalling(m)
                                  ? Colors.green
                                  : Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kGithubColWidthPage,
                          child: Center(
                            child: IconButton(
                              tooltip: m.htmlUrl.isEmpty
                                  ? 'No marketplace URL'
                                  : 'Copy ${m.htmlUrl} to clipboard',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 28, minHeight: 28),
                              icon: const Icon(Icons.open_in_new, size: 16),
                              onPressed: m.htmlUrl.isEmpty
                                  ? null
                                  : () async {
                                      await Clipboard.setData(
                                          ClipboardData(text: m.htmlUrl));
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Copied URL: ${m.htmlUrl}'),
                                          duration:
                                              const Duration(seconds: 2),
                                        ),
                                      );
                                    },
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _geminiModelOptions() {
    final models = <String>[..._geminiModels];
    final selected = _geminiSelectedModel?.trim() ?? '';
    if (selected.isNotEmpty && !models.contains(selected)) {
      models.insert(0, selected);
    }
    return models;
  }

  Future<void> _addGeminiModel() async {
    final id = _geminiNewModelController.text.trim();
    if (id.isEmpty) return;
    if (_geminiModels.contains(id)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model already in list')),
      );
      return;
    }
    final updated = [..._geminiModels, id];
    await BackendSettingsRepository.instance.setGeminiModels(updated);
    if (!mounted) return;
    setState(() {
      _geminiModels = updated;
      _geminiNewModelController.clear();
    });
  }

  Future<void> _removeGeminiModel(String id) async {
    if (!_geminiModels.contains(id)) return;
    final updated = _geminiModels.where((m) => m != id).toList();
    if (updated.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Keep at least one model')),
      );
      return;
    }
    await BackendSettingsRepository.instance.setGeminiModels(updated);
    String? newSelected = _geminiSelectedModel;
    if (newSelected == id) {
      newSelected = updated.first;
      await BackendSettingsRepository.instance.setGeminiModel(newSelected);
    }
    if (!mounted) return;
    setState(() {
      _geminiModels = updated;
      _geminiSelectedModel = newSelected;
    });
  }

  Widget _geminiControlPanel() {
    final modelOptions = _geminiModelOptions();
    final selectedModel = modelOptions.contains(_geminiSelectedModel) ? _geminiSelectedModel : modelOptions.first;

    return _section(
      title: '✨ Gemini Cloud',
      subtitle: 'Google AI Studio key, Gemini model selector, temperature, '
          'and max tokens. Use this as the overflow agent when Claude is '
          'rate-limited.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _geminiApiKeyController,
            obscureText: !_geminiApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'Gemini API Key',
              hintText: 'AIza...',
              helperText: 'Free key from Google AI Studio.',
              suffixIcon: IconButton(
                icon: Icon(
                  _geminiApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(
                  () => _geminiApiKeyVisible = !_geminiApiKeyVisible,
                ),
              ),
            ),
            onChanged: _scheduleGeminiApiKeySave,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Model', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: selectedModel,
                  items: modelOptions
                      .map(
                        (m) => DropdownMenuItem<String>(
                          value: m,
                          child: Text(m, style: const TextStyle(fontSize: 13)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() => _geminiSelectedModel = v);
                    await BackendSettingsRepository.instance.setGeminiModel(v);
                    if (OrchestratorManager.instance.isRunning) {
                      await OrchestratorManager.instance.stop();
                    }
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _geminiNewModelController,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Add model id',
                    hintText: 'e.g. gemini-2.0-flash',
                  ),
                  onSubmitted: (_) => _addGeminiModel(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Add',
                icon: const Icon(Icons.add, size: 20),
                onPressed: _addGeminiModel,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: _geminiModels
                .map(
                  (m) => InputChip(
                    label: Text(m, style: const TextStyle(fontSize: 12)),
                    onDeleted: () => _removeGeminiModel(m),
                    deleteIconColor: AppTheme.danger,
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text('Temperature', style: TextStyle(fontSize: 13)),
              ),
              Expanded(
                child: Slider(
                  value: _geminiTemperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  label: _geminiTemperature.toStringAsFixed(2),
                  onChanged: (v) async {
                    setState(() => _geminiTemperature = v);
                    await BackendSettingsRepository.instance.setGeminiTemperature(v);
                  },
                ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  _geminiTemperature.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          Text(
            'Lower = more deterministic tool calls. Higher = more varied. '
            'For agent work, 0.1-0.3 is usually the sweet spot.',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),
          TokenCountPicker(
            controller: _geminiMaxTokensController,
            presets: TokenCountPicker.maxTokensPresets,
            labelText: 'Max output tokens',
            hintText: '2048',
            helperText:
                'Reply-length cap only. Gemini handles its own context window (1M on 2.5 Pro, 2M on 1.5 Pro). '
                'You are billed per emitted output token, so raising this does not pre-charge — Gemini 2.5 Pro '
                'can emit up to 64K in one call.',
            onChanged: _scheduleGeminiMaxTokensSave,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _geminiTpmLimitController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'TPM limit (0 = unlimited)',
              hintText: '0',
              helperText: 'Tokens-per-minute cap applied by the orchestrator. Set to stay under the provider/free-tier limit.',
              suffixText: 'TPM',
            ),
            onChanged: _scheduleGeminiTpmLimitSave,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _orchestratorBusy ? null : _installGeminiDeps,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Install google-genai'),
            ),
          ),
          Text(
            'Runs: $pythonExecutableLabel -m pip install --user google-genai',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  String get pythonExecutableLabel =>
      OrchestratorManager.defaultPythonExecutable;

  Widget _generateControlPanel() {
    return _section(
      title: '🦙 Ollama /api/generate',
      subtitle: 'Direct connection to any Ollama-compatible /api/generate endpoint. '
          'Enter a custom port (e.g. localhost:12345) and model name. '
          'Supports native thinking output for reasoning models.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Base URL
          TextField(
            controller: _generateBaseUrlController,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: ApiConstants.ollamaLocalBaseUrl,
              helperText: 'Address of the /api/generate server. '
                  'Include port if non-default, e.g. http://localhost:12345',
            ),
            onChanged: (v) {
              _generateBaseUrlSaveTimer?.cancel();
              _generateBaseUrlSaveTimer = Timer(
                const Duration(milliseconds: 600),
                () => BackendSettingsRepository.instance.setGenerateBaseUrl(v.trim()),
              );
            },
          ),
          const SizedBox(height: 12),

          // Model name
          TextField(
            controller: _generateModelController,
            decoration: const InputDecoration(
              labelText: 'Model',
              hintText: 'e.g. llama3:latest, qwq:32b, deepseek-r1:8b',
              helperText: 'Exact model tag as installed in Ollama.',
            ),
            onChanged: (v) {
              _generateModelSaveTimer?.cancel();
              _generateModelSaveTimer = Timer(
                const Duration(milliseconds: 600),
                () => BackendSettingsRepository.instance.setGenerateModel(v.trim()),
              );
            },
          ),
          const SizedBox(height: 16),

          // API key (optional)
          TextField(
            controller: _generateApiKeyController,
            obscureText: !_generateApiKeyVisible,
            decoration: InputDecoration(
              labelText: 'API Key (optional)',
              hintText: 'Leave empty for local Ollama',
              helperText: 'Bearer token for cloud-hosted Ollama-compatible APIs.',
              suffixIcon: IconButton(
                icon: Icon(
                  _generateApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                ),
                onPressed: () => setState(
                  () => _generateApiKeyVisible = !_generateApiKeyVisible,
                ),
              ),
            ),
            onChanged: (v) => BackendSettingsRepository.instance.setGenerateApiKey(v.trim()),
          ),
          const SizedBox(height: 20),

          // Temperature
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text('Temperature', style: TextStyle(fontSize: 13)),
              ),
              Expanded(
                child: Slider(
                  value: _generateTemperature,
                  min: 0.0,
                  max: 2.0,
                  divisions: 40,
                  label: _generateTemperature.toStringAsFixed(2),
                  onChanged: (v) async {
                    setState(() => _generateTemperature = v);
                    await BackendSettingsRepository.instance.setGenerateTemperature(v);
                  },
                ),
              ),
              SizedBox(
                width: 38,
                child: Text(
                  _generateTemperature.toStringAsFixed(2),
                  style: const TextStyle(fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // num_predict
          TokenCountPicker(
            controller: _generateNumPredictController,
            presets: TokenCountPicker.maxTokensPresets,
            labelText: 'Max tokens (num_predict)',
            hintText: '2048',
            helperText:
                'Cap on the reply only. Must fit inside (num_ctx − prompt − history); '
                'on cloud endpoints you only pay for tokens actually emitted.',
            onChanged: (v) async {
              final n = int.tryParse(v.trim());
              if (n != null && n > 0) {
                await BackendSettingsRepository.instance.setGenerateNumPredict(n);
              }
            },
          ),
          const SizedBox(height: 12),

          // num_ctx
          TokenCountPicker(
            controller: _generateNumCtxController,
            presets: TokenCountPicker.numCtxPresets,
            labelText: 'Context window (num_ctx)',
            hintText: '4096',
            helperText:
                'Total budget for the call (prompt + history + reply). Must comfortably exceed Max tokens — '
                'rule of thumb: keep num_ctx ≥ 4× Max tokens. Default 4096; cloud Ollama models often support 32K+.',
            onChanged: (v) async {
              final n = int.tryParse(v.trim());
              if (n != null && n > 0) {
                await BackendSettingsRepository.instance.setGenerateNumCtx(n);
              }
            },
          ),
          const SizedBox(height: 16),

          // Thinking toggle
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Enable thinking (think: true)',
              style: TextStyle(fontSize: 13),
            ),
            subtitle: const Text(
              'Passes "think": true to the API. Supported by deepseek-r1, qwq, '
              'and other reasoning models. The UI renders the reasoning as a '
              'collapsible "Reasoning" block.',
              style: TextStyle(fontSize: 11),
            ),
            value: _generateThinking,
            onChanged: (v) async {
              setState(() => _generateThinking = v);
              await BackendSettingsRepository.instance.setGenerateThinking(v);
            },
          ),
        ],
      ),
    );
  }

  void _scheduleOllamaApiKeySave(String value) {
    _ollamaApiKeySaveTimer?.cancel();
    _ollamaApiKeySaveTimer = Timer(const Duration(milliseconds: 600), () async {
      await BackendSettingsRepository.instance.setOllamaApiKey(value.trim());
    });
  }

  /// Persistently sets OLLAMA_API_KEY in the user's environment.
  /// Windows: setx (user scope). Linux/macOS: appends export to shell rc file.
  Future<void> _exportOllamaApiKeyToEnv() async {
    final key = _ollamaApiKeyController.text.trim();
    if (key.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('API key is empty — nothing to set.')),
        );
      }
      return;
    }

    String? errorMsg;

    if (Platform.isWindows) {
      final result = await Process.run('setx', ['OLLAMA_API_KEY', key]);
      if (result.exitCode != 0) {
        errorMsg = result.stderr.toString().trim();
        if (errorMsg.isEmpty) errorMsg = 'setx exited with ${result.exitCode}';
      }
    } else {
      // Linux / macOS — append to the first rc file that exists.
      final home = Platform.environment['HOME'] ?? '';
      final candidates = [
        '$home/.zshrc',
        '$home/.bashrc',
        '$home/.bash_profile',
        '$home/.profile',
      ];
      final rc = candidates.map((p) => File(p)).firstWhere(
            (f) => f.existsSync(),
            orElse: () => File(candidates.first),
          );
      final line = '\nexport OLLAMA_API_KEY="$key"';
      final existing = rc.existsSync() ? rc.readAsStringSync() : '';
      if (existing.contains('OLLAMA_API_KEY=')) {
        // Replace existing assignment.
        final updated = existing.replaceAll(
          RegExp(r'\nexport OLLAMA_API_KEY="[^"]*"'),
          line,
        );
        rc.writeAsStringSync(updated);
      } else {
        rc.writeAsStringSync(existing + line);
      }
    }

    if (!mounted) return;
    if (errorMsg != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to set env var: $errorMsg')),
      );
    } else {
      final where = Platform.isWindows ? 'user environment (restart apps to pick it up)' : '~/.zshrc / ~/.bashrc (re-open terminal to pick it up)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OLLAMA_API_KEY saved to $where')),
      );
    }
  }

  void _scheduleOllamaPythonUrlSave(String value) {
    _ollamaPythonUrlSaveTimer?.cancel();
    _ollamaPythonUrlSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final v = value.trim();
      if (v.isEmpty) return;
      await BackendSettingsRepository.instance.setOllamaPythonBridgeUrl(v);
    });
  }

  Future<void> _load() async {
    final token = await SettingsRepository.instance.getHfToken();
    final selected = await SettingsRepository.instance.getSelectedModelId();
    final models = await ModelRepository.instance.listAll();
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    final serverUrl = await BackendSettingsRepository.instance.getLocalServerUrl();
    final agentCreds = await AgentCredentialsRepository.instance.getCredentials();
    final ollamaUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();
    final ollamaModel = await BackendSettingsRepository.instance.getOllamaModel();
    final ollamaPythonBridgeUrl = await BackendSettingsRepository.instance.getOllamaPythonBridgeUrl();
    final ollamaTemperature = await BackendSettingsRepository.instance.getOllamaTemperature();
    final ollamaNumPredict = await BackendSettingsRepository.instance.getOllamaNumPredict();
    final ollamaNumCtx = await BackendSettingsRepository.instance.getOllamaNumCtx();
    final ollamaApiKey = await BackendSettingsRepository.instance.getOllamaApiKey();
    final groqApiKey = await BackendSettingsRepository.instance.getGroqApiKey();
    final groqModel = await BackendSettingsRepository.instance.getGroqModel();
    final groqTemperature = await BackendSettingsRepository.instance.getGroqTemperature();
    final groqMaxTokens = await BackendSettingsRepository.instance.getGroqMaxTokens();
    final groqTpmLimit = await BackendSettingsRepository.instance.getGroqTpmLimit();
    final geminiApiKey = await BackendSettingsRepository.instance.getGeminiApiKey();
    final geminiModel = await BackendSettingsRepository.instance.getGeminiModel();
    final geminiModels = await BackendSettingsRepository.instance.getGeminiModels();
    final geminiTemperature = await BackendSettingsRepository.instance.getGeminiTemperature();
    final geminiMaxTokens = await BackendSettingsRepository.instance.getGeminiMaxTokens();
    final geminiTpmLimit = await BackendSettingsRepository.instance.getGeminiTpmLimit();
    final openRouterApiKey = await BackendSettingsRepository.instance.getOpenRouterApiKey();
    final openRouterModel = await BackendSettingsRepository.instance.getOpenRouterModel();
    final openRouterTemperature = await BackendSettingsRepository.instance.getOpenRouterTemperature();
    final openRouterMaxTokens = await BackendSettingsRepository.instance.getOpenRouterMaxTokens();
    final openRouterTpmLimit = await BackendSettingsRepository.instance.getOpenRouterTpmLimit();
    final githubApiKey = await BackendSettingsRepository.instance.getGithubApiKey();
    final githubModel = await BackendSettingsRepository.instance.getGithubModel();
    final githubTemperature = await BackendSettingsRepository.instance.getGithubTemperature();
    final githubMaxTokens = await BackendSettingsRepository.instance.getGithubMaxTokens();
    final githubTpmLimit = await BackendSettingsRepository.instance.getGithubTpmLimit();
    final genBaseUrl = await BackendSettingsRepository.instance.getGenerateBaseUrl();
    final genModel = await BackendSettingsRepository.instance.getGenerateModel();
    final genApiKey = await BackendSettingsRepository.instance.getGenerateApiKey();
    final genTemperature = await BackendSettingsRepository.instance.getGenerateTemperature();
    final genNumPredict = await BackendSettingsRepository.instance.getGenerateNumPredict();
    final genNumCtx = await BackendSettingsRepository.instance.getGenerateNumCtx();
    final genThinking = await BackendSettingsRepository.instance.getGenerateThinking();

    if (!mounted) return;
    setState(() {
      _tokenController.text = token ?? "";
      _agentTokenController.text = agentCreds?.hfToken ?? "";
      _selectedModelId = selected ?? '';
      _models = models;
      _activeBackend = backend;
      _localServerUrl = serverUrl;
      _localServerUrlController.text = serverUrl ?? "";
      _ollamaUrlController.text = ollamaUrl ?? OllamaService.defaultBaseUrl;
      _ollamaSelectedModel = ollamaModel;
      _ollamaPythonUrlController.text = ollamaPythonBridgeUrl ?? OllamaPythonManager.defaultBridgeUrl;
      _ollamaTemperature = ollamaTemperature;
      _ollamaNumPredict = ollamaNumPredict;
      _ollamaNumCtxValue = ollamaNumCtx;
      _ollamaNumPredictController.text = ollamaNumPredict.toString();
      _ollamaNumCtxController.text = ollamaNumCtx.toString();
      _ollamaApiKeyController.text = ollamaApiKey ?? '';
      _groqApiKeyController.text = groqApiKey ?? '';
      _groqSelectedModel = groqModel ?? GroqService.fallbackModels.first;
      _groqTemperature = groqTemperature;
      _groqMaxTokensController.text = groqMaxTokens.toString();
      _groqTpmLimitController.text = groqTpmLimit.toString();
      _geminiApiKeyController.text = geminiApiKey ?? '';
      _geminiModels = geminiModels;
      _geminiSelectedModel = (geminiModel == null || geminiModel.trim().isEmpty) ? BackendSettingsRepository.defaultGeminiModel : geminiModel.trim();
      _geminiTemperature = geminiTemperature;
      _geminiMaxTokensController.text = geminiMaxTokens.toString();
      _geminiTpmLimitController.text = geminiTpmLimit.toString();
      _openRouterApiKeyController.text = openRouterApiKey ?? '';
      _openRouterSelectedModel = openRouterModel;
      _openRouterTemperature = openRouterTemperature;
      _openRouterMaxTokensController.text = openRouterMaxTokens.toString();
      _openRouterTpmLimitController.text = openRouterTpmLimit.toString();
      _githubApiKeyController.text = githubApiKey ?? '';
      _githubSelectedModel = (githubModel == null || githubModel.isEmpty)
          ? GithubModelsService.fallbackModels.first
          : githubModel;
      _githubTemperature = githubTemperature;
      _githubMaxTokensController.text = githubMaxTokens.toString();
      _githubTpmLimitController.text = githubTpmLimit.toString();
      _generateBaseUrlController.text = genBaseUrl ?? OllamaGenerateService.defaultBaseUrl;
      _generateModelController.text = genModel ?? '';
      _generateApiKeyController.text = genApiKey ?? '';
      _generateTemperature = genTemperature;
      _generateNumPredictController.text = genNumPredict.toString();
      _generateNumCtxController.text = genNumCtx.toString();
      _generateThinking = genThinking;
      _loading = false;
    });

    if (backend == LlmBackend.ollama || backend == LlmBackend.ollamaPython || backend == LlmBackend.ollamaOrchestrator) {
      // ignore: unawaited_futures
      _refreshOllamaStatus();
    }
    if (backend == LlmBackend.ollamaPython) {
      // ignore: unawaited_futures
      _refreshOllamaPythonStatus();
    }
    if ((backend == LlmBackend.groq || backend == LlmBackend.groqOrchestrator) && (groqApiKey ?? '').isNotEmpty) {
      // ignore: unawaited_futures
      _refreshGroqModels(groqApiKey!);
    }
    // Always load the OpenRouter catalog when a key exists, regardless of
    // the active backend — populates both the dropdown and the table.
    if ((openRouterApiKey ?? '').isNotEmpty) {
      // ignore: unawaited_futures
      _refreshOpenRouterModels(openRouterApiKey!);
    }
    if (backend == LlmBackend.githubOrchestrator &&
        (githubApiKey ?? '').isNotEmpty) {
      // ignore: unawaited_futures
      _refreshGithubCatalog(githubApiKey!);
    }
  }

  Future<void> _saveToken() async {
    final value = _tokenController.text.trim();
    await SettingsRepository.instance.setHfToken(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Token saved")),
    );
  }

  Future<void> _addModel() async {
    final id = _newModelController.text.trim();
    if (id.isEmpty) return;

    final exists = _models.any((m) => m.id == id);
    if (exists) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Model already saved")),
      );
      return;
    }
    await ModelRepository.instance.upsert(
      HfModel(
        id: id,
        name: id,
        isFavorite: false,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    _newModelController.clear();
    await _load();
  }

  Future<void> _deleteModel(HfModel m) async {
    await ModelRepository.instance.delete(m.id);
    if (_selectedModelId == m.id) {
      await SettingsRepository.instance.setSelectedModelId('');
      _selectedModelId = '';
    }
    await _load();
  }

  Future<void> _setSelected(String id) async {
    await SettingsRepository.instance.setSelectedModelId(id);
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }
    if (!mounted) return;
    setState(() => _selectedModelId = id);
  }

  Future<void> _toggleFavorite(HfModel m) async {
    await ModelRepository.instance.setFavorite(m.id, !m.isFavorite);
    await _load();
  }

  Future<void> _editModel(HfModel m) async {
    final controller = TextEditingController(text: m.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Edit model name"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: "Model name"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == m.name) return;

    await ModelRepository.instance.upsert(m.copyWith(name: newName));
    await _load();
  }

  Future<void> _testLocalServer() async {
    if (_localServerUrl == null || _localServerUrl!.isEmpty) return;

    final isAvailable = await LlmService.instance.checkAvailability(
      backend: LlmBackend.local,
      localServerUrl: _localServerUrl,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isAvailable ? "✓ Server is reachable" : "✗ Server not reachable. Check URL and ensure server is running.",
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: isAvailable ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      _orchestratorLog.add(line);
      if (_orchestratorLog.length > 500) {
        _orchestratorLog.removeRange(0, _orchestratorLog.length - 500);
      }
    });
    _appendToLogFile(line);
  }

  Future<void> _installOrchestratorDeps() async {
    if (_orchestratorBusy) return;
    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Installing orchestrator dependencies...');
    final ok = await OrchestratorManager.instance.installDependencies(
      onLine: _appendLog,
    );
    _appendLog(ok ? '✓ Dependencies installed.' : '✗ Installation failed.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '✓ Dependencies installed' : '✗ Install failed — see log'),
        backgroundColor: ok ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _installGeminiDeps() async {
    if (_orchestratorBusy) return;
    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Installing google-genai...');
    final ok = await OrchestratorManager.instance.installPackage(
      'google-genai',
      onLine: _appendLog,
    );
    _appendLog(ok ? '✓ google-genai installed.' : '✗ Installation failed.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '✓ google-genai installed' : '✗ Install failed — see log'),
        backgroundColor: ok ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _startOrchestrator() async {
    if (_orchestratorBusy) return;
    if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend == OrchestratorBackend.huggingface) {
      return;
    }

    final token = _agentTokenController.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the HF agent token first.')),
      );
      return;
    }
    // Persist it in case the user hasn't pressed Save.
    await AgentCredentialsRepository.instance.saveCredentials(AgentCredentials(hfToken: token));

    if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != OrchestratorBackend.huggingface) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting orchestrator...');
    final started = await OrchestratorManager.instance.start(
      hfToken: token,
      modelId: _selectedModelId,
    );
    final stderr = OrchestratorManager.instance.stderrLog;
    if (stderr.isNotEmpty) {
      for (final l in const LineSplitter().convert(stderr)) {
        _appendLog(l);
      }
    }
    _appendLog(started ? '✓ Orchestrator running.' : '✗ Orchestrator failed to start.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started ? '✓ Orchestrator running' : '✗ Failed to start — check log'),
        backgroundColor: started ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _stopOrchestrator() async {
    if (_orchestratorBusy) return;
    if (!OrchestratorManager.instance.isRunning) return;
    setState(() => _orchestratorBusy = true);
    await OrchestratorManager.instance.stop();
    _appendLog('Orchestrator stopped.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
  }

  Future<void> _startGroqOrchestrator() async {
    if (_orchestratorBusy) return;
    final apiKey = _groqApiKeyController.text.trim();
    final envGroqKey = Platform.environment['GROQ_API_KEY'] ?? '';
    if (apiKey.isEmpty && envGroqKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the Groq API key first.')),
      );
      return;
    }
    final model = _groqSelectedModel ?? GroqService.fallbackModels.first;

    if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != OrchestratorBackend.groq) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting Groq orchestrator (model: $model)…');

    final temperature = _groqTemperature;
    final maxTokens = int.tryParse(_groqMaxTokensController.text.trim()) ?? BackendSettingsRepository.defaultGroqMaxTokens;

    final started = await OrchestratorManager.instance.start(
      backend: OrchestratorBackend.groq,
      modelId: model,
      groqApiKey: apiKey,
      temperature: temperature,
      maxTokens: maxTokens,
    );
    final stderr = OrchestratorManager.instance.stderrLog;
    if (stderr.isNotEmpty) {
      for (final l in const LineSplitter().convert(stderr)) {
        _appendLog(l);
      }
    }
    _appendLog(started ? '✓ Groq orchestrator running.' : '✗ Failed to start Groq orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started ? '✓ Groq orchestrator running' : '✗ Failed to start — check log'),
        backgroundColor: started ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _startGeminiOrchestrator() async {
    if (_orchestratorBusy) return;
    final apiKey = _geminiApiKeyController.text.trim();
    final envGeminiKey = Platform.environment['GOOGLE_API_KEY'] ?? Platform.environment['GEMINI_API_KEY'] ?? '';
    if (apiKey.isEmpty && envGeminiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the Gemini API key first.')),
      );
      return;
    }
    final model = (_geminiSelectedModel != null && _geminiSelectedModel!.trim().isNotEmpty) ? _geminiSelectedModel!.trim() : BackendSettingsRepository.defaultGeminiModel;

    if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != OrchestratorBackend.gemini) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting Gemini orchestrator (model: $model)…');

    final started = await OrchestratorManager.instance.start(
      backend: OrchestratorBackend.gemini,
      modelId: model,
      geminiApiKey: apiKey,
      temperature: _geminiTemperature,
      maxTokens: int.tryParse(_geminiMaxTokensController.text.trim()) ?? BackendSettingsRepository.defaultGeminiMaxTokens,
    );
    final stderr = OrchestratorManager.instance.stderrLog;
    if (stderr.isNotEmpty) {
      for (final l in const LineSplitter().convert(stderr)) {
        _appendLog(l);
      }
    }
    _appendLog(started ? '✓ Gemini orchestrator running.' : '✗ Failed to start Gemini orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started ? '✓ Gemini orchestrator running' : '✗ Failed to start — check log'),
        backgroundColor: started ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _startOllamaOrchestrator() async {
    if (_orchestratorBusy) return;
    final model = _ollamaSelectedModel;
    if (model == null || model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pull and select an Ollama model first.'),
        ),
      );
      return;
    }

    if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != OrchestratorBackend.ollama) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting Ollama orchestrator...');
    final started = await OrchestratorManager.instance.start(
      backend: OrchestratorBackend.ollama,
      modelId: model,
      ollamaBaseUrl: _ollamaBaseUrl,
      ollamaNumCtx: _ollamaNumCtxValue,
      temperature: _ollamaTemperature,
      maxTokens: _ollamaNumPredict,
      ollamaApiKey: _ollamaApiKeyController.text.trim(),
    );
    final stderr = OrchestratorManager.instance.stderrLog;
    if (stderr.isNotEmpty) {
      for (final l in const LineSplitter().convert(stderr)) {
        _appendLog(l);
      }
    }
    _appendLog(started ? 'Ollama orchestrator running.' : 'Failed to start Ollama orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started ? 'Ollama orchestrator running' : 'Failed to start Ollama orchestrator'),
        backgroundColor: started ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Ollama actions
  // ---------------------------------------------------------------------------

  String get _ollamaBaseUrl {
    final v = _ollamaUrlController.text.trim();
    return v.isEmpty ? OllamaService.defaultBaseUrl : v;
  }

  String get _ollamaPythonBridgeUrl {
    final v = _ollamaPythonUrlController.text.trim();
    return v.isEmpty ? OllamaPythonManager.defaultBridgeUrl : v;
  }

  void _appendOllamaLog(String line) {
    if (!mounted) return;
    setState(() {
      _ollamaLog.add(line);
      if (_ollamaLog.length > 500) {
        _ollamaLog.removeRange(0, _ollamaLog.length - 500);
      }
    });
  }

  void _appendOllamaPythonLog(String line) {
    if (!mounted) return;
    setState(() {
      _ollamaPythonLog.add(line);
      if (_ollamaPythonLog.length > 500) {
        _ollamaPythonLog.removeRange(0, _ollamaPythonLog.length - 500);
      }
    });
  }

  /// Detects the Ollama binary, probes the server, and refreshes the
  /// installed-models list. Safe to call any time — never throws.
  Future<void> _refreshOllamaStatus({bool verbose = false}) async {
    final version = await OllamaManager.instance.detectBinary();
    final apiKey = _ollamaApiKeyController.text.trim();
    final up = await OllamaService.instance.isServerReachable(baseUrl: _ollamaBaseUrl, apiKey: apiKey);
    List<String> installed = const [];
    if (up) {
      try {
        installed = await OllamaService.instance.listInstalledModels(baseUrl: _ollamaBaseUrl, apiKey: apiKey);
      } catch (e) {
        if (verbose) _appendOllamaLog('list models failed: $e');
      }
    }

    String? resolvedModel = _ollamaSelectedModel;
    if (resolvedModel == null && installed.isNotEmpty) {
      resolvedModel = installed.first;
      await BackendSettingsRepository.instance.setOllamaModel(resolvedModel);
    } else if (resolvedModel != null && !installed.contains(resolvedModel)) {
      resolvedModel = installed.isNotEmpty ? installed.first : null;
      if (resolvedModel != null) {
        await BackendSettingsRepository.instance.setOllamaModel(resolvedModel);
      }
    }

    if (!mounted) return;
    setState(() {
      _ollamaBinaryVersion = version;
      _ollamaServerUp = up;
      _ollamaInstalledModels = installed;
      _ollamaSelectedModel = resolvedModel;
    });

    // Fire-and-forget the rich catalog fetch (tags + show fan-out). The
    // simple installed list is already populated above, so the dropdown
    // works immediately even if `/api/show` is slow.
    if (up) {
      // ignore: unawaited_futures
      _refreshOllamaCatalog();
    } else if (mounted) {
      setState(() => _ollamaCatalog = const []);
    }
  }

  Future<void> _refreshOllamaCatalog() async {
    if (!mounted) return;
    setState(() => _ollamaCatalogLoading = true);
    final apiKey = _ollamaApiKeyController.text.trim();
    List<OllamaCatalogModel> catalog = const [];
    try {
      catalog = await OllamaService.instance.listCatalog(
        baseUrl: _ollamaBaseUrl,
        apiKey: apiKey,
      );
    } catch (e) {
      _appendOllamaLog('catalog fetch failed: $e');
    }
    if (!mounted) return;
    setState(() {
      _ollamaCatalog = catalog;
      _ollamaCatalogLoading = false;
    });
  }

  Future<void> _refreshOllamaLibrary() async {
    if (!mounted) return;
    setState(() {
      _ollamaLibraryLoading = true;
      _ollamaLibraryError = null;
    });
    try {
      final lib = await OllamaLibraryService.instance.fetchLibrary();
      if (!mounted) return;
      setState(() {
        _ollamaLibrary = lib;
        _ollamaLibraryLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ollamaLibraryError = e.toString();
        _ollamaLibraryLoading = false;
      });
    }
  }

  Future<void> _refreshOllamaPythonStatus({bool verbose = false}) async {
    final pythonVersion = await OllamaPythonManager.instance.detectPythonVersion();
    final packageVersion = await OllamaPythonManager.instance.detectPackageVersion();
    final bridgeUp = await OllamaPythonManager.instance.isBridgeReachable(bridgeUrl: _ollamaPythonBridgeUrl);
    if (verbose && pythonVersion == null) {
      _appendOllamaPythonLog('Python was not found on PATH.');
    }
    if (verbose && pythonVersion != null && packageVersion == null) {
      _appendOllamaPythonLog(
        'Python detected, but package `ollama` is not installed yet.',
      );
    }
    if (!mounted) return;
    setState(() {
      _pythonVersion = pythonVersion;
      _ollamaPythonPackageVersion = packageVersion;
      _ollamaPythonBridgeUp = bridgeUp;
    });
  }

  Future<void> _installOllamaBinary() async {
    if (_ollamaBusy) return;
    setState(() {
      _ollamaBusy = true;
      _ollamaLog.clear();
    });
    final ok = await OllamaManager.instance.installBinary(
      onLine: _appendOllamaLog,
    );
    await _refreshOllamaStatus(verbose: true);
    if (!mounted) return;
    setState(() => _ollamaBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Ollama installed successfully' : 'Ollama install failed - see log'),
        backgroundColor: ok ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _startOllamaServer() async {
    if (_ollamaBusy) return;
    setState(() {
      _ollamaBusy = true;
      _ollamaLog.clear();
    });
    _appendOllamaLog('Checking Ollama installation…');
    final ok = await OllamaManager.instance.startServer(
      baseUrl: _ollamaBaseUrl,
      onLine: _appendOllamaLog,
    );
    await _refreshOllamaStatus();
    if (!mounted) return;
    setState(() => _ollamaBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '✓ Ollama server is ready' : '✗ Ollama server failed to start — see log'),
        backgroundColor: ok ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _stopOllamaServer() async {
    if (_ollamaBusy) return;
    if (!OllamaManager.instance.isManagingProcess) {
      _appendOllamaLog('Not managing an ollama subprocess — nothing to stop. '
          '(If ollama was started externally, stop it in its own terminal.)');
      return;
    }
    setState(() => _ollamaBusy = true);
    await OllamaManager.instance.stopServer(onLine: _appendOllamaLog);
    await _refreshOllamaStatus();
    if (!mounted) return;
    setState(() => _ollamaBusy = false);
  }

  Future<void> _pullOllamaModel() async {
    if (_ollamaBusy) return;
    final name = _ollamaPullController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a model name, e.g. llama3 or qwen2.5-coder:7b')),
      );
      return;
    }
    if (!_ollamaServerUp) {
      _appendOllamaLog('Server not reachable. Start it first ("Start Ollama server").');
      return;
    }
    final token = CancelToken();
    setState(() {
      _ollamaBusy = true;
      _ollamaPullCancelToken = token;
      _ollamaPullingModel = name;
      _ollamaPullCompleted = 0;
      _ollamaPullTotal = 0;
      _ollamaPullCancelled = false;
    });
    _appendOllamaLog('Pulling "$name"… this may take several minutes.');
    try {
      await OllamaService.instance.pullModel(
        name,
        baseUrl: _ollamaBaseUrl,
        onProgress: _appendOllamaLog,
        onBytes: (completed, total) {
          if (!mounted) return;
          // Avoid spamming setState — only rebuild when the percentage
          // actually changes by at least one point (or transfer finishes).
          final prevPct = _ollamaPullTotal > 0
              ? (_ollamaPullCompleted * 100 / _ollamaPullTotal).floor()
              : -1;
          final nextPct = total > 0 ? (completed * 100 / total).floor() : -1;
          if (nextPct != prevPct || completed == total) {
            setState(() {
              _ollamaPullCompleted = completed;
              _ollamaPullTotal = total;
            });
          }
        },
        cancelToken: token,
      );
      _appendOllamaLog('✓ "$name" downloaded.');
      _ollamaPullController.clear();
      await _refreshOllamaStatus();
      // Auto-select the freshly pulled model if none was selected.
      if (_ollamaSelectedModel == null && _ollamaInstalledModels.isNotEmpty) {
        await _setOllamaModel(_ollamaInstalledModels.first);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Model "$name" pulled'),
            backgroundColor: AppTheme.accentMarrone,
          ),
        );
      }
    } catch (e) {
      // Cancellation is expected — don't surface as a failure.
      if (_ollamaPullCancelled || token.isCancelled) {
        _appendOllamaLog('⏹ Pull of "$name" cancelled by user.');
        // Best-effort cleanup of any partial blobs the daemon kept.
        try {
          await OllamaService.instance.deleteModel(
            name,
            baseUrl: _ollamaBaseUrl,
          );
          _appendOllamaLog('   Cleaned up partial download.');
        } catch (delErr) {
          // Manifest probably wasn't written yet — Ollama returns 404,
          // and the blobs will be garbage-collected next pull.
          _appendOllamaLog('   (no manifest to delete: $delErr)');
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Pull of "$name" cancelled'),
              backgroundColor: AppTheme.textMuted,
            ),
          );
        }
      } else {
        _appendOllamaLog('✗ Pull failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✗ Pull failed: $e'),
              backgroundColor: AppTheme.danger,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _ollamaBusy = false;
          _ollamaPullCancelToken = null;
          _ollamaPullingModel = null;
          _ollamaPullCompleted = 0;
          _ollamaPullTotal = 0;
          _ollamaPullCancelled = false;
        });
      }
      // Refresh the catalog whether we succeeded or cancelled — installed
      // models may have shifted (deletion above can drop the row).
      // ignore: unawaited_futures
      _refreshOllamaStatus();
    }
  }

  /// Abort the in-progress pull. The HTTP stream is closed via [CancelToken];
  /// the `_pullOllamaModel` `catch` branch then deletes the partial model.
  void _cancelOllamaPull() {
    final token = _ollamaPullCancelToken;
    if (token == null || token.isCancelled) return;
    setState(() => _ollamaPullCancelled = true);
    token.cancel('user cancelled');
    _appendOllamaLog('Cancelling download…');
  }

  Widget _ollamaPullProgressBar() {
    final hasTotal = _ollamaPullTotal > 0;
    final pct = hasTotal
        ? (_ollamaPullCompleted * 100 / _ollamaPullTotal)
        : null;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Pulling ${_ollamaPullingModel ?? ''}'
                  '${_ollamaPullCancelled ? ' — cancelling…' : ''}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (hasTotal)
                Text(
                  '${_formatBytes(_ollamaPullCompleted)} / '
                  '${_formatBytes(_ollamaPullTotal)}'
                  '  •  ${pct!.toStringAsFixed(1)}%',
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textSecondary),
                ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: hasTotal ? (pct! / 100).clamp(0.0, 1.0) : null,
              minHeight: 6,
              backgroundColor: AppTheme.bgSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteOllamaModel(String name) async {
    if (_ollamaBusy) return;
    if (!_ollamaServerUp) {
      _appendOllamaLog('Server not reachable. Start it first.');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model'),
        content: Text(
          'Remove "$name" from Ollama? This frees disk space and cannot '
          'be undone — you\'ll need to pull it again to use it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _ollamaBusy = true);
    _appendOllamaLog('Deleting "$name"…');
    try {
      await OllamaService.instance.deleteModel(name, baseUrl: _ollamaBaseUrl);
      _appendOllamaLog('✓ "$name" deleted.');
      // Clear the stored default if we just removed it.
      if (_ollamaSelectedModel == name) {
        await BackendSettingsRepository.instance.setOllamaModel('');
        if (mounted) setState(() => _ollamaSelectedModel = null);
      }
      await _refreshOllamaStatus();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ Model "$name" deleted'),
            backgroundColor: AppTheme.accentMarrone,
          ),
        );
      }
    } catch (e) {
      _appendOllamaLog('✗ Delete failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✗ Delete failed: $e'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _ollamaBusy = false);
    }
  }

  Future<void> _setOllamaModel(String name) async {
    await BackendSettingsRepository.instance.setOllamaModel(name);
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }
    if (!mounted) return;
    setState(() => _ollamaSelectedModel = name);
  }

  // ---- Generation parameters (temperature / num_predict / num_ctx) ---------

  void _onTemperatureChanged(double v) {
    // Temperature gets a slider, so persist immediately — no debounce needed.
    setState(() => _ollamaTemperature = v);
    // ignore: unawaited_futures
    BackendSettingsRepository.instance.setOllamaTemperature(v);
  }

  void _scheduleNumPredictSave(String value) {
    _ollamaNumPredictSaveTimer?.cancel();
    _ollamaNumPredictSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final parsed = int.tryParse(value.trim());
      if (parsed == null || parsed <= 0) return;
      setState(() => _ollamaNumPredict = parsed);
      await BackendSettingsRepository.instance.setOllamaNumPredict(parsed);
    });
  }

  void _scheduleNumCtxSave(String value) {
    _ollamaNumCtxSaveTimer?.cancel();
    _ollamaNumCtxSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final parsed = int.tryParse(value.trim());
      if (parsed == null || parsed <= 0) return;
      setState(() => _ollamaNumCtxValue = parsed);
      await BackendSettingsRepository.instance.setOllamaNumCtx(parsed);
    });
  }

  Future<void> _resetOllamaGenParams() async {
    setState(() {
      _ollamaTemperature = BackendSettingsRepository.defaultOllamaTemperature;
      _ollamaNumPredict = BackendSettingsRepository.defaultOllamaNumPredict;
      _ollamaNumCtxValue = BackendSettingsRepository.defaultOllamaNumCtx;
      _ollamaNumPredictController.text = _ollamaNumPredict.toString();
      _ollamaNumCtxController.text = _ollamaNumCtxValue.toString();
    });
    await BackendSettingsRepository.instance.setOllamaTemperature(_ollamaTemperature);
    await BackendSettingsRepository.instance.setOllamaNumPredict(_ollamaNumPredict);
    await BackendSettingsRepository.instance.setOllamaNumCtx(_ollamaNumCtxValue);
  }

  /// Compact, multi-section helper text used under each generation knob.
  /// Split into "What it does / Normal range / Best for / Example" so users
  /// can scan instead of reading a wall of grey text. Shown with tiny muted
  /// typography so it doesn't dominate the form.
  Widget _helperBlock({
    required String what,
    required String normalRange,
    required List<String> bestFor,
    String? example,
  }) {
    const label = TextStyle(
      color: AppTheme.textMuted,
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
    );
    const body = TextStyle(color: AppTheme.textMuted, fontSize: 11.5);
    return Padding(
      padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(what, style: body),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Normal: ', style: label),
              Expanded(child: Text(normalRange, style: body)),
            ],
          ),
          const SizedBox(height: 2),
          const Text('Best for:', style: label),
          for (final line in bestFor)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 1),
              child: Text('• $line', style: body),
            ),
          if (example != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Example: ', style: label),
                Expanded(
                  child: Text(
                    example,
                    style: body.copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOllamaGenParams() {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
        initiallyExpanded: true,
        title: const Text(
          'Generation parameters',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        subtitle: Text(
          'temp=${_ollamaTemperature.toStringAsFixed(2)}   '
          'max_tokens=$_ollamaNumPredict   '
          'ctx=$_ollamaNumCtxValue',
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 11.5),
        ),
        children: [
          // ---- Temperature ------------------------------------------------
          Row(
            children: [
              const SizedBox(
                width: 110,
                child: Text('Temperature', style: TextStyle(fontSize: 12.5)),
              ),
              Expanded(
                child: Slider(
                  value: _ollamaTemperature.clamp(0.0, 1.5),
                  min: 0.0,
                  max: 1.5,
                  divisions: 30,
                  label: _ollamaTemperature.toStringAsFixed(2),
                  onChanged: _onTemperatureChanged,
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  _ollamaTemperature.toStringAsFixed(2),
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
          ),
          _helperBlock(
            what: 'Controls how random the model is when picking the next word. '
                '0 = always the most likely token (deterministic); higher = '
                'more varied, more creative, more likely to go off-script.',
            normalRange: '0.0 – 1.5 (Ollama default 0.8, this app default 0.2)',
            bestFor: [
              '0.0–0.2 — coding, tool calls, JSON output, anything where '
                  'structure matters. Recommended for the orchestrator.',
              '0.3–0.5 — balanced Q&A, explanations.',
              '0.6–0.9 — brainstorming, writing, chit-chat.',
              '> 1.0 — rarely useful; output gets incoherent fast.',
            ],
            example: 'Small models (phi3, llama3.2:3b) follow tool protocols '
                'much more reliably at 0.2 than at 0.7.',
          ),
          const SizedBox(height: 14),

          // ---- num_predict + num_ctx --------------------------------------
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TokenCountPicker(
                  controller: _ollamaNumPredictController,
                  presets: TokenCountPicker.maxTokensPresets,
                  labelText: 'Max output tokens (num_predict)',
                  helperText: 'Reply cap — must fit inside num_ctx.',
                  onChanged: _scheduleNumPredictSave,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TokenCountPicker(
                  controller: _ollamaNumCtxController,
                  presets: TokenCountPicker.numCtxPresets,
                  labelText: 'Context window (num_ctx)',
                  hintText: 'e.g. 4096',
                  helperText: 'Total budget — keep ≥ 4× Max tokens.',
                  onChanged: _scheduleNumCtxSave,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _helperBlock(
            what: 'num_predict caps the REPLY length only — the model is forced '
                'to stop after this many tokens. On cloud Ollama (ollama.com '
                'cloud) and other cloud providers you are billed per token '
                'actually emitted, so raising this does NOT pre-charge you; '
                'it just allows longer answers. On local models it gates how '
                'long a runaway generation can keep your CPU/GPU busy.',
            normalRange: '256 – 8192 (default 2048). ~1 token ≈ 0.75 English '
                'words or ~3 characters of code. Frontier cloud models (Claude, '
                'Gemini) can emit up to 64K in one call.',
            bestFor: [
              '256–512 — short replies, tool calls, quick classification.',
              '1024–2048 — typical coding answers, a single file edit, '
                  'explanations (the app default).',
              '4096–8192 — long essays, whole-file rewrites. On a small local '
                  'model this can take several minutes; on a cloud model it '
                  'just costs proportionally more output tokens.',
              '16384+ — only useful with frontier cloud models (Claude, '
                  'Gemini). Most local 3B–7B models will never emit this much '
                  'cleanly.',
            ],
            example: 'Must fit inside num_ctx − (system prompt + history + '
                'tool defs). If num_predict ≥ num_ctx the model has no room '
                'to read your prompt and will fail or truncate.',
          ),
          const SizedBox(height: 10),
          _helperBlock(
            what: 'num_ctx is the TOTAL budget for one call — system prompt + '
                'tool defs + chat history + your message + the reply, all '
                'combined. Cloud providers (Groq, OpenRouter, Gemini, GitHub '
                'Models) manage this internally and ignore the field; it only '
                'takes effect on Ollama backends. On local Ollama, KV-cache '
                'RAM grows roughly linearly with it; on cloud Ollama, larger '
                'windows just slow the prompt-eval step.',
            normalRange: '2048 – 32768 for local (default 4096). Cloud-hosted '
                'Ollama models often advertise 128K+. Frontier non-Ollama '
                'cloud models (Claude 200K, Gemini 1M) handle this themselves.',
            bestFor: [
              '2048 — chit-chat, single-file reads. Lowest RAM.',
              '4096 — app default, fits a few read_file results + history.',
              '8192–16384 — multi-file edits, reading large config/log '
                  'files. Needs a 7B+ model and ≥ 16 GB RAM locally.',
              '32768+ — long-document tasks. Cheap on cloud Ollama, expensive '
                  'in RAM and prompt-eval time locally.',
            ],
            example: 'Rule of thumb: keep num_ctx ≥ 4× num_predict so the '
                'model has room for the prompt + history. A 4096 window with '
                'num_predict=2048 leaves only ~2K for everything before the '
                'reply, which is tight.',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _resetOllamaGenParams,
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('Reset to defaults'),
            ),
          ),
          const Text(
            'Changes take effect the next time you start the orchestrator '
            '(Settings → "Start Ollama orchestrator"). They do not interrupt '
            'an already-running session. Direct Ollama chat uses the new '
            'values on the next message.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Future<void> _installOllamaPythonPackage() async {
    if (_ollamaPythonBusy) return;
    setState(() {
      _ollamaPythonBusy = true;
      _ollamaPythonLog.clear();
    });
    final ok = await OllamaPythonManager.instance.installPackage(
      onLine: _appendOllamaPythonLog,
    );
    await _refreshOllamaPythonStatus(verbose: true);
    if (!mounted) return;
    setState(() => _ollamaPythonBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Python package installed' : 'Python package install failed - see log'),
        backgroundColor: ok ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _startOllamaPythonBridge() async {
    if (_ollamaPythonBusy) return;
    setState(() {
      _ollamaPythonBusy = true;
      _ollamaPythonLog.clear();
    });
    final ok = await OllamaPythonManager.instance.startBridge(
      bridgeUrl: _ollamaPythonBridgeUrl,
      onLine: _appendOllamaPythonLog,
    );
    await _refreshOllamaPythonStatus(verbose: true);
    if (!mounted) return;
    setState(() => _ollamaPythonBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Ollama Python bridge is ready' : 'Python bridge failed to start - see log'),
        backgroundColor: ok ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _stopOllamaPythonBridge() async {
    if (_ollamaPythonBusy) return;
    setState(() => _ollamaPythonBusy = true);
    await OllamaPythonManager.instance.stopBridge(
      onLine: _appendOllamaPythonLog,
    );
    await _refreshOllamaPythonStatus(verbose: true);
    if (!mounted) return;
    setState(() => _ollamaPythonBusy = false);
  }

  void _openLocalServerConfig(HfModel model) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bgPrimary,
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.8,
          height: MediaQuery.of(context).size.height * 0.9,
          child: LocalServerConfigWidget(model: model),
        ),
      ),
    );
  }

  @override
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
        title: const Text(
          "Settings",
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSideNav(),
                const VerticalDivider(width: 1, thickness: 1, color: AppTheme.border),
                Expanded(
                  child: _settingsSection == 0
                      ? _buildModelSettings()
                      : _settingsSection == 1
                          ? _buildOrchestratorPanel()
                          : _settingsSection == 2
                              ? _buildAgentWorkflowPanel()
                              : _buildDeveloperPanel(),
                ),
              ],
            ),
    );
  }

  // ---- Side navigation ------------------------------------------------------

  Widget _buildSideNav() {
    return Container(
      width: 190,
      color: AppTheme.bgPrimary,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        children: [
          _navItem("Model Settings", 0, Icons.tune_outlined),
          const SizedBox(height: 4),
          _navItem("Orchestrator", 1, Icons.memory_outlined),
          const SizedBox(height: 4),
          _navItem("Workflow Agents", 2, Icons.account_tree_outlined),
          const SizedBox(height: 4),
          _navItem("Developer", 3, Icons.developer_mode_outlined),
        ],
      ),
    );
  }

  Widget _navItem(String label, int index, IconData icon) {
    final selected = _settingsSection == index;
    return Material(
      color: selected ? AppTheme.accent.withAlpha(25) : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _settingsSection = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(
                icon,
                size: 17,
                color: selected ? AppTheme.accent : AppTheme.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? AppTheme.accent : AppTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Model Settings panel -------------------------------------------------

  Widget _buildModelSettings() {
    final isOllamaBackend =
        _activeBackend == LlmBackend.ollama || _activeBackend == LlmBackend.ollamaPython || _activeBackend == LlmBackend.ollamaOrchestrator || _activeBackend == LlmBackend.ollamaGenerate;
    final isGroqBackend = _activeBackend == LlmBackend.groq || _activeBackend == LlmBackend.groqOrchestrator;
    final isGeminiBackend = _activeBackend == LlmBackend.geminiOrchestrator;
    final isOpenRouterBackend = _activeBackend == LlmBackend.openRouter || _activeBackend == LlmBackend.openRouterOrchestrator;
    final isGithubBackend = _activeBackend == LlmBackend.githubOrchestrator;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _section(
                title: "LLM Backend",
                subtitle: "Choose between remote HF API, cloud agents "
                    "(Groq / Gemini / OpenRouter), or local server "
                    "(Python/transformers, Ollama, etc).",
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppTheme.border),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<LlmBackend>(
                          isExpanded: true,
                          value: _activeBackend,
                          // Only orchestrator-backed options are exposed —
                          // direct backends don't route through
                          // orchestrator.py and are intentionally hidden.
                          items: const [
                            // --- Hugging Face ---
                            // DropdownMenuItem(
                            //   value: LlmBackend.huggingFace,
                            //   child: Text("Hugging Face (Direct)"),
                            // ),
                            DropdownMenuItem(
                              value: LlmBackend.orchestrator,
                              child: Text("Hugging Face + Orchestrator (Recommended)"),
                            ),
                            // --- Ollama ---
                            // DropdownMenuItem(
                            //   value: LlmBackend.ollama,
                            //   child: Text("Ollama (Direct)"),
                            // ),
                            DropdownMenuItem(
                              value: LlmBackend.ollamaOrchestrator,
                              child: Text("Ollama + Orchestrator (filesystem tools)"),
                            ),
                            // DropdownMenuItem(
                            //   value: LlmBackend.ollamaPython,
                            //   child: Text("Ollama (Python bridge)"),
                            // ),
                            // DropdownMenuItem(
                            //   value: LlmBackend.ollamaGenerate,
                            //   child: Text("Ollama /api/generate"),
                            // ),
                            // --- Groq ---
                            // DropdownMenuItem(
                            //   value: LlmBackend.groq,
                            //   child: Text("Groq Cloud (Direct)"),
                            // ),
                            DropdownMenuItem(
                              value: LlmBackend.groqOrchestrator,
                              child: Text("Groq + Orchestrator (filesystem tools)"),
                            ),
                            // --- Gemini ---
                            DropdownMenuItem(
                              value: LlmBackend.geminiOrchestrator,
                              child: Text("Gemini + Orchestrator (filesystem tools)"),
                            ),
                            // --- OpenRouter ---
                            // DropdownMenuItem(
                            //   value: LlmBackend.openRouter,
                            //   child: Text("OpenRouter (Direct)"),
                            // ),
                            DropdownMenuItem(
                              value: LlmBackend.openRouterOrchestrator,
                              child: Text("OpenRouter + Orchestrator (filesystem tools)"),
                            ),
                            // --- GitHub Models ---
                            DropdownMenuItem(
                              value: LlmBackend.githubOrchestrator,
                              child: Text("GitHub + Orchestrator (filesystem tools)"),
                            ),
                            // --- Other ---
                            // DropdownMenuItem(
                            //   value: LlmBackend.local,
                            //   child: Text("Local Server (Python)"),
                            // ),
                          ],
                          onChanged: (v) async {
                            if (v != null) {
                              final messenger = ScaffoldMessenger.of(context);
                              setState(() => _activeBackend = v);
                              await BackendSettingsRepository.instance.setActiveBackend(v);

                              // Stop orchestrator as backend change requires a process restart
                              if (OrchestratorManager.instance.isRunning) {
                                await OrchestratorManager.instance.stop();
                              }

                              if (v == LlmBackend.ollama || v == LlmBackend.ollamaPython || v == LlmBackend.ollamaOrchestrator) {
                                // ignore: unawaited_futures
                                _refreshOllamaStatus();
                              }
                              if (v == LlmBackend.ollamaPython) {
                                // ignore: unawaited_futures
                                _refreshOllamaPythonStatus();
                              }
                              if (v == LlmBackend.openRouter || v == LlmBackend.openRouterOrchestrator) {
                                // ignore: unawaited_futures
                                _refreshOpenRouterModels(
                                  _openRouterApiKeyController.text.trim(),
                                );
                              }
                              if (v == LlmBackend.githubOrchestrator) {
                                // ignore: unawaited_futures
                                _refreshGithubCatalog(
                                  _githubApiKeyController.text.trim(),
                                );
                              }
                              if (mounted) {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text("✓ Backend saved"),
                                    duration: Duration(milliseconds: 800),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),
                    ),
                    if (_activeBackend == LlmBackend.local) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _localServerUrlController,
                        decoration: const InputDecoration(
                          hintText: "http://localhost:5000",
                          labelText: "Server URL",
                          helperText: "Auto-saved on change.",
                        ),
                        onChanged: (v) {
                          setState(() => _localServerUrl = v.trim());
                          _scheduleLocalServerUrlSave(v);
                        },
                      ),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _localServerUrl != null && _localServerUrl!.isNotEmpty ? () => _testLocalServer() : null,
                        icon: const Icon(Icons.cloud_done, size: 16),
                        label: const Text("Test Connection"),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 28),
              if (_activeBackend == LlmBackend.ollama) ...[
                _ollamaControlPanel(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.ollamaOrchestrator) ...[
                // Show the same Ollama panel (so the user can pull /
                // select a model) plus a header explaining what this
                // backend does differently — it wraps the local model
                // in the orchestrator, granting filesystem tools.
                _section(
                  title: "🦙🛠️ Ollama + filesystem tools",
                  subtitle: "Routes a local Ollama model through the same "
                      "orchestrator used for HF models — the model "
                      "can read/write files in the project root via "
                      "tool calls. Strongly recommend a 7B+ coder "
                      "model (qwen2.5-coder:7b, llama3:8b). Smaller "
                      "models often refuse or emit natural-language "
                      "answers instead of <tool>…</tool> calls.",
                  child: const SizedBox.shrink(),
                ),
                const SizedBox(height: 12),
                _ollamaControlPanel(),
                const SizedBox(height: 20),
                _orchestratorNote(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.ollamaPython) ...[
                _ollamaPythonControlPanel(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.groq) ...[
                _groqControlPanel(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.groqOrchestrator) ...[
                _groqControlPanel(),
                const SizedBox(height: 20),
                _orchestratorNote(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.geminiOrchestrator) ...[
                _geminiControlPanel(),
                const SizedBox(height: 20),
                _orchestratorNote(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.openRouter) ...[
                _openRouterControlPanel(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.openRouterOrchestrator) ...[
                _openRouterControlPanel(),
                const SizedBox(height: 20),
                _orchestratorNote(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.githubOrchestrator) ...[
                _githubControlPanel(),
                const SizedBox(height: 20),
                _orchestratorNote(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.ollamaGenerate) ...[
                _generateControlPanel(),
                const SizedBox(height: 28),
              ] else if (_activeBackend == LlmBackend.orchestrator) ...[
                _section(
                  title: "HF Agent Configuration",
                  subtitle: "Token for the local orchestrator. Stored locally only.",
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _agentTokenController,
                          obscureText: _obscureAgentToken,
                          onChanged: (v) => _scheduleAgentTokenSave(v),
                          decoration: InputDecoration(
                            hintText: "hf_xxx...",
                            helperText: "Auto-saved on change. Get from ${ApiConstants.huggingfaceTokensUrl}",
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureAgentToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                size: 18,
                              ),
                              onPressed: () => setState(
                                () => _obscureAgentToken = !_obscureAgentToken,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final token = _agentTokenController.text.trim();
                              if (token.isEmpty) {
                                messenger.showSnackBar(
                                  const SnackBar(content: Text("Token cannot be empty")),
                                );
                                return;
                              }
                              await AgentCredentialsRepository.instance.saveCredentials(AgentCredentials(hfToken: token));
                              if (!mounted) return;
                              messenger.showSnackBar(
                                const SnackBar(content: Text("Agent token saved")),
                              );
                            },
                            child: const Text("Save"),
                          )),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _orchestratorNote(),
                const SizedBox(height: 28),
              ] else ...[
                _section(
                  title: "Hugging Face token",
                  subtitle: "Stored locally on this device only.",
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tokenController,
                          obscureText: _obscureToken,
                          onChanged: (v) => _scheduleHfTokenSave(v),
                          decoration: InputDecoration(
                            hintText: "hf_xxx...",
                            helperText: "Auto-saved on change.",
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscureToken ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                size: 18,
                              ),
                              onPressed: () => setState(
                                () => _obscureToken = !_obscureToken,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton(
                        onPressed: _saveToken,
                        child: const Text("Save"),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
              ],
              // "Default model" and "Saved models" are HF-specific.
              // Groq and Gemini manage their own models inside their
              // dedicated control panels, so we hide these sections
              // for those backends.
              if (!isGroqBackend && !isGeminiBackend && !isOpenRouterBackend && !isGithubBackend) ...[
                const SizedBox(height: 28),
                _section(
                  title: "Default model",
                  subtitle: "Used for new chats. You can still override per conversation.",
                  child: isOllamaBackend
                      ? _ollamaDefaultModelPicker()
                      : Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            border: Border.all(color: AppTheme.border),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              isExpanded: true,
                              value: _models.any((m) => m.id == _selectedModelId) ? _selectedModelId : null,
                              hint: const Text("Select default model"),
                              items: _models
                                  .map(
                                    (m) => DropdownMenuItem<String>(
                                      value: m.id,
                                      child: Text(
                                        m.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null) _setSelected(v);
                              },
                            ),
                          ),
                        ),
                ),
                if (!isOllamaBackend) ...[
                  const SizedBox(height: 28),
                  _section(
                    title: "Saved models",
                    subtitle: "Add any model id supported by the HF router.",
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _newModelController,
                                decoration: const InputDecoration(
                                  hintText: "e.g. Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic",
                                ),
                                onSubmitted: (_) => _addModel(),
                              ),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                                height: 48,
                                child: OutlinedButton.icon(
                                  onPressed: _addModel,
                                  icon: const Icon(Icons.add, size: 16),
                                  label: const Text("Add"),
                                )),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (_models.isEmpty)
                          const Text(
                            "No models saved yet.",
                            style: TextStyle(color: AppTheme.textMuted),
                          )
                        else
                          Column(
                            children: _models.map((m) => _modelRow(m)).toList(),
                          ),
                      ],
                    ),
                  ),
                ]
              ], // closes if (!isOllamaBackend) and HF-only model sections
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Orchestrator quick-status note (shown inside Model Settings) ---------

  Widget _orchestratorNote() {
    final running = OrchestratorManager.instance.isRunning;
    return _section(
      title: "Orchestrator",
      subtitle: "Manage the orchestrator process in the Orchestrator section.",
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: running ? AppTheme.accentMarrone : AppTheme.textMuted,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            running ? "Running" : "Stopped",
            style: TextStyle(
              fontSize: 13,
              color: running ? AppTheme.accentMarrone : AppTheme.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => setState(() => _settingsSection = 1),
            icon: const Icon(Icons.memory_outlined, size: 15),
            label: const Text("Manage"),
            style: TextButton.styleFrom(foregroundColor: AppTheme.accent),
          ),
        ],
      ),
    );
  }

  // ---- Workflow Agents panel (side-nav section 2) ---------------------------

  Widget _buildAgentWorkflowPanel() {
    return const AgentWorkflowSettings();
  }

  // ---- Orchestrator panel (side-nav section 1) ------------------------------

  Widget _buildOrchestratorPanel() {
    final running = OrchestratorManager.instance.isRunning;
    final needsOrchestrator = _activeBackend == LlmBackend.orchestrator ||
        _activeBackend == LlmBackend.ollamaOrchestrator ||
        _activeBackend == LlmBackend.groqOrchestrator ||
        _activeBackend == LlmBackend.geminiOrchestrator ||
        _activeBackend == LlmBackend.openRouterOrchestrator ||
        _activeBackend == LlmBackend.githubOrchestrator;

    // Merge in-memory session log + persisted log (deduplicated, persisted first).
    final seen = <String>{};
    final allLines = <String>[];
    for (final l in _persistedLog) {
      if (seen.add(l)) allLines.add(l);
    }
    for (final l in _orchestratorLog) {
      if (seen.add(l)) allLines.add(l);
    }
    for (final l in const LineSplitter().convert(OrchestratorManager.instance.stderrLog)) {
      if (l.trim().isEmpty) continue;
      if (seen.add(l)) allLines.add(l);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status
              _section(
                title: "Status",
                subtitle: "Current orchestrator process state.",
                child: Row(
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: running ? AppTheme.accentMarrone : AppTheme.textMuted,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      running ? "Running" : "Stopped",
                      style: TextStyle(
                        fontSize: 13,
                        color: running ? AppTheme.accentMarrone : AppTheme.textMuted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (running) ...[
                      const SizedBox(width: 12),
                      Text(
                        "backend: ${_activeBackend.name}",
                        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                    const Spacer(),
                    if (_orchestratorBusy)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Actions
              _section(
                title: "Actions",
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _orchestratorBusy ? null : _installOrchestratorDeps,
                      icon: const Icon(Icons.download_outlined, size: 16),
                      label: const Text("Install dependencies"),
                    ),
                    if (needsOrchestrator) ...[
                      ElevatedButton.icon(
                        onPressed: (_orchestratorBusy || running) ? null : _startCurrentOrchestrator,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text("Start orchestrator"),
                      ),
                      OutlinedButton.icon(
                        onPressed: (_orchestratorBusy || !running) ? null : _stopOrchestrator,
                        icon: const Icon(Icons.stop, size: 16),
                        label: const Text("Stop"),
                      ),
                    ] else
                      const Text(
                        "Start/Stop controls appear when an orchestrator backend is selected in Model Settings.",
                        style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // Log
              _section(
                title: "Log",
                subtitle: "Persisted log — last 2 000 lines (oldest auto-removed).",
                child: allLines.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          "No log entries yet.",
                          style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                        ),
                      )
                    : _logConsole(allLines),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // Dispatch Start to the right method based on active backend.
  Future<void> _startCurrentOrchestrator() async {
    switch (_activeBackend) {
      case LlmBackend.huggingFace:
      case LlmBackend.local:
      case LlmBackend.ollama:
      case LlmBackend.ollamaPython:
      case LlmBackend.groq:
      case LlmBackend.openRouter:
      case LlmBackend.ollamaGenerate:
        break;
      case LlmBackend.orchestrator:
        await _startOrchestrator();
        break;
      case LlmBackend.ollamaOrchestrator:
        await _startOllamaOrchestrator();
        break;
      case LlmBackend.groqOrchestrator:
        await _startGroqOrchestrator();
        break;
      case LlmBackend.geminiOrchestrator:
        await _startGeminiOrchestrator();
        break;
      case LlmBackend.openRouterOrchestrator:
        await _startOpenRouterOrchestrator();
        break;
      case LlmBackend.githubOrchestrator:
        await _startGithubOrchestrator();
        break;
    }
  }

  // List<String> _combinedOrchestratorLogLines() {
  //   final combined = <String>[..._orchestratorLog];
  //   final runtime = OrchestratorManager.instance.stderrLog;
  //   if (runtime.isNotEmpty) {
  //     for (final line in const LineSplitter().convert(runtime)) {
  //       if (line.trim().isEmpty) continue;
  //       if (!combined.contains(line)) {
  //         combined.add(line);
  //       }
  //     }
  //   }
  //   return combined;
  // }

  Widget _ollamaControlPanel() {
    final hasBinary = _ollamaBinaryVersion != null;
    final serverUp = _ollamaServerUp;
    final managing = OllamaManager.instance.isManagingProcess;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _section(
          title: "🦙 Ollama — local models",
          subtitle: "Ollama runs LLMs entirely on this machine. Step 1 is a "
              "one-time install of the Ollama binary; everything else "
              "(starting the daemon, pulling models, chatting) is driven "
              "from here.",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Status row -------------------------------------------------
              Row(
                children: [
                  _statusDot(hasBinary ? AppTheme.accentMarrone : AppTheme.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    hasBinary ? 'Binary: ${_ollamaBinaryVersion!}' : 'Binary: not detected',
                    style: TextStyle(
                      fontSize: 13,
                      color: hasBinary ? AppTheme.accentMarrone : AppTheme.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 16),
                  _statusDot(serverUp ? AppTheme.accentMarrone : AppTheme.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    serverUp ? 'Server: running' : (managing ? 'Server: starting…' : 'Server: stopped'),
                    style: TextStyle(
                      fontSize: 13,
                      color: serverUp ? AppTheme.accentMarrone : AppTheme.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (_ollamaBusy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 14),

              // --- Install helper when binary missing -------------------------
              if (!hasBinary) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Step 1 — install Ollama (one-time)',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Run the installer from here when possible. If your '
                        'platform is not supported, copy the download URL and '
                        'install Ollama manually.',
                        style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          ElevatedButton.icon(
                            onPressed: (_ollamaBusy || !OllamaManager.instance.supportsUiInstall) ? null : _installOllamaBinary,
                            icon: const Icon(Icons.download_outlined, size: 14),
                            label: Text(
                              OllamaManager.instance.supportsUiInstall ? 'Install from UI' : 'UI install unavailable',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(const ClipboardData(text: ApiConstants.ollamaDownloadUrl));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Download URL copied: ${ApiConstants.ollamaDownloadUrl}'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 14),
                            label: const Text('Copy download URL'),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: _ollamaBusy ? null : () => _refreshOllamaStatus(verbose: true),
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text('Re-check'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // --- Server URL -------------------------------------------------
              TextField(
                controller: _ollamaUrlController,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: OllamaService.defaultBaseUrl,
                  helperText: 'Local daemon: ${ApiConstants.ollamaLocalBaseUrl} (default). '
                      'Cloud: use the URL from your Ollama account '
                      '(e.g. ${ApiConstants.ollamaCloudBaseUrl}). Auto-saved.',
                ),
                onChanged: (v) {
                  _scheduleOllamaUrlSave(v);
                  // ignore: unawaited_futures
                  _refreshOllamaStatus();
                },
              ),
              const SizedBox(height: 12),

              // --- API key (cloud models) -------------------------------------
              TextField(
                controller: _ollamaApiKeyController,
                obscureText: !_ollamaApiKeyVisible,
                decoration: InputDecoration(
                  labelText: 'API key (cloud models)',
                  hintText: 'Leave blank for local daemon',
                  helperText: 'Bearer token for cloud-hosted Ollama endpoints '
                      '(e.g. Ollama Cloud, OpenRouter). '
                      'Local daemon needs no key.',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _ollamaApiKeyVisible ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                    ),
                    onPressed: () => setState(
                      () => _ollamaApiKeyVisible = !_ollamaApiKeyVisible,
                    ),
                  ),
                ),
                onChanged: _scheduleOllamaApiKeySave,
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.save_alt, size: 15),
                  label: const Text(
                    'Set as OLLAMA_API_KEY environment variable',
                    style: TextStyle(fontSize: 12),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _exportOllamaApiKeyToEnv,
                ),
              ),
              const SizedBox(height: 12),

              // --- Start / stop / refresh buttons -----------------------------
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: (_ollamaBusy || !hasBinary || serverUp) ? null : _startOllamaServer,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Start Ollama server'),
                  ),
                  OutlinedButton.icon(
                    onPressed: (_ollamaBusy || !managing) ? null : _stopOllamaServer,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('Stop'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _ollamaBusy ? null : () => _refreshOllamaStatus(verbose: true),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Refresh'),
                  ),
                ],
              ),

              const SizedBox(height: 18),
              // --- Model management ------------------------------------------
              const Text(
                'Installed models',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              if (_ollamaInstalledModels.isEmpty)
                const Text(
                  'No models installed yet. Pull one below '
                  '(e.g. `llama3`, `qwen2.5-coder:7b`, `gemma:2b`).',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5),
                )
              else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppTheme.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _ollamaInstalledModels.contains(_ollamaSelectedModel) ? _ollamaSelectedModel : null,
                      hint: const Text('Select model to use in chat'),
                      items: _ollamaInstalledModels
                          .map((m) => DropdownMenuItem<String>(
                                value: m,
                                child: Text(m),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) _setOllamaModel(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _installedModelsList(canModify: serverUp),
              ],

              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ollamaPullController,
                      decoration: const InputDecoration(
                        labelText: 'Pull model',
                        hintText: 'llama3, mistral, qwen2.5-coder:7b, gemma:2b…',
                      ),
                      onSubmitted: (_) => _pullOllamaModel(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    onPressed: (_ollamaBusy || !serverUp) ? null : _pullOllamaModel,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Pull'),
                  ),
                  if (_ollamaPullingModel != null) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Stop download and remove partial data',
                      style: IconButton.styleFrom(
                        backgroundColor: AppTheme.danger.withAlpha(30),
                      ),
                      icon: Icon(
                        Icons.stop_circle_outlined,
                        size: 22,
                        color: _ollamaPullCancelled
                            ? AppTheme.textMuted
                            : AppTheme.danger,
                      ),
                      onPressed:
                          _ollamaPullCancelled ? null : _cancelOllamaPull,
                    ),
                  ],
                ],
              ),
              if (_ollamaPullingModel != null) _ollamaPullProgressBar(),

              const SizedBox(height: 16),
              _ollamaCatalogTable(serverUp: serverUp),

              const SizedBox(height: 16),
              _ollamaLibraryPanel(serverUp: serverUp),

              // --- Generation parameters -------------------------------------
              const SizedBox(height: 18),
              _buildOllamaGenParams(),

              // --- Log console ------------------------------------------------
              if (_ollamaLog.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 180),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      _ollamaLog.join('\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: Colors.greenAccent,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _ollamaPythonControlPanel() {
    final hasBinary = _ollamaBinaryVersion != null;
    final serverUp = _ollamaServerUp;
    final hasPython = _pythonVersion != null;
    final hasPackage = _ollamaPythonPackageVersion != null;
    final bridgeUp = _ollamaPythonBridgeUp;
    final managingBridge = OllamaPythonManager.instance.isManagingBridge;

    return _section(
      title: "Ollama Python bridge",
      subtitle: "This approach follows the Python guide: install Ollama, install "
          "`pip install ollama`, then start a small local bridge the app can "
          "chat through.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 10,
            children: [
              _statusChip(
                ok: hasBinary,
                label: hasBinary ? 'Ollama: ${_ollamaBinaryVersion!}' : 'Ollama: not installed',
              ),
              _statusChip(
                ok: serverUp,
                label: serverUp ? 'Daemon: running' : 'Daemon: stopped',
              ),
              _statusChip(
                ok: hasPython,
                label: hasPython ? 'Python: ${_pythonVersion!}' : 'Python: not found',
              ),
              _statusChip(
                ok: hasPackage,
                label: hasPackage ? 'Package: ollama ${_ollamaPythonPackageVersion!}' : 'Package: missing',
              ),
              _statusChip(
                ok: bridgeUp,
                label: bridgeUp ? 'Bridge: running' : (managingBridge ? 'Bridge: starting' : 'Bridge: stopped'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (!hasBinary) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.border),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: (_ollamaBusy || !OllamaManager.instance.supportsUiInstall) ? null : _installOllamaBinary,
                    icon: const Icon(Icons.download_outlined, size: 14),
                    label: Text(
                      OllamaManager.instance.supportsUiInstall ? 'Install Ollama' : 'UI install unavailable',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(const ClipboardData(text: ApiConstants.ollamaDownloadUrl));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Download URL copied: ${ApiConstants.ollamaDownloadUrl}'),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('Copy download URL'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          TextField(
            controller: _ollamaPythonUrlController,
            decoration: const InputDecoration(
              labelText: 'Bridge URL',
              hintText: OllamaPythonManager.defaultBridgeUrl,
              helperText: 'Auto-saved on change.',
            ),
            onChanged: (v) {
              _scheduleOllamaPythonUrlSave(v);
              // ignore: unawaited_futures
              _refreshOllamaPythonStatus();
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: (_ollamaPythonBusy || !hasPython) ? null : _installOllamaPythonPackage,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Install Python package'),
              ),
              ElevatedButton.icon(
                onPressed: (_ollamaBusy || !hasBinary || serverUp) ? null : _startOllamaServer,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Start Ollama daemon'),
              ),
              ElevatedButton.icon(
                onPressed: (_ollamaPythonBusy || !hasPackage || bridgeUp) ? null : _startOllamaPythonBridge,
                icon: const Icon(Icons.play_circle_outline, size: 16),
                label: const Text('Start Python bridge'),
              ),
              OutlinedButton.icon(
                onPressed: (_ollamaPythonBusy || !managingBridge) ? null : _stopOllamaPythonBridge,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Stop bridge'),
              ),
              OutlinedButton.icon(
                onPressed: (_ollamaBusy || !OllamaManager.instance.isManagingProcess) ? null : _stopOllamaServer,
                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                label: const Text('Stop daemon'),
              ),
              OutlinedButton.icon(
                onPressed: (_ollamaBusy || _ollamaPythonBusy)
                    ? null
                    : () async {
                        await _refreshOllamaStatus(verbose: true);
                        await _refreshOllamaPythonStatus(verbose: true);
                      },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Refresh'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _ollamaModelManagement(canPull: serverUp),
          if (_ollamaLog.isNotEmpty) ...[
            const SizedBox(height: 12),
            _logConsole(_ollamaLog),
          ],
          if (_ollamaPythonLog.isNotEmpty) ...[
            const SizedBox(height: 12),
            _logConsole(_ollamaPythonLog),
          ],
        ],
      ),
    );
  }

  /// Compact list of installed Ollama models, each with a delete button.
  /// [canModify] is false when the daemon is unreachable — the delete icon
  /// is then disabled so users don't hit an inevitable error.
  Widget _installedModelsList({required bool canModify}) {
    if (_ollamaInstalledModels.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: _ollamaInstalledModels.map((m) {
        return Container(
          padding: const EdgeInsets.only(left: 10, right: 4, top: 2, bottom: 2),
          decoration: BoxDecoration(
            border: Border.all(color: AppTheme.border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(m, style: const TextStyle(fontSize: 12)),
              const SizedBox(width: 4),
              InkWell(
                onTap: (_ollamaBusy || !canModify) ? null : () => _deleteOllamaModel(m),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: (_ollamaBusy || !canModify) ? AppTheme.textMuted : AppTheme.danger,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  // --- Ollama catalog table -------------------------------------------------

  static const int _kOlColFlexName = 6;
  static const int _kOlColFlexFamily = 3;
  static const int _kOlColFlexParams = 2;
  static const int _kOlColFlexQuant = 2;
  static const int _kOlColFlexSize = 2;
  static const int _kOlColFlexModified = 3;
  static const double _kOlColWidthInstalled = 36;
  static const double _kOlColWidthTools = 36;
  static const double _kOlColWidthActions = 72;

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double v = bytes.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return v >= 100
        ? '${v.toStringAsFixed(0)} ${units[i]}'
        : v >= 10
            ? '${v.toStringAsFixed(1)} ${units[i]}'
            : '${v.toStringAsFixed(2)} ${units[i]}';
  }

  String _formatRelative(DateTime? when) {
    if (when == null) return '—';
    final d = DateTime.now().difference(when);
    if (d.inDays >= 365) return '${(d.inDays / 365).floor()}y ago';
    if (d.inDays >= 30) return '${(d.inDays / 30).floor()}mo ago';
    if (d.inDays >= 1) return '${d.inDays}d ago';
    if (d.inHours >= 1) return '${d.inHours}h ago';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ago';
    return 'just now';
  }

  Future<void> _copyOllamaCatalog() async {
    if (_ollamaCatalog.isEmpty) return;
    final buf = StringBuffer()
      ..writeln([
        'name',
        'family',
        'params',
        'quant',
        'size_bytes',
        'size_human',
        'modified_at',
        'tools',
        'capabilities',
        'digest',
      ].join('\t'));
    for (final m in _ollamaCatalog) {
      buf.writeln([
        m.name,
        m.family,
        m.parameterSize,
        m.quantizationLevel,
        m.sizeBytes.toString(),
        _formatBytes(m.sizeBytes),
        m.modifiedAt?.toIso8601String() ?? '',
        OllamaService.supportsToolCalling(m) ? 'yes' : 'no',
        m.capabilities.join(','),
        m.digest,
      ].join('\t'));
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content:
            Text('Copied ${_ollamaCatalog.length} Ollama models to clipboard'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _pullOllamaCatalogRow(String name) async {
    _ollamaPullController.text = name;
    await _pullOllamaModel();
  }

  Widget _ollamaCatalogTable({required bool serverUp}) {
    if (!serverUp) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'Ollama daemon not reachable. Start the server to load the catalog.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      );
    }
    if (_ollamaCatalog.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          _ollamaCatalogLoading
              ? 'Loading catalog…'
              : 'No models installed yet. Pull one above to populate this table.',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.list_alt, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Catalog (${_ollamaCatalog.length} models)',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_ollamaCatalogLoading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  tooltip: 'Refresh catalog',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed:
                      _ollamaCatalogLoading ? null : _refreshOllamaCatalog,
                ),
                IconButton(
                  tooltip: 'Copy all rows as TSV',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.copy_all, size: 16),
                  onPressed: _copyOllamaCatalog,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              border: Border(
                top: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
                bottom: BorderSide(
                    color: AppTheme.accentDarkMarrone.withAlpha(80)),
              ),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: _kOlColFlexName,
                  child: Text('Name',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                SizedBox(width: 8),
                Expanded(
                  flex: _kOlColFlexFamily,
                  child: Text('Family',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                SizedBox(width: 8),
                Expanded(
                  flex: _kOlColFlexParams,
                  child: Text('Params',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.right),
                ),
                SizedBox(width: 8),
                Expanded(
                  flex: _kOlColFlexQuant,
                  child: Text('Quant',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                SizedBox(width: 8),
                Expanded(
                  flex: _kOlColFlexSize,
                  child: Text('Size',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.right),
                ),
                SizedBox(width: 8),
                Expanded(
                  flex: _kOlColFlexModified,
                  child: Text('Modified',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold)),
                ),
                SizedBox(width: 8),
                SizedBox(
                  width: _kOlColWidthInstalled,
                  child: Text('Inst.',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center),
                ),
                SizedBox(width: 8),
                SizedBox(
                  width: _kOlColWidthTools,
                  child: Text('Tools',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center),
                ),
                SizedBox(width: 8),
                SizedBox(
                  width: _kOlColWidthActions,
                  child: Text('Actions',
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: Scrollbar(
              controller: _ollamaCatalogScrollController,
              child: ListView.separated(
                controller: _ollamaCatalogScrollController,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _ollamaCatalog.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  thickness: 1,
                  color: AppTheme.accentDarkMarrone.withAlpha(30),
                ),
                itemBuilder: (ctx, i) {
                  final m = _ollamaCatalog[i];
                  final tools = OllamaService.supportsToolCalling(m);
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          flex: _kOlColFlexName,
                          child: Text(
                            m.name,
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w600),
                            softWrap: true,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOlColFlexFamily,
                          child: Text(
                            m.family.isEmpty ? '—' : m.family,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOlColFlexParams,
                          child: Text(
                            m.parameterSize.isEmpty ? '—' : m.parameterSize,
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOlColFlexQuant,
                          child: Text(
                            m.quantizationLevel.isEmpty
                                ? '—'
                                : m.quantizationLevel,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOlColFlexSize,
                          child: Text(
                            _formatBytes(m.sizeBytes),
                            style: const TextStyle(fontSize: 12),
                            textAlign: TextAlign.right,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: _kOlColFlexModified,
                          child: Text(
                            _formatRelative(m.modifiedAt),
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.textSecondary),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: _kOlColWidthInstalled,
                          child: Center(
                            child: Icon(
                              Icons.check_circle,
                              size: 16,
                              color: Colors.green,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kOlColWidthTools,
                          child: Center(
                            child: Icon(
                              tools
                                  ? Icons.check_circle
                                  : Icons.remove_circle_outline,
                              size: 16,
                              color: tools ? Colors.green : Colors.grey,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: _kOlColWidthActions,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                tooltip: 'Re-pull / update ${m.name}',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 28, minHeight: 28),
                                icon: const Icon(Icons.download, size: 16),
                                onPressed: _ollamaBusy
                                    ? null
                                    : () => _pullOllamaCatalogRow(m.name),
                              ),
                              IconButton(
                                tooltip: 'Delete ${m.name}',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                    minWidth: 28, minHeight: 28),
                                icon: const Icon(Icons.delete_outline,
                                    size: 16, color: AppTheme.danger),
                                onPressed: _ollamaBusy
                                    ? null
                                    : () => _deleteOllamaModel(m.name),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- Browse the public ollama.com/library --------------------------------

  /// Quick lookup: short installed-name matches `_ollamaInstalledModels`
  /// entries like `llama3:latest` -> base name `llama3`. Used to draw the
  /// green check on rows the user already has locally.
  bool _libraryRowInstalled(String name) {
    final n = name.toLowerCase();
    for (final m in _ollamaInstalledModels) {
      final base = m.split(':').first.toLowerCase();
      if (base == n) return true;
    }
    return false;
  }

  List<OllamaLibraryModel> _filteredLibrary() {
    if (_ollamaLibraryFilter.trim().isEmpty) return _ollamaLibrary;
    final q = _ollamaLibraryFilter.trim().toLowerCase();
    return _ollamaLibrary.where((m) {
      if (m.name.toLowerCase().contains(q)) return true;
      if (m.description.toLowerCase().contains(q)) return true;
      if (m.sizes.any((s) => s.contains(q))) return true;
      if (m.tags.any((t) => t.contains(q))) return true;
      if (m.capabilities.any((c) => c.contains(q))) return true;
      return false;
    }).toList();
  }

  Widget _ollamaLibraryPanel({required bool serverUp}) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentDarkMarrone.withAlpha(100)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.travel_explore, size: 16),
                const SizedBox(width: 6),
                Text(
                  _ollamaLibrary.isEmpty
                      ? 'Browse ollama.com/library'
                      : 'Browse ollama.com/library '
                          '(${_filteredLibrary().length}'
                          '${_ollamaLibraryFilter.isEmpty ? '' : ' / ${_ollamaLibrary.length}'} '
                          'models)',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_ollamaLibraryLoading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  tooltip: _ollamaLibrary.isEmpty
                      ? 'Fetch library'
                      : 'Refresh library',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: const Icon(Icons.refresh, size: 16),
                  onPressed:
                      _ollamaLibraryLoading ? null : _refreshOllamaLibrary,
                ),
              ],
            ),
          ),
          if (_ollamaLibrary.isEmpty && !_ollamaLibraryLoading) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                _ollamaLibraryError != null
                    ? 'Failed to load: $_ollamaLibraryError'
                    : 'Click refresh to fetch the public model catalog from '
                        'ollama.com/library. Scraped HTML — Ollama has no '
                        'public JSON API, so layout changes may break this.',
                style: TextStyle(
                    fontSize: 12, color: Colors.grey[700], height: 1.4),
              ),
            ),
          ] else if (_ollamaLibrary.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: TextField(
                controller: _ollamaLibraryFilterController,
                decoration: const InputDecoration(
                  isDense: true,
                  prefixIcon: Icon(Icons.search, size: 16),
                  hintText: 'Filter by name, size, capability…',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    setState(() => _ollamaLibraryFilter = v),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 480),
              child: Scrollbar(
                controller: _ollamaLibraryScrollController,
                child: ListView.separated(
                  controller: _ollamaLibraryScrollController,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _filteredLibrary().length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    thickness: 1,
                    color: AppTheme.accentDarkMarrone.withAlpha(30),
                  ),
                  itemBuilder: (ctx, i) =>
                      _ollamaLibraryRow(_filteredLibrary()[i], serverUp),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _ollamaLibraryRow(OllamaLibraryModel m, bool serverUp) {
    final installed = _libraryRowInstalled(m.name);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Left: name + description + chips
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SelectableText(
                      m.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (installed) ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.check_circle,
                          size: 14, color: Colors.green),
                    ],
                  ],
                ),
                if (m.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    m.description,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    if (m.isCloud) _libChip('cloud', color: Colors.indigo),
                    for (final s in m.sizes) _libChip(s),
                    for (final c in m.capabilities)
                      _libChip(c, color: Colors.teal),
                    for (final t in m.tags.where((t) => t != 'cloud'))
                      _libChip(t),
                  ],
                ),
                if (m.pulls.isNotEmpty || m.updated.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    [
                      if (m.pulls.isNotEmpty) '${m.pulls} pulls',
                      if (m.updated.isNotEmpty) 'updated ${m.updated}',
                    ].join(' • '),
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Right: actions
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Copy name',
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.copy, size: 14),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: m.name));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Copied "${m.name}" to clipboard'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                },
              ),
              IconButton(
                tooltip: m.url.isEmpty
                    ? 'No URL'
                    : 'Copy ${m.url}',
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.open_in_new, size: 14),
                onPressed: m.url.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: m.url));
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied URL: ${m.url}'),
                            duration: const Duration(seconds: 1),
                          ),
                        );
                      },
              ),
              IconButton(
                tooltip: serverUp
                    ? (installed
                        ? 'Re-pull / update ${m.name}'
                        : 'Pull ${m.name}')
                    : 'Start the Ollama server first',
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 28, minHeight: 28),
                icon: const Icon(Icons.download, size: 14),
                onPressed: (!serverUp || _ollamaBusy)
                    ? null
                    : () => _pullOllamaCatalogRow(m.name),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _libChip(String label, {Color? color}) {
    final fg = color ?? AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: fg.withAlpha(25),
        border: Border.all(color: fg.withAlpha(1000)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _ollamaDefaultModelPicker() {
    if (_ollamaInstalledModels.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.bgSecondary,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'No Ollama models installed yet. Pull one in the Ollama section above.',
          style: TextStyle(color: AppTheme.textMuted),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _ollamaInstalledModels.contains(_ollamaSelectedModel) ? _ollamaSelectedModel : null,
          hint: const Text('Select default Ollama model'),
          items: _ollamaInstalledModels
              .map((m) => DropdownMenuItem<String>(
                    value: m,
                    child: Text(
                      m,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ))
              .toList(),
          onChanged: (v) {
            if (v != null) _setOllamaModel(v);
          },
        ),
      ),
    );
  }

  Widget _ollamaModelManagement({required bool canPull}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Installed models',
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 6),
        if (_ollamaInstalledModels.isEmpty)
          const Text(
            'No models installed yet. Pull one below '
            '(e.g. `llama3`, `qwen2.5-coder:7b`, `gemma:2b`).',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12.5),
          )
        else ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _ollamaInstalledModels.contains(_ollamaSelectedModel) ? _ollamaSelectedModel : null,
                hint: const Text('Select model to use in chat'),
                items: _ollamaInstalledModels
                    .map((m) => DropdownMenuItem<String>(
                          value: m,
                          child: Text(m),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) _setOllamaModel(v);
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          _installedModelsList(canModify: canPull),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ollamaPullController,
                decoration: const InputDecoration(
                  labelText: 'Pull model',
                  hintText: 'llama3, mistral, qwen2.5-coder:7b, gemma:2b...',
                ),
                onSubmitted: (_) => _pullOllamaModel(),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: (_ollamaBusy || !canPull) ? null : _pullOllamaModel,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Pull'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusChip({
    required bool ok,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: ok ? AppTheme.accentMarrone : AppTheme.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: ok ? AppTheme.accentMarrone : AppTheme.textMuted,
        ),
      ),
    );
  }

  Widget _logConsole(List<String> lines) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bgCodeMessageBubble,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: SelectableText(
          lines.join('\n'),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11.5,
            color: Colors.greenAccent,
          ),
        ),
      ),
    );
  }

  Widget _statusDot(Color color) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );

  Widget _modelRow(HfModel m) {
    final selected = m.id == _selectedModelId;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? AppTheme.accent.withAlpha(100) : AppTheme.border,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              m.isFavorite ? Icons.star : Icons.star_border,
              size: 18,
              color: m.isFavorite ? AppTheme.accent : AppTheme.textMuted,
            ),
            tooltip: m.isFavorite ? "Unfavorite" : "Favorite",
            onPressed: () => _toggleFavorite(m),
            splashRadius: 16,
          ),
          Expanded(
            child: Text(
              m.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
          IconButton(
            tooltip: "Copy id",
            icon: const Icon(Icons.copy_outlined, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: m.id));
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Model id copied")),
              );
            },
            splashRadius: 16,
          ),
          IconButton(
            tooltip: "Edit name",
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: () => _editModel(m),
            splashRadius: 16,
          ),
          IconButton(
            tooltip: "Configure local server",
            icon: const Icon(Icons.settings_outlined, size: 16),
            onPressed: () => _openLocalServerConfig(m),
            splashRadius: 16,
          ),
          TextButton(
            onPressed: selected ? null : () => _setSelected(m.id),
            child: Text(selected ? "Default" : "Use"),
          ),
          IconButton(
            tooltip: "Delete",
            icon: const Icon(Icons.delete_outline, size: 18),
            color: AppTheme.danger,
            onPressed: () => _deleteModel(m),
            splashRadius: 16,
          ),
        ],
      ),
    );
  }

  Widget _section({
    required String title,
    String? subtitle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 12.5,
              color: AppTheme.textMuted,
            ),
          ),
        ],
        const SizedBox(height: 10),
        child,
      ],
    );
  }

  Future<void> _startOpenRouterOrchestrator() async {
    if (_orchestratorBusy) return;
    final apiKey = _openRouterApiKeyController.text.trim();
    final envOpenRouterKey = Platform.environment['OPENROUTER_API_KEY'] ?? '';
    if (apiKey.isEmpty && envOpenRouterKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the OpenRouter API key first.')),
      );
      return;
    }
    final model = _openRouterSelectedModel?.trim() ?? '';
    if (model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            'Pick an OpenRouter model first (refresh the catalog if empty).')),
      );
      return;
    }

    if (OrchestratorManager.instance.isRunning && OrchestratorManager.instance.currentBackend != OrchestratorBackend.openrouter) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting OpenRouter orchestrator (model: $model)...');

    final temperature = _openRouterTemperature;
    final maxTokens = int.tryParse(_openRouterMaxTokensController.text.trim()) ?? BackendSettingsRepository.defaultOpenRouterMaxTokens;

    final started = await OrchestratorManager.instance.start(
      backend: OrchestratorBackend.openrouter,
      modelId: model,
      openRouterApiKey: apiKey,
      temperature: temperature,
      maxTokens: maxTokens,
    );
    final stderr = OrchestratorManager.instance.stderrLog;
    if (stderr.isNotEmpty) {
      for (final l in const LineSplitter().convert(stderr)) {
        _appendLog(l);
      }
    }
    _appendLog(started ? 'OpenRouter orchestrator running.' : 'Failed to start OpenRouter orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started ? 'OpenRouter orchestrator running' : 'Failed to start — check log'),
        backgroundColor: started ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  Future<void> _startGithubOrchestrator() async {
    if (_orchestratorBusy) return;
    final apiKey = _githubApiKeyController.text.trim();
    final envKey = Platform.environment['GITHUB_TOKEN'] ??
        Platform.environment['GITHUB_API_KEY'] ??
        '';
    if (apiKey.isEmpty && envKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the GitHub PAT first.')),
      );
      return;
    }
    final model =
        _githubSelectedModel ?? GithubModelsService.fallbackModels.first;

    if (OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend !=
            OrchestratorBackend.github) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting GitHub Models orchestrator (model: $model)...');

    final temperature = _githubTemperature;
    final maxTokens =
        int.tryParse(_githubMaxTokensController.text.trim()) ??
            BackendSettingsRepository.defaultGithubMaxTokens;
    final tpmLimit =
        int.tryParse(_githubTpmLimitController.text.trim()) ?? 0;
    final disableTools =
        await BackendSettingsRepository.instance.getGithubDisableTools();
    if (disableTools) {
      _appendLog(
          '"$model" is a non-tool-calling model — running in plain-chat mode.');
    }

    final started = await OrchestratorManager.instance.start(
      backend: OrchestratorBackend.github,
      modelId: model,
      githubApiKey: apiKey,
      temperature: temperature,
      maxTokens: maxTokens,
      tpmLimit: tpmLimit,
      disableTools: disableTools,
    );
    final stderr = OrchestratorManager.instance.stderrLog;
    if (stderr.isNotEmpty) {
      for (final l in const LineSplitter().convert(stderr)) {
        _appendLog(l);
      }
    }
    _appendLog(started
        ? 'GitHub Models orchestrator running.'
        : 'Failed to start GitHub Models orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started
            ? 'GitHub Models orchestrator running'
            : 'Failed to start — check log'),
        backgroundColor: started ? AppTheme.accentMarrone : AppTheme.danger,
      ),
    );
  }

  // ---- Developer panel (side-nav section 3) ---------------------------------

  Widget _buildDeveloperPanel() {
    // Lazy-load the persisted external-tools paths the first time the panel
    // is built — keeps initState lean for users who never open Developer.
    if (!_externalPathsLoaded) {
      _externalPathsLoaded = true;
      _loadExternalToolPaths();
    }
    // Lazy-load filesystem filter lists the first time the panel opens.
    if (!_filtersLoaded) {
      _filtersLoaded = true;
      _loadFilters();
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildExternalToolsSection(),
              const SizedBox(height: 24),
              _buildFilesystemFiltersSection(),
              const SizedBox(height: 24),
              if (kDebugMode) _buildInnoSetupSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExternalToolsSection() {
    return _section(
      title: "External Tools",
      subtitle:
          "Tell the orchestrator subprocess where to find the Flutter SDK and "
          "the Python interpreter. The Flutter SDK path is prepended to the "
          "subprocess PATH so tools like `flutter analyze` resolve without "
          "needing system-wide PATH setup. The Python path overrides the "
          "default interpreter used to launch the orchestrator. Leave a field "
          "blank to fall back to the system default.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pathField(
            label: "Flutter SDK path",
            hint: r"e.g. C:\src\flutter   (the folder that contains bin\flutter)",
            controller: _flutterSdkPathController,
            onPick: () => _pickFlutterSdkPath(),
            onSave: () => _saveFlutterSdkPath(),
            onClear: () => _clearFlutterSdkPath(),
          ),
          const SizedBox(height: 16),
          _pathField(
            label: "Python interpreter path",
            hint: Platform.isWindows
                ? r"e.g. C:\Python312\python.exe"
                : "e.g. /usr/bin/python3.12",
            controller: _pythonPathController,
            onPick: () => _pickPythonPath(),
            onSave: () => _savePythonPath(),
            onClear: () => _clearPythonPath(),
          ),
          const SizedBox(height: 8),
          const Text(
            "Changes take effect the next time the orchestrator subprocess starts.",
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _pathField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required VoidCallback onPick,
    required VoidCallback onSave,
    required VoidCallback onClear,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: "Browse...",
              onPressed: onPick,
              icon: const Icon(Icons.folder_open_outlined, size: 20),
            ),
            IconButton(
              tooltip: "Save",
              onPressed: onSave,
              icon: const Icon(Icons.save_outlined, size: 20),
            ),
            IconButton(
              tooltip: "Clear (use system default)",
              onPressed: onClear,
              icon: const Icon(Icons.clear, size: 20),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _loadExternalToolPaths() async {
    final flutter =
        await SettingsRepository.instance.getFlutterSdkPath() ?? '';
    final python = await SettingsRepository.instance.getPythonPath() ?? '';
    if (!mounted) return;
    setState(() {
      _flutterSdkPathController.text = flutter;
      _pythonPathController.text = python;
    });
  }

  Future<void> _pickFlutterSdkPath() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: "Select Flutter SDK root (folder containing bin/flutter)",
    );
    if (path == null || !mounted) return;
    setState(() => _flutterSdkPathController.text = path);
    await _saveFlutterSdkPath();
  }

  Future<void> _pickPythonPath() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: "Select Python interpreter",
      type: FileType.any,
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    setState(() => _pythonPathController.text = path);
    await _savePythonPath();
  }

  Future<void> _saveFlutterSdkPath() async {
    final value = _flutterSdkPathController.text.trim();
    if (value.isEmpty) {
      await SettingsRepository.instance.clearFlutterSdkPath();
    } else {
      await SettingsRepository.instance.setFlutterSdkPath(value);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Flutter SDK path saved"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _savePythonPath() async {
    final value = _pythonPathController.text.trim();
    if (value.isEmpty) {
      await SettingsRepository.instance.clearPythonPath();
    } else {
      await SettingsRepository.instance.setPythonPath(value);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Python path saved"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _clearFlutterSdkPath() async {
    await SettingsRepository.instance.clearFlutterSdkPath();
    if (!mounted) return;
    setState(() => _flutterSdkPathController.text = '');
  }

  Future<void> _clearPythonPath() async {
    await SettingsRepository.instance.clearPythonPath();
    if (!mounted) return;
    setState(() => _pythonPathController.text = '');
  }

  // ---- Filesystem filters (Developer panel) --------------------------------

  Future<void> _loadFilters() async {
    final workingDir = ProjectService().currentPath;
    final excludeDirs = await DevFiltersRepository.instance.getList(workingDir, DevFiltersRepository.kExcludeDirs);
    final includeDirs = await DevFiltersRepository.instance.getList(workingDir, DevFiltersRepository.kIncludeDirs);
    final excludeFiles = await DevFiltersRepository.instance.getList(workingDir, DevFiltersRepository.kExcludeFiles);
    final includeFiles = await DevFiltersRepository.instance.getList(workingDir, DevFiltersRepository.kIncludeFiles);
    if (!mounted) return;
    setState(() {
      _filtersWorkingDir = workingDir;
      _excludeDirs = List<String>.from(excludeDirs);
      _includeDirs = List<String>.from(includeDirs);
      _excludeFiles = List<String>.from(excludeFiles);
      _includeFiles = List<String>.from(includeFiles);
    });
  }

  Future<void> _saveFilterList(String category) async {
    final workingDir = _filtersWorkingDir ?? ProjectService().currentPath;
    List<String> items;
    switch (category) {
      case DevFiltersRepository.kExcludeDirs:
        items = _excludeDirs;
        break;
      case DevFiltersRepository.kIncludeDirs:
        items = _includeDirs;
        break;
      case DevFiltersRepository.kExcludeFiles:
        items = _excludeFiles;
        break;
      case DevFiltersRepository.kIncludeFiles:
        items = _includeFiles;
        break;
      default:
        return;
    }
    await DevFiltersRepository.instance.setList(workingDir, category, items);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Filters saved'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Shared add/edit dialog. Includes a Browse button that opens a folder
  /// picker for directory categories and a file picker for file
  /// categories — the picked path is dropped into the text field, where
  /// the user can still tweak it (e.g. trim to a relative basename, or
  /// switch a concrete file path to a `*.ext` glob) before confirming.
  Future<String?> _promptFilterValue({
    required String category,
    required String submitLabel,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final label = _filterLabel(category);
    final isDirCategory = category == DevFiltersRepository.kExcludeDirs ||
        category == DevFiltersRepository.kIncludeDirs;

    Future<void> browse() async {
      if (isDirCategory) {
        final picked = await FilePicker.getDirectoryPath(
          dialogTitle: 'Select directory',
          initialDirectory:
              _filtersWorkingDir ?? ProjectService().currentPath,
        );
        if (picked != null && picked.isNotEmpty) {
          controller.text = picked;
        }
      } else {
        final result = await FilePicker.pickFiles(
          dialogTitle: 'Select file',
          initialDirectory:
              _filtersWorkingDir ?? ProjectService().currentPath,
          type: FileType.any,
        );
        final picked = result?.files.single.path;
        if (picked != null && picked.isNotEmpty) {
          controller.text = picked;
        }
      }
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          submitLabel == 'Add' ? 'Add $label entry' : 'Edit $label entry',
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      autofocus: true,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13),
                      decoration: InputDecoration(
                        hintText: _filterHint(category),
                        helperText: _filterHelper(category),
                        helperMaxLines: 2,
                      ),
                      onSubmitted: (_) {
                        final v = controller.text.trim();
                        if (v.isEmpty) return;
                        Navigator.of(ctx).pop<String>(v);
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: isDirCategory
                        ? 'Browse for a directory'
                        : 'Browse for a file (type *.ext for an extension instead)',
                    icon: Icon(
                      isDirCategory
                          ? Icons.folder_open_outlined
                          : Icons.upload_file_outlined,
                      size: 20,
                    ),
                    onPressed: browse,
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) return;
              Navigator.of(ctx).pop<String>(value);
            },
            child: Text(submitLabel),
          ),
        ],
      ),
    );
  }

  void _addFilterEntry(String category) {
    _promptFilterValue(category: category, submitLabel: 'Add').then((value) {
      if (value == null || value.isEmpty) return;
      setState(() {
        switch (category) {
          case DevFiltersRepository.kExcludeDirs:
            _excludeDirs = [..._excludeDirs, value];
            break;
          case DevFiltersRepository.kIncludeDirs:
            _includeDirs = [..._includeDirs, value];
            break;
          case DevFiltersRepository.kExcludeFiles:
            _excludeFiles = [..._excludeFiles, value];
            break;
          case DevFiltersRepository.kIncludeFiles:
            _includeFiles = [..._includeFiles, value];
            break;
        }
      });
      _saveFilterList(category);
    });
  }

  void _editFilterEntry(String category, int index) {
    final current = _filterListFor(category)[index];
    _promptFilterValue(
      category: category,
      submitLabel: 'Save',
      initial: current,
    ).then((value) {
      if (value == null || value.isEmpty) return;
      setState(() {
        switch (category) {
          case DevFiltersRepository.kExcludeDirs:
            _excludeDirs = [..._excludeDirs]..[index] = value;
            break;
          case DevFiltersRepository.kIncludeDirs:
            _includeDirs = [..._includeDirs]..[index] = value;
            break;
          case DevFiltersRepository.kExcludeFiles:
            _excludeFiles = [..._excludeFiles]..[index] = value;
            break;
          case DevFiltersRepository.kIncludeFiles:
            _includeFiles = [..._includeFiles]..[index] = value;
            break;
        }
      });
      _saveFilterList(category);
    });
  }

  void _removeFilterEntry(String category, int index) {
    setState(() {
      switch (category) {
        case DevFiltersRepository.kExcludeDirs:
          _excludeDirs = [..._excludeDirs]..removeAt(index);
          break;
        case DevFiltersRepository.kIncludeDirs:
          _includeDirs = [..._includeDirs]..removeAt(index);
          break;
        case DevFiltersRepository.kExcludeFiles:
          _excludeFiles = [..._excludeFiles]..removeAt(index);
          break;
        case DevFiltersRepository.kIncludeFiles:
          _includeFiles = [..._includeFiles]..removeAt(index);
          break;
      }
    });
    _saveFilterList(category);
  }

  List<String> _filterListFor(String category) {
    switch (category) {
      case DevFiltersRepository.kExcludeDirs:
        return _excludeDirs;
      case DevFiltersRepository.kIncludeDirs:
        return _includeDirs;
      case DevFiltersRepository.kExcludeFiles:
        return _excludeFiles;
      case DevFiltersRepository.kIncludeFiles:
        return _includeFiles;
      default:
        return const [];
    }
  }

  String _filterLabel(String category) {
    switch (category) {
      case DevFiltersRepository.kExcludeDirs:
        return 'excluded directory';
      case DevFiltersRepository.kIncludeDirs:
        return 'included directory';
      case DevFiltersRepository.kExcludeFiles:
        return 'excluded file/extension';
      case DevFiltersRepository.kIncludeFiles:
        return 'included file/extension';
      default:
        return 'filter';
    }
  }

  String _filterHint(String category) {
    switch (category) {
      case DevFiltersRepository.kExcludeDirs:
      case DevFiltersRepository.kIncludeDirs:
        return 'e.g. node_modules, .git, build';
      case DevFiltersRepository.kExcludeFiles:
      case DevFiltersRepository.kIncludeFiles:
        return 'e.g. *.exe, *.png, README';
      default:
        return '';
    }
  }

  String _filterHelper(String category) {
    switch (category) {
      case DevFiltersRepository.kExcludeDirs:
        return 'Bare names match any dir (e.g. build). '
            'Absolute paths match exactly.';
      case DevFiltersRepository.kIncludeDirs:
        return 'Explicitly visible dirs override excludes. '
            'Bare names or absolute paths.';
      case DevFiltersRepository.kExcludeFiles:
        return 'Use *.ext for extensions (e.g. *.exe). '
            'Bare names match exact filenames.';
      case DevFiltersRepository.kIncludeFiles:
        return 'Explicitly visible files override excludes. '
            'Use *.ext or bare names.';
      default:
        return '';
    }
  }

  IconData _filterIcon(String category) {
    switch (category) {
      case DevFiltersRepository.kExcludeDirs:
        return Icons.folder_off_outlined;
      case DevFiltersRepository.kIncludeDirs:
        return Icons.folder_outlined;
      case DevFiltersRepository.kExcludeFiles:
        return Icons.insert_drive_file_outlined;
      case DevFiltersRepository.kIncludeFiles:
        return Icons.description_outlined;
      default:
        return Icons.filter_list;
    }
  }

  Widget _buildFilesystemFiltersSection() {
    final workingDir = _filtersWorkingDir ?? ProjectService().currentPath;
    return _section(
      title: 'Filesystem Filters',
      subtitle: 'Control which directories and files the agent sees in '
          'discovery tools (list_files, search_in_files, find_files, '
          'list_files_recursive). Read/write tools are NOT blocked \u2014 '
          'you can still ask the model to read or edit a specific excluded '
          'path. Inclusion always overrides exclusion. Filters are scoped '
          'to the current project folder.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.bgSecondary,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.border),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_open, size: 16, color: AppTheme.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    workingDir,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _filterListCard(
            category: DevFiltersRepository.kExcludeDirs,
            title: 'Excluded Directories',
            description: 'Directories hidden from discovery. Bare names '
                '(e.g. node_modules) match anywhere; absolute paths match exactly.',
          ),
          const SizedBox(height: 12),
          _filterListCard(
            category: DevFiltersRepository.kIncludeDirs,
            title: 'Included Directories',
            description: 'Directories always visible, overriding excludes. '
                'Use to un-hide a subdirectory inside an excluded tree.',
          ),
          const SizedBox(height: 12),
          _filterListCard(
            category: DevFiltersRepository.kExcludeFiles,
            title: 'Excluded Files / Extensions',
            description: 'Files hidden from discovery. Use *.ext for '
                'extensions (e.g. *.exe) or bare names (e.g. README).',
          ),
          const SizedBox(height: 12),
          _filterListCard(
            category: DevFiltersRepository.kIncludeFiles,
            title: 'Included Files / Extensions',
            description: 'Files always visible, overriding excludes. '
                'Use *.ext or bare names.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Changes are saved immediately. Restart the orchestrator '
            'for changes to take effect in the next session.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _filterListCard({
    required String category,
    required String title,
    required String description,
  }) {
    final items = _filterListFor(category);
    final icon = _filterIcon(category);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                Icon(icon, size: 18, color: AppTheme.accentMarrone),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Add entry',
                  onPressed: () => _addFilterEntry(category),
                  icon: const Icon(Icons.add, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              description,
              style: const TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 6),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                'No entries \u2014 default behaviour applies.',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[500],
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemCount: items.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  thickness: 1,
                  color: AppTheme.border.withAlpha(80),
                ),
                itemBuilder: (ctx, i) {
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    title: Text(
                      items[i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12.5,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Edit',
                          onPressed: () => _editFilterEntry(category, i),
                          icon: const Icon(Icons.edit_outlined, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          onPressed: () => _removeFilterEntry(category, i),
                          icon: const Icon(Icons.delete_outline, size: 16, color: AppTheme.danger),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildInnoSetupSection() {
    return _section(
      title: "Windows Installer",
      subtitle: "Build a release of the Windows app and package it "
          "as an Inno Setup installer. The /bin folder ships with "
          "the installer and is placed under "
          r"%LOCALAPPDATA%\Programs\Agentic\bin "
          "(user-writable, no admin required).",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ElevatedButton.icon(
                onPressed:
                    _installerBusy ? null : _createInnoSetupInstaller,
                icon: _installerBusy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.archive_outlined, size: 16),
                label: Text(_installerBusy
                    ? "Building..."
                    : "Create Inno Setup Installer"),
              ),
              const SizedBox(width: 12),
              if (!_installerBusy && _installerLog.isNotEmpty)
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _installerLog.clear()),
                  icon: const Icon(Icons.clear_all, size: 16),
                  label: const Text("Clear log"),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 280,
            decoration: BoxDecoration(
              color: AppTheme.bgCodeMessageBubble,
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.all(10),
            child: Scrollbar(
              controller: _installerLogScroll,
              child: SelectionArea(
                child: ListView.builder(
                  controller: _installerLogScroll,
                  itemCount: _installerLog.length,
                  itemBuilder: (context, i) => Text(
                    _installerLog[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _appendInstallerLog(String line) {
    if (!mounted) return;
    setState(() => _installerLog.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_installerLogScroll.hasClients) {
        _installerLogScroll.jumpTo(
            _installerLogScroll.position.maxScrollExtent);
      }
    });
  }

  Future<Directory?> _findProjectRoot() async {
    var dir = Directory.current;
    for (var i = 0; i < 6; i++) {
      if (await File('${dir.path}${Platform.pathSeparator}pubspec.yaml')
          .exists()) {
        return dir;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  Future<String?> _findIscc() async {
    final candidates = <String>[
      r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
      r'C:\Program Files\Inno Setup 6\ISCC.exe',
      r'C:\Program Files (x86)\Inno Setup 5\ISCC.exe',
      r'C:\Program Files\Inno Setup 5\ISCC.exe',
    ];
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    try {
      final res = await Process.run('where', ['iscc'], runInShell: true);
      if (res.exitCode == 0) {
        final out = (res.stdout as String).split(RegExp(r'\r?\n'));
        for (final l in out) {
          final t = l.trim();
          if (t.isNotEmpty && File(t).existsSync()) return t;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<int> _runStreamed(
    String exe,
    List<String> args, {
    String? workingDir,
  }) async {
    _appendInstallerLog('> $exe ${args.join(' ')}');
    final proc = await Process.start(
      exe,
      args,
      workingDirectory: workingDir,
      runInShell: true,
    );
    proc.stdout.transform(const SystemEncoding().decoder).listen((d) {
      for (final l in const LineSplitter().convert(d)) {
        if (l.isNotEmpty) _appendInstallerLog(l);
      }
    });
    proc.stderr.transform(const SystemEncoding().decoder).listen((d) {
      for (final l in const LineSplitter().convert(d)) {
        if (l.isNotEmpty) _appendInstallerLog(l);
      }
    });
    return proc.exitCode;
  }

  Future<void> _createInnoSetupInstaller() async {
    if (!Platform.isWindows) {
      _appendInstallerLog('Inno Setup builds are only supported on Windows.');
      return;
    }
    setState(() {
      _installerBusy = true;
      _installerLog.clear();
    });

    try {
      final root = await _findProjectRoot();
      if (root == null) {
        _appendInstallerLog(
            'ERROR: could not locate project root (pubspec.yaml not found).');
        return;
      }
      _appendInstallerLog('Project root: ${root.path}');

      // 1) flutter build windows --release
      _appendInstallerLog('Running: flutter build windows --release');
      final buildExit = await _runStreamed(
        'flutter',
        ['build', 'windows', '--release'],
        workingDir: root.path,
      );
      if (buildExit != 0) {
        _appendInstallerLog('flutter build failed (exit $buildExit).');
        return;
      }

      // 2) Resolve build output directory.
      final candidates = <Directory>[
        Directory('${root.path}\\build\\windows\\x64\\runner\\Release'),
        Directory('${root.path}\\build\\windows\\runner\\Release'),
      ];
      Directory? releaseDir;
      for (final c in candidates) {
        if (await c.exists()) {
          releaseDir = c;
          break;
        }
      }
      if (releaseDir == null) {
        _appendInstallerLog(
            'ERROR: could not find Flutter Windows release output.');
        return;
      }
      _appendInstallerLog('Release output: ${releaseDir.path}');

      // 3) /bin folder.
      final binDir = Directory('${root.path}\\bin');
      if (!await binDir.exists()) {
        _appendInstallerLog(
            'WARN: bin folder not found at ${binDir.path} (continuing without it).');
      }

      // 4) installer/ directory.
      final installerDir = Directory('${root.path}\\installer');
      if (!await installerDir.exists()) await installerDir.create();
      final outputDir = Directory('${installerDir.path}\\Output');
      if (!await outputDir.exists()) await outputDir.create();

      const appName = 'Agentic';
      const appId = '{{A6E2B7D3-1F4E-4B2A-8C5D-AGENTICAPP00001}}';
      const exeName = 'agentic.exe';
      final issPath = '${installerDir.path}\\agentic.iss';

      final iss = StringBuffer()
        ..writeln('; Auto-generated by Agentic — Developer panel')
        ..writeln('[Setup]')
        ..writeln('AppId=$appId')
        ..writeln('AppName=$appName')
        ..writeln('AppVersion=1.0.0')
        ..writeln('AppPublisher=Agentic')
        // Install under %LOCALAPPDATA%\Programs\Agentic so no admin/UAC
        // prompt is required and the orchestrator in /bin can write logs
        // and session files. The \Programs\ subfolder matches the Microsoft
        // convention for per-user app installs (VS Code User, Chrome,
        // Signal, etc.) — separates executables from cache/data that other
        // apps drop directly under LocalAppData.
        ..writeln(r'DefaultDirName={localappdata}\Programs\Agentic')
        ..writeln('DefaultGroupName=$appName')
        ..writeln('DisableProgramGroupPage=yes')
        ..writeln('PrivilegesRequired=lowest')
        ..writeln('PrivilegesRequiredOverridesAllowed=dialog')
        ..writeln('OutputDir=${outputDir.path}')
        ..writeln('OutputBaseFilename=AgenticSetup')
        ..writeln('Compression=lzma2/max')
        ..writeln('SolidCompression=yes')
        ..writeln('WizardStyle=modern')
        ..writeln('ArchitecturesInstallIn64BitMode=x64')
        ..writeln('UninstallDisplayIcon={app}\\$exeName')
        ..writeln()
        ..writeln('[Languages]')
        ..writeln(
            'Name: "english"; MessagesFile: "compiler:Default.isl"')
        ..writeln()
        ..writeln('[Files]')
        // Flutter app binaries go into {app} (= {localappdata}\Programs\Agentic).
        ..writeln(
            'Source: "${releaseDir.path}\\*"; DestDir: "{app}"; '
            'Flags: ignoreversion recursesubdirs createallsubdirs');
      if (await binDir.exists()) {
        // /bin is shipped under {app}\bin — same install root, which is
        // already a writable user location ({localappdata}\Programs\Agentic).
        iss.writeln(
            'Source: "${binDir.path}\\*"; DestDir: "{app}\\bin"; '
            'Flags: ignoreversion recursesubdirs createallsubdirs');
      }
      iss
        ..writeln()
        ..writeln('[Icons]')
        ..writeln(
            'Name: "{group}\\$appName"; Filename: "{app}\\$exeName"')
        ..writeln(
            'Name: "{userdesktop}\\$appName"; Filename: "{app}\\$exeName"; Tasks: desktopicon')
        ..writeln()
        ..writeln('[Tasks]')
        ..writeln(
            'Name: "desktopicon"; Description: "Create a &desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked')
        ..writeln()
        ..writeln('[Run]')
        ..writeln(
            'Filename: "{app}\\$exeName"; Description: "Launch $appName"; Flags: nowait postinstall skipifsilent');

      await File(issPath).writeAsString(iss.toString());
      _appendInstallerLog('Wrote Inno Setup script: $issPath');

      // 5) Run ISCC if available.
      final iscc = await _findIscc();
      if (iscc == null) {
        _appendInstallerLog(
            'ISCC.exe not found. Install Inno Setup 6 from https://jrsoftware.org/isinfo.php');
        _appendInstallerLog(
            'Then compile manually: "<InnoSetup>\\ISCC.exe" "$issPath"');
        return;
      }
      _appendInstallerLog('Found Inno Setup compiler: $iscc');
      final isccExit = await _runStreamed(iscc, [issPath]);
      if (isccExit != 0) {
        _appendInstallerLog('ISCC failed (exit $isccExit).');
        return;
      }
      _appendInstallerLog(
          'Installer built: ${outputDir.path}\\AgenticSetup.exe');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Installer built at ${outputDir.path}\\AgenticSetup.exe'),
            backgroundColor: AppTheme.accentMarrone,
          ),
        );
      }
    } catch (e, st) {
      _appendInstallerLog('ERROR: $e');
      _appendInstallerLog(st.toString());
    } finally {
      if (mounted) setState(() => _installerBusy = false);
    }
  }
}
