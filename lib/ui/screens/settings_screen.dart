import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import '../../services/ollama_manager.dart';
import '../../services/ollama_python_manager.dart';
import '../../services/ollama_service.dart';
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
  final TextEditingController _ollamaPythonUrlController =
      TextEditingController();
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
  final TextEditingController _ollamaNumPredictController =
      TextEditingController();
  final TextEditingController _ollamaNumCtxController =
      TextEditingController();

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

  // Debounce timers for auto-saving fields as the user types.
  Timer? _tokenSaveTimer;
  Timer? _agentTokenSaveTimer;
  Timer? _localServerUrlSaveTimer;
  Timer? _ollamaUrlSaveTimer;
  Timer? _ollamaPythonUrlSaveTimer;
  Timer? _ollamaNumPredictSaveTimer;
  Timer? _ollamaNumCtxSaveTimer;

  @override
  void initState() {
    super.initState();
    _load();
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
    _groqApiKeyController.dispose();
    _groqMaxTokensController.dispose();
    super.dispose();
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
      await AgentCredentialsRepository.instance
          .saveCredentials(AgentCredentials(hfToken: v));
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

  void _scheduleGroqApiKeySave(String value) {
    _groqApiKeySaveTimer?.cancel();
    _groqApiKeySaveTimer = Timer(const Duration(milliseconds: 600), () async {
      final trimmed = value.trim();
      await BackendSettingsRepository.instance.setGroqApiKey(trimmed);
      if (trimmed.isNotEmpty) _refreshGroqModels(trimmed);
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
    await BackendSettingsRepository.instance
        .setGroqModel(_groqSelectedModel ?? models.first);
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
                onPressed: () =>
                    setState(() => _groqApiKeyVisible = !_groqApiKeyVisible),
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
                        value: _groqModels.contains(_groqSelectedModel)
                            ? _groqSelectedModel
                            : _groqModels.first,
                        items: _groqModels
                            .map((m) => DropdownMenuItem(
                                  value: m,
                                  child: Text(m,
                                      style: const TextStyle(fontSize: 13)),
                                ))
                            .toList(),
                        onChanged: (v) async {
                          if (v == null) return;
                          setState(() => _groqSelectedModel = v);
                          await BackendSettingsRepository.instance
                              .setGroqModel(v);
                        },
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Refresh model list',
                onPressed: _groqApiKeyController.text.trim().isNotEmpty
                    ? () => _refreshGroqModels(
                        _groqApiKeyController.text.trim())
                    : null,
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
                    await BackendSettingsRepository.instance
                        .setGroqTemperature(v);
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
              helperText:
                  'Maximum tokens in the response. Groq models support up to '
                  '8192–32768 depending on the model.',
              suffixText: 'tokens',
            ),
            onChanged: _scheduleGroqMaxTokensSave,
          ),
        ],
      ),
    );
  }

  void _scheduleOllamaApiKeySave(String value) {
    _ollamaApiKeySaveTimer?.cancel();
    _ollamaApiKeySaveTimer =
        Timer(const Duration(milliseconds: 600), () async {
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
      final where = Platform.isWindows
          ? 'user environment (restart apps to pick it up)'
          : '~/.zshrc / ~/.bashrc (re-open terminal to pick it up)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('OLLAMA_API_KEY saved to $where')),
      );
    }
  }

  void _scheduleOllamaPythonUrlSave(String value) {
    _ollamaPythonUrlSaveTimer?.cancel();
    _ollamaPythonUrlSaveTimer =
        Timer(const Duration(milliseconds: 400), () async {
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
    final ollamaPythonBridgeUrl =
        await BackendSettingsRepository.instance.getOllamaPythonBridgeUrl();
    final ollamaTemperature =
        await BackendSettingsRepository.instance.getOllamaTemperature();
    final ollamaNumPredict =
        await BackendSettingsRepository.instance.getOllamaNumPredict();
    final ollamaNumCtx =
        await BackendSettingsRepository.instance.getOllamaNumCtx();
    final ollamaApiKey =
        await BackendSettingsRepository.instance.getOllamaApiKey();
    final groqApiKey =
        await BackendSettingsRepository.instance.getGroqApiKey();
    final groqModel =
        await BackendSettingsRepository.instance.getGroqModel();
    final groqTemperature =
        await BackendSettingsRepository.instance.getGroqTemperature();
    final groqMaxTokens =
        await BackendSettingsRepository.instance.getGroqMaxTokens();

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
      _ollamaPythonUrlController.text =
          ollamaPythonBridgeUrl ?? OllamaPythonManager.defaultBridgeUrl;
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
      _loading = false;
    });

    if (backend == LlmBackend.ollama ||
        backend == LlmBackend.ollamaPython ||
        backend == LlmBackend.ollamaOrchestrator) {
      // ignore: unawaited_futures
      _refreshOllamaStatus();
    }
    if (backend == LlmBackend.ollamaPython) {
      // ignore: unawaited_futures
      _refreshOllamaPythonStatus();
    }
    if ((backend == LlmBackend.groq || backend == LlmBackend.groqOrchestrator) &&
        (groqApiKey ?? '').isNotEmpty) {
      // ignore: unawaited_futures
      _refreshGroqModels(groqApiKey!);
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
      await SettingsRepository.instance
          .setSelectedModelId(ApiConstants.defaultModelId);
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
          isAvailable
              ? "✓ Server is reachable"
              : "✗ Server not reachable. Check URL and ensure server is running.",
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: isAvailable ? Colors.green[700] : AppTheme.danger,
      ),
    );
  }

  void _appendLog(String line) {
    if (!mounted) return;
    setState(() {
      _orchestratorLog.add(line);
      // Keep the buffer reasonable.
      if (_orchestratorLog.length > 500) {
        _orchestratorLog.removeRange(0, _orchestratorLog.length - 500);
      }
    });
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
        backgroundColor: ok ? Colors.green[700] : AppTheme.danger,
      ),
    );
  }

  Future<void> _startOrchestrator() async {
    if (_orchestratorBusy) return;
    if (OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend ==
            OrchestratorBackend.huggingface) {
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
    await AgentCredentialsRepository.instance
        .saveCredentials(AgentCredentials(hfToken: token));

    if (OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend !=
            OrchestratorBackend.huggingface) {
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
        content: Text(started
            ? '✓ Orchestrator running'
            : '✗ Failed to start — check log'),
        backgroundColor: started ? Colors.green[700] : AppTheme.danger,
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
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Save the Groq API key first.')),
      );
      return;
    }
    final model = _groqSelectedModel ?? GroqService.fallbackModels.first;

    if (OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend != OrchestratorBackend.groq) {
      await OrchestratorManager.instance.stop();
    }

    setState(() {
      _orchestratorBusy = true;
      _orchestratorLog.clear();
    });
    _appendLog('Starting Groq orchestrator (model: $model)…');

    final temperature = _groqTemperature;
    final maxTokens =
        int.tryParse(_groqMaxTokensController.text.trim()) ??
            BackendSettingsRepository.defaultGroqMaxTokens;

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
    _appendLog(started
        ? '✓ Groq orchestrator running.'
        : '✗ Failed to start Groq orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started
            ? '✓ Groq orchestrator running'
            : '✗ Failed to start — check log'),
        backgroundColor: started ? Colors.green[700] : AppTheme.danger,
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

    if (OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend !=
            OrchestratorBackend.ollama) {
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
    _appendLog(started
        ? 'Ollama orchestrator running.'
        : 'Failed to start Ollama orchestrator.');
    if (!mounted) return;
    setState(() => _orchestratorBusy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(started
            ? 'Ollama orchestrator running'
            : 'Failed to start Ollama orchestrator'),
        backgroundColor: started ? Colors.green[700] : AppTheme.danger,
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
    final up = await OllamaService.instance
        .isServerReachable(baseUrl: _ollamaBaseUrl, apiKey: apiKey);
    List<String> installed = const [];
    if (up) {
      try {
        installed = await OllamaService.instance
            .listInstalledModels(baseUrl: _ollamaBaseUrl, apiKey: apiKey);
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
    final bridgeUp = await OllamaPythonManager.instance
        .isBridgeReachable(bridgeUrl: _ollamaPythonBridgeUrl);
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
        content: Text(ok
            ? 'Ollama installed successfully'
            : 'Ollama install failed - see log'),
        backgroundColor: ok ? Colors.green[700] : AppTheme.danger,
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
        content: Text(ok
            ? '✓ Ollama server is ready'
            : '✗ Ollama server failed to start — see log'),
        backgroundColor: ok ? Colors.green[700] : AppTheme.danger,
      ),
    );
  }

  Future<void> _stopOllamaServer() async {
    if (_ollamaBusy) return;
    if (!OllamaManager.instance.isManagingProcess) {
      _appendOllamaLog(
          'Not managing an ollama subprocess — nothing to stop. '
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
        const SnackBar(
            content: Text('Enter a model name, e.g. llama3 or qwen2.5-coder:7b')),
      );
      return;
    }
    if (!_ollamaServerUp) {
      _appendOllamaLog(
          'Server not reachable. Start it first ("Start Ollama server").');
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
            backgroundColor: Colors.green[700],
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
    _ollamaNumPredictSaveTimer =
        Timer(const Duration(milliseconds: 400), () async {
      final parsed = int.tryParse(value.trim());
      if (parsed == null || parsed <= 0) return;
      setState(() => _ollamaNumPredict = parsed);
      await BackendSettingsRepository.instance.setOllamaNumPredict(parsed);
    });
  }

  void _scheduleNumCtxSave(String value) {
    _ollamaNumCtxSaveTimer?.cancel();
    _ollamaNumCtxSaveTimer =
        Timer(const Duration(milliseconds: 400), () async {
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
    await BackendSettingsRepository.instance
        .setOllamaTemperature(_ollamaTemperature);
    await BackendSettingsRepository.instance
        .setOllamaNumPredict(_ollamaNumPredict);
    await BackendSettingsRepository.instance
        .setOllamaNumCtx(_ollamaNumCtxValue);
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
                child: Text('Temperature',
                    style: TextStyle(fontSize: 12.5)),
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
            what:
                'Controls how random the model is when picking the next word. '
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
            what:
                'num_predict caps how many tokens the model can generate in '
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
            what:
                'num_ctx is the context window — how many tokens (prompt + '
                'past messages + reply) the model can "see" at once. Bigger '
                'window = more history, but KV-cache RAM grows roughly '
                'linearly with it.',
            normalRange:
                '2048 – 32768 (default 4096). Ollama may ship Modelfiles '
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
            example:
                'Raising this from 4096 → 32768 on phi3:mini can push RAM use '
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
        content: Text(ok
            ? 'Python package installed'
            : 'Python package install failed - see log'),
        backgroundColor: ok ? Colors.green[700] : AppTheme.danger,
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
        content: Text(ok
            ? 'Ollama Python bridge is ready'
            : 'Python bridge failed to start - see log'),
        backgroundColor: ok ? Colors.green[700] : AppTheme.danger,
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
  Widget build(BuildContext context) {
    final isOllamaBackend = _activeBackend == LlmBackend.ollama ||
        _activeBackend == LlmBackend.ollamaPython ||
        _activeBackend == LlmBackend.ollamaOrchestrator;
    // Groq manages its own model list inside _groqControlPanel().
    // The HF-specific "Default model" and "Saved models" sections below
    // must be hidden for these backends.
    final isGroqBackend = _activeBackend == LlmBackend.groq ||
        _activeBackend == LlmBackend.groqOrchestrator;

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
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _section(
                        title: "LLM Backend",
                        subtitle: "Choose between remote HF API or local server (Python/transformers, ollama, etc)",
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
                                  items: const [
                                    DropdownMenuItem(
                                      value: LlmBackend.huggingFace,
                                      child: Text("Hugging Face API (Remote)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.orchestrator,
                                      child: Text("🤖 Local Orchestrator (Recommended)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.ollama,
                                      child: Text("🦙 Ollama (Local)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.ollamaOrchestrator,
                                      child: Text(
                                        "🦙🛠️ Ollama + filesystem tools "
                                        "(orchestrator)",
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.local,
                                      child: Text("Local Server (Python)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.ollamaPython,
                                      child: Text("Ollama (Python bridge)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.groq,
                                      child: Text("⚡ Groq Cloud"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.groqOrchestrator,
                                      child: Text("⚡🛠️ Groq + filesystem tools"),
                                    ),
                                  ],
                                  onChanged: (v) async {
                                    if (v != null) {
                                      final messenger = ScaffoldMessenger.of(context);
                                      setState(() => _activeBackend = v);
                                      await BackendSettingsRepository.instance.setActiveBackend(v);
                                      if (v == LlmBackend.ollama ||
                                          v == LlmBackend.ollamaPython ||
                                          v == LlmBackend.ollamaOrchestrator) {
                                        // ignore: unawaited_futures
                                        _refreshOllamaStatus();
                                      }
                                      if (v == LlmBackend.ollamaPython) {
                                        // ignore: unawaited_futures
                                        _refreshOllamaPythonStatus();
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
                                onPressed: _localServerUrl != null && _localServerUrl!.isNotEmpty
                                    ? () => _testLocalServer()
                                    : null,
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
                      ] else if (_activeBackend ==
                          LlmBackend.ollamaOrchestrator) ...[
                        // Show the same Ollama panel (so the user can pull /
                        // select a model) plus a header explaining what this
                        // backend does differently — it wraps the local model
                        // in the orchestrator, granting filesystem tools.
                        _section(
                          title: "🦙🛠️ Ollama + filesystem tools",
                          subtitle:
                              "Routes a local Ollama model through the same "
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
                        _ollamaOrchestratorControlPanel(),
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
                        _groqOrchestratorControlPanel(),
                        const SizedBox(height: 28),
                      ] else if (_activeBackend == LlmBackend.orchestrator) ...[
                        _section(
                          title: "🤖 HF Agent Configuration",
                          subtitle: "Token for the local orchestrator. Stored locally only.",
                          child: Row(
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
                                        _obscureAgentToken
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
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
                              ElevatedButton(
                                onPressed: () async {
                                  final messenger = ScaffoldMessenger.of(context);
                                  final token = _agentTokenController.text.trim();
                                  if (token.isEmpty) {
                                    messenger.showSnackBar(
                                      const SnackBar(content: Text("Token cannot be empty")),
                                    );
                                    return;
                                  }
                                  await AgentCredentialsRepository.instance
                                      .saveCredentials(AgentCredentials(hfToken: token));
                                  if (!mounted) return;
                                  messenger.showSnackBar(
                                    const SnackBar(content: Text("✓ Agent token saved")),
                                  );
                                },
                                child: const Text("Save"),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        _orchestratorControlPanel(),
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
                                        _obscureToken
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
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
                      // Groq manages its own model inside _groqControlPanel(),
                      // so we hide these two sections for Groq backends.
                      if (!isGroqBackend) ...[
                      const SizedBox(height: 28),
                      _section(
                        title: "Default model",
                        subtitle:
                            "Used for new chats. You can still override per conversation.",
                        child: isOllamaBackend
                            ? _ollamaDefaultModelPicker()
                            : Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  border: Border.all(color: AppTheme.border),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    isExpanded: true,
                                    value: _models.any((m) => m.id == _selectedModelId)
                                        ? _selectedModelId
                                        : null,
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
                                  OutlinedButton.icon(
                                    onPressed: _addModel,
                                    icon: const Icon(Icons.add, size: 16),
                                    label: const Text("Add"),
                                  ),
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
                                  children: _models
                                      .map((m) => _modelRow(m))
                                      .toList(),
                                ),
                            ],
                          ),
                        ),
                      ]], // closes if (!isOllamaBackend) and if (!isGroqBackend)
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _orchestratorControlPanel() {
    final running = OrchestratorManager.instance.isRunning;
    final logLines = _combinedOrchestratorLogLines();
    return _section(
      title: "Orchestrator control",
      subtitle: "Install Python dependencies and start the local orchestrator "
          "process. The process runs on this machine and the remote HF model "
          "calls its tools to read/write files locally.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: running ? Colors.green : AppTheme.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                running ? "Running" : "Stopped",
                style: TextStyle(
                  fontSize: 13,
                  color: running ? Colors.green[700] : AppTheme.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_orchestratorBusy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _orchestratorBusy ? null : _installOrchestratorDeps,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text("Install dependencies"),
              ),
              ElevatedButton.icon(
                onPressed: (_orchestratorBusy || running) ? null : _startOrchestrator,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text("Start orchestrator"),
              ),
              OutlinedButton.icon(
                onPressed: (_orchestratorBusy || !running) ? null : _stopOrchestrator,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text("Stop"),
              ),
            ],
          ),
          if (logLines.isNotEmpty) ...[
            const SizedBox(height: 12),
            _logConsole(logLines),
          ],
        ],
      ),
    );
  }

  Widget _ollamaOrchestratorControlPanel() {
    final running = OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend == OrchestratorBackend.ollama;
    final logLines = _combinedOrchestratorLogLines();
    return _section(
      title: "Filesystem tools",
      subtitle: "Start the Ollama-backed orchestrator when you want the local "
          "model to inspect files or execute project tools.",
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: running ? Colors.green : AppTheme.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                running ? "Running" : "Stopped",
                style: TextStyle(
                  fontSize: 13,
                  color: running ? Colors.green[700] : AppTheme.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (_orchestratorBusy)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _orchestratorBusy ? null : _installOrchestratorDeps,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text("Install dependencies"),
              ),
              ElevatedButton.icon(
                onPressed: (_orchestratorBusy || running) ? null : _startOllamaOrchestrator,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text("Start orchestrator"),
              ),
              OutlinedButton.icon(
                onPressed: (_orchestratorBusy || !running) ? null : _stopOrchestrator,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text("Stop"),
              ),
            ],
          ),
          if (logLines.isNotEmpty) ...[
            const SizedBox(height: 12),
            _logConsole(logLines),
          ],
        ],
      ),
    );
  }

  Widget _groqOrchestratorControlPanel() {
    final running = OrchestratorManager.instance.isRunning &&
        OrchestratorManager.instance.currentBackend == OrchestratorBackend.groq;
    final logLines = _combinedOrchestratorLogLines();
    return _section(
      title: '⚡🛠️ Groq + filesystem tools — orchestrator',
      subtitle: 'The local Python orchestrator wraps Groq Cloud so the model '
          'can read/write files and run project commands via tool calls. '
          'Requires the `groq` Python package (Install dependencies below).',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status row
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: running ? Colors.green : AppTheme.textMuted,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                running ? 'Running' : 'Stopped',
                style: TextStyle(
                  fontSize: 13,
                  color: running ? Colors.green[700] : AppTheme.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (running) ...[
                const SizedBox(width: 8),
                Text(
                  'model: ${OrchestratorManager.instance.logLines.isEmpty ? (_groqSelectedModel ?? '—') : (_groqSelectedModel ?? '—')}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textSecondary,
                  ),
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
          const SizedBox(height: 12),
          // Action buttons
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _orchestratorBusy ? null : _installOrchestratorDeps,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Install dependencies'),
              ),
              ElevatedButton.icon(
                onPressed: (_orchestratorBusy || running)
                    ? null
                    : _startGroqOrchestrator,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Start orchestrator'),
              ),
              OutlinedButton.icon(
                onPressed: (_orchestratorBusy || !running)
                    ? null
                    : _stopOrchestrator,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Stop'),
              ),
            ],
          ),
          if (logLines.isNotEmpty) ...[
            const SizedBox(height: 12),
            _logConsole(logLines),
          ],
        ],
      ),
    );
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
          subtitle:
              "Ollama runs LLMs entirely on this machine. Step 1 is a "
              "one-time install of the Ollama binary; everything else "
              "(starting the daemon, pulling models, chatting) is driven "
              "from here.",
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // --- Status row -------------------------------------------------
              Row(
                children: [
                  _statusDot(hasBinary ? Colors.green : AppTheme.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    hasBinary
                        ? 'Binary: ${_ollamaBinaryVersion!}'
                        : 'Binary: not detected',
                    style: TextStyle(
                      fontSize: 13,
                      color: hasBinary ? Colors.green[700] : AppTheme.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 16),
                  _statusDot(serverUp ? Colors.green : AppTheme.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    serverUp
                        ? 'Server: running'
                        : (managing ? 'Server: starting…' : 'Server: stopped'),
                    style: TextStyle(
                      fontSize: 13,
                      color: serverUp ? Colors.green[700] : AppTheme.textMuted,
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
                        style: TextStyle(
                            fontSize: 12.5, color: AppTheme.textMuted),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          ElevatedButton.icon(
                            onPressed: (_ollamaBusy || !OllamaManager.instance.supportsUiInstall)
                                ? null
                                : _installOllamaBinary,
                            icon: const Icon(Icons.download_outlined, size: 14),
                            label: Text(
                              OllamaManager.instance.supportsUiInstall
                                  ? 'Install from UI'
                                  : 'UI install unavailable',
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: () async {
                              await Clipboard.setData(const ClipboardData(
                                  text: 'https://ollama.com/download'));
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Download URL copied: https://ollama.com/download'),
                                ),
                              );
                            },
                            icon: const Icon(Icons.copy, size: 14),
                            label: const Text('Copy download URL'),
                          ),
                          const SizedBox(width: 10),
                          OutlinedButton.icon(
                            onPressed: _ollamaBusy
                                ? null
                                : () => _refreshOllamaStatus(verbose: true),
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
                  helperText:
                      'Local daemon: http://localhost:11434 (default). '
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
                  helperText:
                      'Bearer token for cloud-hosted Ollama endpoints '
                      '(e.g. Ollama Cloud, OpenRouter). '
                      'Local daemon needs no key.',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _ollamaApiKeyVisible
                          ? Icons.visibility_off
                          : Icons.visibility,
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 4),
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
                    onPressed: (_ollamaBusy || !hasBinary || serverUp)
                        ? null
                        : _startOllamaServer,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('Start Ollama server'),
                  ),
                  OutlinedButton.icon(
                    onPressed: (_ollamaBusy || !managing)
                        ? null
                        : _stopOllamaServer,
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text('Stop'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _ollamaBusy
                        ? null
                        : () => _refreshOllamaStatus(verbose: true),
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
              else
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
                      value: _ollamaInstalledModels.contains(_ollamaSelectedModel)
                          ? _ollamaSelectedModel
                          : null,
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
                    onPressed:
                        (_ollamaBusy || !serverUp) ? null : _pullOllamaModel,
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
      subtitle:
          "This approach follows the Python guide: install Ollama, install "
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
                label: hasBinary
                    ? 'Ollama: ${_ollamaBinaryVersion!}'
                    : 'Ollama: not installed',
              ),
              _statusChip(
                ok: serverUp,
                label: serverUp ? 'Daemon: running' : 'Daemon: stopped',
              ),
              _statusChip(
                ok: hasPython,
                label: hasPython
                    ? 'Python: ${_pythonVersion!}'
                    : 'Python: not found',
              ),
              _statusChip(
                ok: hasPackage,
                label: hasPackage
                    ? 'Package: ollama ${_ollamaPythonPackageVersion!}'
                    : 'Package: missing',
              ),
              _statusChip(
                ok: bridgeUp,
                label: bridgeUp
                    ? 'Bridge: running'
                    : (managingBridge ? 'Bridge: starting' : 'Bridge: stopped'),
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
                    onPressed: (_ollamaBusy || !OllamaManager.instance.supportsUiInstall)
                        ? null
                        : _installOllamaBinary,
                    icon: const Icon(Icons.download_outlined, size: 14),
                    label: Text(
                      OllamaManager.instance.supportsUiInstall
                          ? 'Install Ollama'
                          : 'UI install unavailable',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(const ClipboardData(
                          text: 'https://ollama.com/download'));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Download URL copied: https://ollama.com/download'),
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
                onPressed: (_ollamaPythonBusy || !hasPython)
                    ? null
                    : _installOllamaPythonPackage,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('Install Python package'),
              ),
              ElevatedButton.icon(
                onPressed: (_ollamaBusy || !hasBinary || serverUp)
                    ? null
                    : _startOllamaServer,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('Start Ollama daemon'),
              ),
              ElevatedButton.icon(
                onPressed: (_ollamaPythonBusy || !hasPackage || bridgeUp)
                    ? null
                    : _startOllamaPythonBridge,
                icon: const Icon(Icons.play_circle_outline, size: 16),
                label: const Text('Start Python bridge'),
              ),
              OutlinedButton.icon(
                onPressed: (_ollamaPythonBusy || !managingBridge)
                    ? null
                    : _stopOllamaPythonBridge,
                icon: const Icon(Icons.stop, size: 16),
                label: const Text('Stop bridge'),
              ),
              OutlinedButton.icon(
                onPressed: (_ollamaBusy || !OllamaManager.instance.isManagingProcess)
                    ? null
                    : _stopOllamaServer,
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
        color: Colors.white,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _ollamaInstalledModels.contains(_ollamaSelectedModel)
              ? _ollamaSelectedModel
              : null,
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
        else
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
                value: _ollamaInstalledModels.contains(_ollamaSelectedModel)
                    ? _ollamaSelectedModel
                    : null,
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
        border: Border.all(color: ok ? Colors.green : AppTheme.border),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: ok ? Colors.green[700] : AppTheme.textMuted,
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
        color: selected ? AppTheme.bgSecondary : Colors.white,
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
}
