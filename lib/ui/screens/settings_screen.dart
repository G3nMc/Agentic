import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/constants/api_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/agent_credentials.dart';
import '../../data/models/hf_model.dart';
import '../../data/repositories/agent_credentials_repository.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/model_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/groq_service.dart';
import '../../services/llm_service.dart';
import '../../services/ollama_generate_service.dart';
import '../../services/ollama_manager.dart';
import '../../services/ollama_python_manager.dart';
import '../../services/ollama_service.dart';
import '../../services/openrouter_service.dart';
import '../../services/orchestrator_manager.dart';
import '../widgets/local_server_config_widget.dart';

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

  // Settings side-nav: 0 = Model Settings, 1 = Orchestrator
  int _settingsSection = 0;

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
  final List<String> _ollamaLog = [];
  String? _ollamaBinaryVersion; // null => not detected yet or missing
  bool _ollamaServerUp = false;
  List<String> _ollamaInstalledModels = const [];
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
  List<String> _openRouterModels = OpenRouterService.fallbackModels;
  String? _openRouterSelectedModel;
  bool _openRouterLoadingModels = false;
  double _openRouterTemperature = BackendSettingsRepository.defaultOpenRouterTemperature;
  final TextEditingController _openRouterMaxTokensController = TextEditingController();
  Timer? _openRouterMaxTokensSaveTimer;
  final TextEditingController _openRouterTpmLimitController = TextEditingController();
  Timer? _openRouterTpmLimitSaveTimer;

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
        spans.add(TextSpan(
          text: ':free',
          style: const TextStyle(
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
    _ollamaUrlController.dispose();
    _ollamaApiKeyController.dispose();
    _ollamaPullController.dispose();
    _ollamaPythonUrlController.dispose();
    _ollamaNumPredictController.dispose();
    _ollamaNumCtxController.dispose();
    _groqApiKeySaveTimer?.cancel();
    _groqMaxTokensSaveTimer?.cancel();
    _groqTpmLimitSaveTimer?.cancel();
    _groqApiKeyController.dispose();
    _groqMaxTokensController.dispose();
    _groqTpmLimitController.dispose();
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
    final models = await GroqService.instance.listModels(apiKey);
    if (!mounted) return;
    setState(() {
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

    List<String> models = OpenRouterService.fallbackModels;
    if (apiKey.trim().isNotEmpty) {
      models = await OpenRouterService.instance.listModels(apiKey);
    }

    final selected = _openRouterSelectedModel?.trim() ?? '';
    if (selected.isNotEmpty && !models.contains(selected)) {
      models = [selected, ...models];
    }

    final nextSelected = models.contains(_openRouterSelectedModel) ? (_openRouterSelectedModel ?? models.first) : models.first;

    if (!mounted) return;
    setState(() {
      _openRouterModels = models;
      _openRouterSelectedModel = nextSelected;
      _openRouterLoadingModels = false;
    });
    await BackendSettingsRepository.instance.setOpenRouterModel(nextSelected);
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
          TextField(
            controller: _groqMaxTokensController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Max completion tokens',
              hintText: '4096',
              helperText: 'Maximum tokens in the response. Groq models support up to '
                  '8192–32768 depending on the model.',
              suffixText: 'tokens',
            ),
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
        ],
      ),
    );
  }

  List<String> _openRouterModelOptions() {
    return _openRouterModels;
  }

  Widget _openRouterControlPanel() {
    final modelOptions = _openRouterModelOptions();
    final selectedModel = modelOptions.contains(_openRouterSelectedModel) ? _openRouterSelectedModel : modelOptions.first;

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
                    : DropdownButton<String>(
                        isExpanded: true,
                        value: selectedModel,
                        items: modelOptions
                            .map(
                              (m) => DropdownMenuItem<String>(
                                value: m,
                                child: RichText(
                                  text: TextSpan(
                                    children: _buildModelTextSpans(m),
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _openRouterSelectedModel = v);
                          await BackendSettingsRepository.instance.setOpenRouterModel(v);
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
          TextField(
            controller: _openRouterMaxTokensController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Max completion tokens',
              hintText: '4096',
              helperText: 'OpenRouter uses `max_tokens` for the completion budget.',
              suffixText: 'tokens',
            ),
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
          TextField(
            controller: _geminiMaxTokensController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Max output tokens',
              hintText: '2048',
              helperText: 'Maximum tokens the model can emit in one call.',
              suffixText: 'tokens',
            ),
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

  String get pythonExecutableLabel => OrchestratorManager.pythonExecutable;

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
              hintText: 'http://localhost:11434',
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
          TextField(
            controller: _generateNumPredictController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Max tokens (num_predict)',
              hintText: '2048',
              suffixText: 'tokens',
            ),
            onChanged: (v) async {
              final n = int.tryParse(v.trim());
              if (n != null && n > 0) {
                await BackendSettingsRepository.instance.setGenerateNumPredict(n);
              }
            },
          ),
          const SizedBox(height: 12),

          // num_ctx
          TextField(
            controller: _generateNumCtxController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Context window (num_ctx)',
              hintText: '4096',
              helperText: 'Tokens the model can "see". Higher = more memory. '
                  '4096 is safe for most hardware.',
              suffixText: 'tokens',
            ),
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
      _selectedModelId = selected ?? ApiConstants.defaultModelId;
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
      _openRouterSelectedModel = openRouterModel ?? OpenRouterService.fallbackModels.first;
      _openRouterTemperature = openRouterTemperature;
      _openRouterMaxTokensController.text = openRouterMaxTokens.toString();
      _openRouterTpmLimitController.text = openRouterTpmLimit.toString();
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
    if (backend == LlmBackend.openRouter) {
      // ignore: unawaited_futures
      _refreshOpenRouterModels(openRouterApiKey ?? '');
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
      await SettingsRepository.instance.setSelectedModelId(ApiConstants.defaultModelId);
      _selectedModelId = ApiConstants.defaultModelId;
    }
    await _load();
  }

  Future<void> _setSelected(String id) async {
    await SettingsRepository.instance.setSelectedModelId(id);
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
    setState(() {
      _ollamaBusy = true;
    });
    _appendOllamaLog('Pulling "$name"… this may take several minutes.');
    try {
      await OllamaService.instance.pullModel(
        name,
        baseUrl: _ollamaBaseUrl,
        onProgress: _appendOllamaLog,
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
      _appendOllamaLog('✗ Pull failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✗ Pull failed: $e'),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _ollamaBusy = false);
    }
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
            children: [
              Expanded(
                child: TextField(
                  controller: _ollamaNumPredictController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Max output tokens (num_predict)',
                    helperText: 'e.g. 2048',
                  ),
                  onChanged: _scheduleNumPredictSave,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _ollamaNumCtxController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Context window (num_ctx)',
                    helperText: 'e.g. 4096',
                  ),
                  onChanged: _scheduleNumCtxSave,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _helperBlock(
            what: 'num_predict caps how many tokens the model can generate in '
                'ONE reply. It stops the model mid-sentence if it tries to '
                'go longer — useful to prevent runaway generations that take '
                'minutes on small models.',
            normalRange: '256 – 8192 (default 2048). ~1 token ≈ 0.75 English '
                'words or ~3 characters of code.',
            bestFor: [
              '256–512 — short replies, tool calls, quick classification.',
              '1024–2048 — typical coding answers, a single file edit, '
                  'explanations (the app default).',
              '4096–8192 — long essays, whole-file rewrites. On a 3B model '
                  'this can take several minutes — consider raising '
                  'cautiously.',
            ],
            example: 'At 4 tok/s on phi3:mini, num_predict=8192 could burn '
                'over 30 min if the model decides to actually use it all.',
          ),
          const SizedBox(height: 10),
          _helperBlock(
            what: 'num_ctx is the context window — how many tokens (prompt + '
                'past messages + reply) the model can "see" at once. Bigger '
                'window = more history, but KV-cache RAM grows roughly '
                'linearly with it.',
            normalRange: '2048 – 32768 (default 4096). Ollama may ship Modelfiles '
                'defaulting to 128K — that can cost 30–50 GiB of RAM on '
                'a tiny model, so this app caps at 4096 by default.',
            bestFor: [
              '2048 — chit-chat, single-file reads. Lowest RAM.',
              '4096 — app default, fits a few read_file results + history.',
              '8192–16384 — multi-file edits, reading large config/log '
                  'files. Needs a 7B+ model and >= 16 GB RAM to be comfy.',
              '32768+ — rarely worth it; prompt-eval time grows with context '
                  'and small models ignore most of it anyway.',
            ],
            example: 'Raising this from 4096 → 32768 on phi3:mini can push RAM use '
                'from ~2 GB to >10 GB for the same conversation.',
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
                  child: _settingsSection == 0 ? _buildModelSettings() : _buildOrchestratorPanel(),
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
        ],
      ),
    );
  }

  Widget _navItem(String label, int index, IconData icon) {
    final selected = _settingsSection == index;
    return Material(
      color: selected ? AppTheme.accent.withOpacity(0.12) : Colors.transparent,
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
                            helperText: "Auto-saved on change. Get from https://huggingface.co/settings/tokens",
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
              if (!isGroqBackend && !isGeminiBackend && !isOpenRouterBackend) ...[
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

  // ---- Orchestrator panel (side-nav section 1) ------------------------------

  Widget _buildOrchestratorPanel() {
    final running = OrchestratorManager.instance.isRunning;
    final needsOrchestrator = _activeBackend == LlmBackend.orchestrator ||
        _activeBackend == LlmBackend.ollamaOrchestrator ||
        _activeBackend == LlmBackend.groqOrchestrator ||
        _activeBackend == LlmBackend.geminiOrchestrator ||
        _activeBackend == LlmBackend.openRouterOrchestrator;

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
    }
  }

  List<String> _combinedOrchestratorLogLines() {
    final combined = <String>[..._orchestratorLog];
    final runtime = OrchestratorManager.instance.stderrLog;
    if (runtime.isNotEmpty) {
      for (final line in const LineSplitter().convert(runtime)) {
        if (line.trim().isEmpty) continue;
        if (!combined.contains(line)) {
          combined.add(line);
        }
      }
    }
    return combined;
  }

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
                              await Clipboard.setData(const ClipboardData(text: 'https://ollama.com/download'));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Download URL copied: https://ollama.com/download'),
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
                  helperText: 'Local daemon: http://localhost:11434 (default). '
                      'Cloud: use the URL from your Ollama account '
                      '(e.g. https://api.ollama.ai). Auto-saved.',
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
                ],
              ),

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
                      await Clipboard.setData(const ClipboardData(text: 'https://ollama.com/download'));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Download URL copied: https://ollama.com/download'),
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
        color: Colors.black,
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
          color: selected ? AppTheme.accent.withOpacity(0.4) : AppTheme.border,
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
    final model = _openRouterSelectedModel ?? OpenRouterService.fallbackModels.first;

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
}
