import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/model_repository.dart';
import '../../services/github_models_service.dart';
import '../../services/groq_service.dart';
import '../../services/llm_service.dart';
import '../../services/ollama_service.dart';
import '../../services/openrouter_service.dart';

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
    if (backend == LlmBackend.ollama || backend == LlmBackend.ollamaPython || backend == LlmBackend.ollamaOrchestrator) {
      final ollamaUrl = await BackendSettingsRepository.instance.getOllamaBaseUrl();
      final apiKey = await BackendSettingsRepository.instance.getOllamaApiKey();
      List<String> models = const [];
      try {
        final reachable = await OllamaService.instance.isServerReachable(baseUrl: ollamaUrl, apiKey: apiKey);
        if (reachable) {
          models = await OllamaService.instance.listInstalledModels(baseUrl: ollamaUrl, apiKey: apiKey);
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
        _loading = false;
      });
      return;
    }

    // --- Groq / Groq Orchestrator: fetch model list from Groq API ---
    if (backend == LlmBackend.groq || backend == LlmBackend.groqOrchestrator) {
      final apiKey = await BackendSettingsRepository.instance.getGroqApiKey() ?? '';
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
        final capable = models.where((m) => GroqService.supportsToolCalling(m)).toList();
        // Always keep at least one model available even if the heuristic
        // is wrong or the API returned only reasoning models.
        if (capable.isNotEmpty) models = capable;
      }

      final saved = await BackendSettingsRepository.instance.getGroqModel() ?? '';
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
        _showManualInput = false;
        // Pre-select the model saved in settings.
        if (saved.isNotEmpty && !models.contains(saved) && _manualController.text.isEmpty) {
          _manualController.text = saved;
          _showManualInput = true;
        }
        _loading = false;
      });
      return;
    }

    // --- GitHub Orchestrator: show only the model picked in Settings. ---
    if (backend == LlmBackend.githubOrchestrator) {
      final saved = await BackendSettingsRepository.instance.getGithubModel() ?? '';
      final pinned = saved.isNotEmpty ? saved : GithubModelsService.fallbackModels.first;
      if (!mounted) return;
      setState(() {
        _choices = [_ModelChoice(id: pinned, label: pinned)];
        _showManualInput = false;
        _loading = false;
      });
      return;
    }

    // --- OpenRouter Orchestrator: show only the model picked in Settings. ---
    // The orchestrator is pinned to one OpenRouter model at startup, so
    // per-chat switching doesn't apply — surface a single-entry dropdown.
    if (backend == LlmBackend.openRouterOrchestrator) {
      final saved = await BackendSettingsRepository.instance.getOpenRouterModel() ?? '';
      if (!mounted) return;
      setState(() {
        _choices = saved.isEmpty
            ? const []
            : [_ModelChoice(id: saved, label: saved)];
        _showManualInput = saved.isEmpty;
        _loading = false;
      });
      return;
    }

    // --- OpenRouter (Direct): fetch model list from OpenRouter API ---
    if (backend == LlmBackend.openRouter) {
      final apiKey = await BackendSettingsRepository.instance.getOpenRouterApiKey() ?? '';
      final saved = await BackendSettingsRepository.instance.getOpenRouterModel() ?? '';
      List<String> models = const [];
      if (apiKey.isNotEmpty) {
        try {
          models = await OpenRouterService.instance.listModels(apiKey);
        } catch (_) {
          models = const [];
        }
      }

      final current = resolveOpenRouterModel(widget.selectedModelId, saved);
      final showManual = current.isNotEmpty && !models.contains(current);
      if (showManual && _manualController.text.isEmpty) {
        _manualController.text = current;
      }
      if (showManual) {
        models = [current, ...models.where((m) => m != current)];
      }

      if (!mounted) return;
      setState(() {
        _choices = models.map((m) => _ModelChoice(id: m, label: m)).toList();
        _showManualInput = showManual || models.isEmpty;
        _loading = false;
      });
      return;
    }

    // --- Gemini Orchestrator: show the user-managed Gemini models list. ---
    if (backend == LlmBackend.geminiOrchestrator) {
      final models = await BackendSettingsRepository.instance.getGeminiModels();
      final saved = await BackendSettingsRepository.instance.getGeminiModel() ?? '';
      final list = models.isEmpty
          ? List<String>.from(BackendSettingsRepository.defaultGeminiModels)
          : models;
      final current = saved.isNotEmpty ? saved : list.first;
      if (!mounted) return;
      setState(() {
        _choices = list.map((m) => _ModelChoice(id: m, label: m)).toList();
        _showManualInput = false;
        _loading = false;
      });
      if (current != widget.selectedModelId) {
        widget.onChanged(current);
      }
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
          if (_choices.isNotEmpty) _buildDropdown(),

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
    final current = ids.contains(widget.selectedModelId) ? widget.selectedModelId : (ids.isNotEmpty ? ids.first : widget.selectedModelId);
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.accentMarrone),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _choices.any((m) => m.id == current) ? current : null,
          hint: const Text(
            'Select model',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
          isDense: true,
          isExpanded: true,
          style: const TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          icon: const Icon(Icons.keyboard_arrow_down, size: 16),
          selectedItemBuilder: (context) => _choices
              .map(
                (m) => Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          m.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (!m.supportsTools) ...[
                        const SizedBox(width: 4),
                        const Icon(
                          Icons.warning_amber_rounded,
                          size: 14,
                          color: Colors.orange,
                        ),
                      ],
                    ],
                  ),
                ),
              )
              .toList(),
          items: _choices
              .map(
                (m) => DropdownMenuItem<String>(
                  value: m.id,
                  child: m.supportsTools
                      ? Text(
                          m.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                m.label,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Tooltip(
                              message: 'Reasoning model — no tool calling.\n'
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
              hintStyle: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
