import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/hf_model.dart';
import '../../data/repositories/local_server_config_repository.dart';
import '../../services/local_server_manager.dart';
import 'local_server_config_widget.dart';

class QuickServerPanel extends StatefulWidget {
  final String modelId;
  final VoidCallback onServerStatusChanged;

  const QuickServerPanel({
    super.key,
    required this.modelId,
    required this.onServerStatusChanged,
  });

  @override
  State<QuickServerPanel> createState() => _QuickServerPanelState();
}

class _QuickServerPanelState extends State<QuickServerPanel> {
  HfModel? _model;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // In a real app, you'd fetch the model from ModelRepository
    // For now, create a basic model from ID
    if (!mounted) return;
    setState(() {
      _model = HfModel(
        id: widget.modelId,
        name: widget.modelId.split('/').last,
        isFavorite: false,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _model == null) {
      return const SizedBox.shrink();
    }

    final isRunning = LocalServerManager.instance.isServerRunning(_model!.id);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.code,
                size: 16,
                color: isRunning ? AppTheme.accentSecondary : AppTheme.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Python Server",
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isRunning ? AppTheme.accentSecondary : AppTheme.textPrimary,
                  ),
                ),
              ),
              if (isRunning)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.accentSecondary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    "Running",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accentSecondary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _openFullEditor(context),
                  icon: const Icon(Icons.edit, size: 14),
                  label: const Text("Edit Code"),
                ),
              ),
              const SizedBox(width: 8),
              if (!isRunning)
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _startServer(),
                    icon: const Icon(Icons.play_arrow, size: 14),
                    label: const Text("Start"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.accentSecondary,
                    ),
                  ),
                )
              else
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _stopServer(),
                    icon: const Icon(Icons.stop_circle, size: 14),
                    label: const Text("Stop"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.danger,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _startServer() async {
    if (_model == null) return;
    try {
      final config = await LocalServerConfigRepository.instance.getByModelId(_model!.id);
      if (config == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("No server configuration found. Click 'Edit Code' to set it up."),
          ),
        );
        return;
      }

      await LocalServerManager.instance.startServer(config);
      if (!mounted) return;
      setState(() {});
      widget.onServerStatusChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("✓ Server running at http://${config.host}:${config.port}"),
          backgroundColor: AppTheme.accentSecondary,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error: $e"),
          backgroundColor: AppTheme.danger,
        ),
      );
    }
  }

  Future<void> _stopServer() async {
    if (_model == null) return;
    await LocalServerManager.instance.stopServer(_model!.id);
    if (!mounted) return;
    setState(() {});
    widget.onServerStatusChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Server stopped"),
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _openFullEditor(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bgPrimary,
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.85,
          height: MediaQuery.of(context).size.height * 0.9,
          child: LocalServerConfigWidget(model: _model!),
        ),
      ),
    ).then((_) {
      // Refresh when dialog closes in case server status changed
      setState(() {});
      widget.onServerStatusChanged();
    });
  }
}
