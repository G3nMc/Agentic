import 'package:flutter/material.dart';

import '../../core/constants/server_templates.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/hf_model.dart';
import '../../data/models/local_server_config.dart';
import '../../data/repositories/local_server_config_repository.dart';
import '../../services/local_server_manager.dart';

class LocalServerConfigWidget extends StatefulWidget {
  final HfModel model;

  const LocalServerConfigWidget({super.key, required this.model});

  @override
  State<LocalServerConfigWidget> createState() => _LocalServerConfigWidgetState();
}

class _LocalServerConfigWidgetState extends State<LocalServerConfigWidget> {
  LocalServerConfig? _config;
  bool _loading = true;
  bool _isStarting = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final config = await LocalServerConfigRepository.instance.getByModelId(widget.model.id);
    if (!mounted) return;
    setState(() {
      _config = config ?? _createDefaultConfig();
      _loading = false;
    });
  }

  LocalServerConfig _createDefaultConfig() {
    return LocalServerConfig(
      modelId: widget.model.id,
      pythonCode: defaultPythonServerTemplate.replaceAll("{{MODEL_ID}}", widget.model.id).replaceAll("{{HOST}}", "localhost").replaceAll("{{PORT}}", "5000"),
      host: "localhost",
      port: 5000,
      isEnabled: true,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _saveConfig() async {
    if (_config == null) return;
    await LocalServerConfigRepository.instance.upsert(_config!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Server configuration saved")),
    );
  }

  Future<void> _startServer() async {
    if (_config == null) return;
    setState(() => _isStarting = true);

    try {
      final serverUrl = await LocalServerManager.instance.startServer(_config!);
      if (!mounted) return;
      setState(() {
        _statusMessage = "✓ Server started: $serverUrl";
        _isStarting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Server running on $serverUrl"),
          backgroundColor: Colors.green[700],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = "✗ Failed: $e";
        _isStarting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error: $e"),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  Future<void> _stopServer() async {
    if (_config == null) return;
    await LocalServerManager.instance.stopServer(_config!.modelId);
    if (!mounted) return;
    setState(() => _statusMessage = "Server stopped");
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Server stopped")),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _config == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final isRunning = LocalServerManager.instance.isServerRunning(_config!.modelId);
    final pythonCodeController = TextEditingController(text: _config!.pythonCode);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Python Server: ${widget.model.name}",
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "http://${_config!.host}:${_config!.port}",
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                        fontFamily: "monospace",
                      ),
                    ),
                  ],
                ),
              ),
              if (isRunning)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.green[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_done, size: 16, color: Colors.green[900]),
                      const SizedBox(width: 6),
                      Text(
                        "Running",
                        style: TextStyle(
                          color: Colors.green[900],
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),

          // Python Code Editor (Primary Focus)
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.border),
              borderRadius: BorderRadius.circular(8),
              color: Colors.white,
            ),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: pythonCodeController,
              maxLines: 22,
              minLines: 18,
              style: const TextStyle(fontFamily: "monospace", fontSize: 11.5),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: "# Edit your Python server code here...",
                hintStyle: TextStyle(color: AppTheme.textMuted),
              ),
              onChanged: (v) {
                _config = _config!.copyWith(pythonCode: v);
              },
            ),
          ),
          const SizedBox(height: 16),

          // Templates
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () {
                  pythonCodeController.text =
                      defaultPythonServerTemplate.replaceAll("{{MODEL_ID}}", widget.model.id).replaceAll("{{HOST}}", _config!.host).replaceAll("{{PORT}}", _config!.port.toString());
                  _config = _config!.copyWith(pythonCode: pythonCodeController.text);
                  setState(() {});
                },
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text("Flask Template"),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  pythonCodeController.text = ollamaServerTemplate.replaceAll("{{MODEL_ID}}", widget.model.id);
                  _config = _config!.copyWith(pythonCode: pythonCodeController.text);
                  setState(() {});
                },
                icon: const Icon(Icons.info_outline, size: 14),
                label: const Text("Ollama"),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  pythonCodeController.text = llamaCppTemplate
                      .replaceAll("{{MODEL_ID}}", widget.model.id)
                      .replaceAll("{{HOST}}", _config!.host)
                      .replaceAll("{{PORT}}", _config!.port.toString())
                      .replaceAll("{{MODEL_PATH}}", "/path/to/model.gguf");
                  _config = _config!.copyWith(pythonCode: pythonCodeController.text);
                  setState(() {});
                },
                icon: const Icon(Icons.code, size: 14),
                label: const Text("Llama.cpp"),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Host & Port Config (Collapsible)
          ExpansionTile(
            title: const Text("Server Settings"),
            initiallyExpanded: false,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(labelText: "Host"),
                      onChanged: (v) {
                        _config = _config!.copyWith(host: v);
                      },
                      controller: TextEditingController(text: _config!.host),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      decoration: const InputDecoration(labelText: "Port"),
                      keyboardType: TextInputType.number,
                      onChanged: (v) {
                        _config = _config!.copyWith(port: int.tryParse(v) ?? 5000);
                      },
                      controller: TextEditingController(text: _config!.port.toString()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
          const SizedBox(height: 20),

          // Status Message
          if (_statusMessage != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _statusMessage!.startsWith("✓") ? Colors.green[100] : Colors.red[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _statusMessage!.startsWith("✓") ? Colors.green[300]! : Colors.red[300]!,
                ),
              ),
              child: SelectableText(
                _statusMessage!,
                style: TextStyle(
                  color: _statusMessage!.startsWith("✓") ? Colors.green[900] : Colors.red[900],
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: 16),

          // Action Buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saveConfig,
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text("Save"),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _isStarting || isRunning ? null : _startServer,
                  icon: Icon(
                    _isStarting ? Icons.hourglass_bottom : Icons.play_circle_outline,
                    size: 16,
                  ),
                  label: Text(_isStarting ? "Starting..." : "Start Server"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[700],
                  ),
                ),
              ),
              if (isRunning) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _stopServer,
                    icon: const Icon(Icons.stop_circle_outlined, size: 16),
                    label: const Text("Stop"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.danger,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
