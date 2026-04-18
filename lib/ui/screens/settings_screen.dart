import 'dart:async';
import 'dart:convert';

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
import '../../services/llm_service.dart';
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

  // Debounce timers for auto-saving fields as the user types.
  Timer? _tokenSaveTimer;
  Timer? _agentTokenSaveTimer;
  Timer? _localServerUrlSaveTimer;

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
    _tokenController.dispose();
    _agentTokenController.dispose();
    _newModelController.dispose();
    _localServerUrlController.dispose();
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

  Future<void> _load() async {
    final token = await SettingsRepository.instance.getHfToken();
    final selected = await SettingsRepository.instance.getSelectedModelId();
    final models = await ModelRepository.instance.listAll();
    final backend = await BackendSettingsRepository.instance.getActiveBackend();
    final serverUrl = await BackendSettingsRepository.instance.getLocalServerUrl();
    final agentCreds = await AgentCredentialsRepository.instance.getCredentials();

    if (!mounted) return;
    setState(() {
      _tokenController.text = token ?? "";
      _agentTokenController.text = agentCreds?.hfToken ?? "";
      _selectedModelId = selected ?? ApiConstants.defaultModelId;
      _models = models;
      _activeBackend = backend;
      _localServerUrl = serverUrl;
      _localServerUrlController.text = serverUrl ?? "";
      _loading = false;
    });
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
    if (OrchestratorManager.instance.isRunning) return;

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
                                  items: [
                                    DropdownMenuItem(
                                      value: LlmBackend.huggingFace,
                                      child: const Text("Hugging Face API (Remote)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.orchestrator,
                                      child: const Text("🤖 Local Orchestrator (Recommended)"),
                                    ),
                                    DropdownMenuItem(
                                      value: LlmBackend.local,
                                      child: const Text("Local Server (Python)"),
                                    ),
                                  ],
                                  onChanged: (v) async {
                                    if (v != null) {
                                      setState(() => _activeBackend = v);
                                      await BackendSettingsRepository.instance.setActiveBackend(v);
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
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
                      if (_activeBackend == LlmBackend.orchestrator) ...[
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
                                  final token = _agentTokenController.text.trim();
                                  if (token.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text("Token cannot be empty")),
                                    );
                                    return;
                                  }
                                  await AgentCredentialsRepository.instance
                                      .saveCredentials(AgentCredentials(hfToken: token));
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
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
                      const SizedBox(height: 28),
                      _section(
                        title: "Default model",
                        subtitle:
                            "Used for new chats. You can still override per conversation.",
                        child: Container(
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
          if (_orchestratorLog.isNotEmpty) ...[
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
                  _orchestratorLog.join('\n'),
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
    );
  }

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
