import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/model_repository.dart';
import '../../services/groq_service.dart';
import '../../services/llm_service.dart';
import '../../services/ollama_service.dart';

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
  List<_ModelChoice> _choices = [];
  bool _loading = true;
  // Shown as a text field below the dropdown when either the list is
  // empty (endpoint returned nothing) or the user clicks "Enter manually".
  bool _showManualInput = false;
  final TextEditingController _manualController = TextEditingController();

  // True when the active backend has its own model API (Ollama, Groq).
  // For these backends the "Enter cloud model name…" button is hidden —
  // users should pick from the list returned by the backend, not type
  // a name manually.  The button stays for HuggingFace/local where
  // discovering models happens outside this widget.
  bool _backendHasApiModelList = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _manualController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load();
    }
  }

  Future<void> _load() async {
    final backend = await BackendSettingsRepository.instance.getActiveBackend();

    // --- Ollama backends: fetch installed models from the daemon ---
    if (backend == LlmBackend.ollama ||
        backend == LlmBackend.ollamaPython ||
        backend == LlmBackend.ollamaOrchestrator) {
      final ollamaUrl =
          await BackendSettingsRepository.instance.getOllamaBaseUrl();
      final apiKey =
          await BackendSettingsRepository.instance.getOllamaApiKey();
      List<String> models = const [];
      try {
        final reachable = await OllamaService.instance
            .isServerReachable(baseUrl: ollamaUrl, apiKey: apiKey);
        if (reachable) {
          models = await OllamaService.instance
              .listInstalledModels(baseUrl: ollamaUrl, apiKey: apiKey);
        }
      } catch (_) {
        models = const [];
      }
      if (!mounted) return;
      final showManual = models.isEmpty;
      if (showManual && _manualController.text.isEmpty) {
        _manualController.text = widget.selectedModelId;
      }
      setState(() {
        _choices = models.map((m) => _ModelChoice(id: m, label: m)).toList();
        _showManualInput = showManual;
        _backendHasApiModelList = true; // Ollama has its own model list
        _loading = false;
      });
      return;
    }

    // --- Groq / Groq Orchestrator: fetch model list from Groq API ---
    if (backend == LlmBackend.groq || backend == LlmBackend.groqOrchestrator) {
      final apiKey =
          await BackendSettingsRepository.instance.getGroqApiKey() ?? '';
      List<String> models = GroqService.fallbackModels;
      if (apiKey.isNotEmpty) {
        try {
          models = await GroqService.instance.listModels(apiKey);
        } catch (_) {
          models = GroqService.fallbackModels;
        }
      }

      // For the orchestrator backend, only offer models that support tool
      // calling.  Reasoning models (DeepSeek-R1, QwQ, …) return a 400 when
      // the `tools` parameter is sent and produce unreliable results with the
      // text-based fallback.
      if (backend == LlmBackend.groqOrchestrator) {
        final capable = models
            .where((m) => GroqService.supportsToolCalling(m))
            .toList();
        // Always keep at least one model available even if the heuristic
        // is wrong or the API returned only reasoning models.
        if (capable.isNotEmpty) models = capable;
      }

      final saved =
          await BackendSettingsRepository.instance.getGroqModel() ?? '';
      if (!mounted) return;
      setState(() {
        _choices = models
            .map((m) => _ModelChoice(
                  id: m,
                  label: m,
                  // Mark models that don't support tools so users know they
                  // might behave differently with the orchestrator.
                  supportsTools: GroqService.supportsToolCalling(m),
                ))
            .toList();
        _backendHasApiModelList = true; // Groq has its own model list
        _showManualInput = false;
        // Pre-select the model saved in settings.
        if (saved.isNotEmpty &&
            !models.contains(saved) &&
            _manualController.text.isEmpty) {
          _manualController.text = saved;
          _showManualInput = true;
        }
        _loading = false;
      });
      return;
    }

    // --- HuggingFace / local / orchestrator: use the HF model repository ---
    final list = await ModelRepository.instance.listAll();
    if (!mounted) return;
    setState(() {
      _choices = list.map((m) => _ModelChoice(id: m.id, label: m.name)).toList();
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

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 160, maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dropdown — only shown when the endpoint returned models.
          if (_choices.isNotEmpty) ...[
            _buildDropdown(),
            // "Enter cloud model name…" is only useful for HuggingFace /
            // local backends where models aren't fetched from an API.
            // For Groq and Ollama (which have their own model lists) this
            // button is hidden so the UI shows exactly one selector.
            if (!_showManualInput && !_backendHasApiModelList)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => setState(() => _showManualInput = true),
                  child: const Text(
                    'Enter cloud model name…',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
              ),
          ],

          // Manual text input — shown when no models listed (endpoint
          // returned nothing) or the user explicitly requested it.
          if (_showManualInput) ...[
            if (_choices.isNotEmpty) const SizedBox(height: 6),
            _buildManualInput(),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdown() {
    final ids = _choices.map((m) => m.id).toSet();
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
          value: _choices.any((m) => m.id == current) ? current : null,
          hint: const Text(
            'Select model',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          isDense: true,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          icon: const Icon(Icons.keyboard_arrow_down, size: 16),
          items: _choices
              .map(
                (m) => DropdownMenuItem<String>(
                  value: m.id,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: m.supportsTools
                        ? Text(
                            m.label,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: Text(
                                  m.label,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              const Tooltip(
                                message:
                                    'Reasoning model — no tool calling.\n'
                                    'Use with plain Groq backend only.',
                                child: Icon(
                                  Icons.warning_amber_rounded,
                                  size: 14,
                                  color: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              )
              .toList(),
          onChanged: (v) {
            if (v != null) {
              setState(() => _showManualInput = false);
              widget.onChanged(v);
            }
          },
        ),
      ),
    );
  }

  Widget _buildManualInput() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _manualController,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'e.g. gemma4:27b-it-qat-q4_K_M or gemma4:31b-cloud',
              hintStyle: const TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              // Show a clear button when there's text.
              suffixIcon: _manualController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _manualController.clear();
                        setState(() {});
                      },
                    )
                  : null,
            ),
            onChanged: (v) => setState(() {}),
            onSubmitted: (v) {
              final trimmed = v.trim();
              if (trimmed.isNotEmpty) widget.onChanged(trimmed);
            },
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: const Icon(Icons.check_circle_outline, size: 20),
          tooltip: 'Use this model',
          onPressed: () {
            final trimmed = _manualController.text.trim();
            if (trimmed.isNotEmpty) widget.onChanged(trimmed);
          },
        ),
      ],
    );
  }
}

class _ModelChoice {
  final String id;
  final String label;
  /// True when the model supports the Groq native tool-calling API.
  /// Defaults to true for non-Groq backends where it is irrelevant.
  final bool supportsTools;

  const _ModelChoice({
    required this.id,
    required this.label,
    this.supportsTools = true,
  });
}
