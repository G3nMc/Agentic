import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/hf_model.dart';
import '../../data/repositories/model_repository.dart';

class ModelSwitcher extends StatefulWidget {
  final String selectedModelId;
  final ValueChanged<String> onChanged;

  const ModelSwitcher({
    super.key,
    required this.selectedModelId,
    required this.onChanged,
  });

  @override
  State<ModelSwitcher> createState() => _ModelSwitcherState();
}

class _ModelSwitcherState extends State<ModelSwitcher> with WidgetsBindingObserver {
  List<HfModel> _models = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    }
  }

  Future<void> _load() async {
    final list = await ModelRepository.instance.listAll();
    if (!mounted) return;
    setState(() {
      _models = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final ids = _models.map((m) => m.id).toSet();
    final current = ids.contains(widget.selectedModelId)
        ? widget.selectedModelId
        : (ids.isNotEmpty ? ids.first : widget.selectedModelId);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _models.any((m) => m.id == current) ? current : null,
          hint: const Text(
            "Select model",
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          isDense: true,
          style: const TextStyle(
            fontSize: 13,
            color: AppTheme.textPrimary,
          ),
          icon: const Icon(Icons.keyboard_arrow_down, size: 16),
          items: _models
              .map(
                (m) => DropdownMenuItem<String>(
                  value: m.id,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: Text(
                      m.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) widget.onChanged(v);
          },
        ),
      ),
    );
  }
}
