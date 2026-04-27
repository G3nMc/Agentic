import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/agent_role_settings_repository.dart';

/// Settings panel for the multi-agent workflow.
///
/// One row per role (router / shaper / reasoner / executor) with:
///   * backend dropdown — same set Python's `build_backend` knows about,
///   * model text field with suggestion presets,
///   * temperature, max_tokens, tpm fields,
///   * a master "Enable multi-agent mode" switch and a "Reset" button.
///
/// Persistence goes through [AgentRoleSettingsRepository] so the same JSON the
/// Python orchestrator will read at launch time is what the user sees here.
class AgentWorkflowSettings extends StatefulWidget {
  const AgentWorkflowSettings({super.key});

  @override
  State<AgentWorkflowSettings> createState() => _AgentWorkflowSettingsState();
}

class _AgentWorkflowSettingsState extends State<AgentWorkflowSettings> {
  bool _loading = true;
  bool _enabled = false;
  final Map<String, AgentRoleConfig> _configs = {};
  final Map<String, TextEditingController> _modelCtrls = {};
  final Map<String, TextEditingController> _maxTokensCtrls = {};
  final Map<String, TextEditingController> _tpmCtrls = {};
  String? _saving; // role currently being persisted, for the snackbar feedback.

  @override
  void initState() {
    super.initState();
    for (final r in AgentRoleSettingsRepository.roles) {
      _modelCtrls[r] = TextEditingController();
      _maxTokensCtrls[r] = TextEditingController();
      _tpmCtrls[r] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _modelCtrls.values) {
      c.dispose();
    }
    for (final c in _maxTokensCtrls.values) {
      c.dispose();
    }
    for (final c in _tpmCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final enabled = await AgentRoleSettingsRepository.instance.isEnabled();
    final all = await AgentRoleSettingsRepository.instance.getAll();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _configs
        ..clear()
        ..addAll(all);
      for (final r in AgentRoleSettingsRepository.roles) {
        _modelCtrls[r]!.text = all[r]?.model ?? '';
        _maxTokensCtrls[r]!.text = (all[r]?.maxTokens ?? 1024).toString();
        _tpmCtrls[r]!.text = (all[r]?.tpmLimit ?? 0).toString();
      }
      _loading = false;
    });
  }

  Future<void> _persist(String role) async {
    final cfg = _configs[role];
    if (cfg == null) return;
    setState(() => _saving = role);
    await AgentRoleSettingsRepository.instance.set(role, cfg);
    if (!mounted) return;
    setState(() => _saving = null);
  }

  Future<void> _reset() async {
    await AgentRoleSettingsRepository.instance.resetToDefaults();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Workflow agents reset to defaults.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              const SizedBox(height: 16),
              _enableSwitch(),
              const SizedBox(height: 24),
              for (final role in AgentRoleSettingsRepository.roles) ...[
                _roleCard(role),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _reset,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reset to defaults'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Sections ─────────────────────────────────────────────────────────────
  Widget _header() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Workflow Agents',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Pick which model handles each role in the multi-agent pipeline. '
          'Cheap models for routing/shaping; the strong model only for '
          'reasoning. API keys come from the Model Settings tab.',
          style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
        ),
      ],
    );
  }

  Widget _enableSwitch() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enable multi-agent workflow',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'When OFF the orchestrator runs in the original single-agent '
                  'loop. When ON the next start launches the router → shaper → '
                  'reasoner → executor pipeline.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          Switch(
            value: _enabled,
            onChanged: (v) async {
              await AgentRoleSettingsRepository.instance.setEnabled(v);
              setState(() => _enabled = v);
            },
          ),
        ],
      ),
    );
  }

  Widget _roleCard(String role) {
    final cfg = _configs[role]!;
    final saving = _saving == role;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_iconForRole(role), size: 18, color: AppTheme.accent),
              const SizedBox(width: 8),
              Text(
                _titleForRole(role),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _hintForRole(role),
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppTheme.textMuted,
                ),
              ),
              const Spacer(),
              if (saving)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Backend + model row.
          Row(
            children: [
              Expanded(
                flex: 2,
                child: _backendDropdown(role, cfg),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: _modelField(role, cfg),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Temperature + max tokens + TPM row.
          Row(
            children: [
              Expanded(child: _temperatureSlider(role, cfg)),
              const SizedBox(width: 10),
              Expanded(child: _maxTokensField(role)),
              const SizedBox(width: 10),
              Expanded(child: _tpmField(role)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _backendDropdown(String role, AgentRoleConfig cfg) {
    return DropdownButtonFormField<String>(
      // ignore: deprecated_member_use
      value: cfg.backend,
      decoration: const InputDecoration(
        labelText: 'Backend',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final b in AgentRoleSettingsRepository.supportedBackends)
          DropdownMenuItem(value: b, child: Text(b)),
      ],
      onChanged: (v) async {
        if (v == null) return;
        final updated = cfg.copyWith(backend: v);
        setState(() => _configs[role] = updated);
        // When the backend changes, surface the first suggested model so the
        // text field doesn't keep an incompatible model name.
        final suggestions = AgentRoleModelSuggestions.forBackend(v);
        if (suggestions.isNotEmpty &&
            !suggestions.contains(_modelCtrls[role]!.text)) {
          _modelCtrls[role]!.text = suggestions.first;
          setState(() => _configs[role] =
              _configs[role]!.copyWith(model: suggestions.first));
        }
        await _persist(role);
      },
    );
  }

  Widget _modelField(String role, AgentRoleConfig cfg) {
    final suggestions = AgentRoleModelSuggestions.forBackend(cfg.backend);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _modelCtrls[role],
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              setState(
                  () => _configs[role] = cfg.copyWith(model: v.trim()));
            },
            onEditingComplete: () => _persist(role),
            onSubmitted: (_) => _persist(role),
          ),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: 'Suggested models',
            icon: const Icon(Icons.expand_more, size: 18),
            onSelected: (s) async {
              _modelCtrls[role]!.text = s;
              setState(() => _configs[role] = cfg.copyWith(model: s));
              await _persist(role);
            },
            itemBuilder: (_) => [
              for (final s in suggestions)
                PopupMenuItem(value: s, child: Text(s)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _temperatureSlider(String role, AgentRoleConfig cfg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Temp ${cfg.temperature.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        Slider(
          value: cfg.temperature.clamp(0.0, 2.0),
          min: 0.0,
          max: 2.0,
          divisions: 40,
          label: cfg.temperature.toStringAsFixed(2),
          onChanged: (v) {
            setState(() => _configs[role] = cfg.copyWith(temperature: v));
          },
          onChangeEnd: (_) => _persist(role),
        ),
      ],
    );
  }

  Widget _maxTokensField(String role) {
    return TextField(
      controller: _maxTokensCtrls[role],
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'Max tokens',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (v) {
        final parsed = int.tryParse(v.trim());
        if (parsed == null) return;
        setState(() => _configs[role] =
            _configs[role]!.copyWith(maxTokens: parsed));
      },
      onEditingComplete: () => _persist(role),
      onSubmitted: (_) => _persist(role),
    );
  }

  Widget _tpmField(String role) {
    return TextField(
      controller: _tpmCtrls[role],
      keyboardType: TextInputType.number,
      decoration: const InputDecoration(
        labelText: 'TPM (0=∞)',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (v) {
        final parsed = int.tryParse(v.trim());
        if (parsed == null) return;
        setState(() => _configs[role] =
            _configs[role]!.copyWith(tpmLimit: parsed));
      },
      onEditingComplete: () => _persist(role),
      onSubmitted: (_) => _persist(role),
    );
  }

  // ─── Per-role copy ────────────────────────────────────────────────────────
  String _titleForRole(String role) {
    switch (role) {
      case 'router':
        return 'Router';
      case 'shaper':
        return 'Shaper';
      case 'reasoner':
        return 'Reasoner';
      case 'executor':
        return 'Executor';
    }
    return role;
  }

  String _hintForRole(String role) {
    switch (role) {
      case 'router':
        return '— cheapest, classifies the request';
      case 'shaper':
        return '— rewrites prompts (runs once per chat)';
      case 'reasoner':
        return '— strong model, plans + decides';
      case 'executor':
        return '— runs tools, handles trivial replies';
    }
    return '';
  }

  IconData _iconForRole(String role) {
    switch (role) {
      case 'router':
        return Icons.alt_route_outlined;
      case 'shaper':
        return Icons.auto_fix_high_outlined;
      case 'reasoner':
        return Icons.psychology_outlined;
      case 'executor':
        return Icons.build_outlined;
    }
    return Icons.smart_toy_outlined;
  }
}
