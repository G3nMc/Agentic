import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/agent_role_settings_repository.dart';
import '../../data/repositories/backend_settings_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/ollama_service.dart';
import '../../services/openrouter_service.dart';
import 'team_board_viewer.dart';
import 'token_count_picker.dart';

/// Settings panel for the multi-agent workflow.
///
/// Architecture:
///   * Holds a [WorkflowAgents] aggregate (the ORM-ish bag of all four role
///     configs) and binds every form widget to it.
///   * Persists on every change via a 400ms debounce + on focus loss, so the
///     user never has to remember to press Enter.
///   * Per-row "Refresh models" button calls the backend's live `listModels`
///     endpoint; results are cached for the rest of the session.
///   * Falls back to a static suggestions list when a backend has no API
///     (Gemini, HuggingFace).
class AgentWorkflowSettings extends StatefulWidget {
  const AgentWorkflowSettings({super.key});

  @override
  State<AgentWorkflowSettings> createState() => _AgentWorkflowSettingsState();
}

class _AgentWorkflowSettingsState extends State<AgentWorkflowSettings> {
  bool _loading = true;
  bool _enabled = false;
  bool _teamMode = false;
  List<WorkflowGroup> _groups = [];
  String _activeGroupId = '';

  // The two core roles plus the optional 'leader' role used by Team Mode.
  // The leader's controllers/state share the same maps as the other roles
  // — only the rendering is gated on [_teamMode].
  static const _kAllRolesIncludingLeader = <String>[
    'reasoner',
    'summarizer',
    AgentRoleSettingsRepository.leaderRole,
  ];

  // The aggregate — single source of truth for the form.
  WorkflowAgents _agents = WorkflowAgents({});

  // Per-role text controllers (kept in sync with [_agents]).
  final Map<String, TextEditingController> _modelCtrls = {};
  final Map<String, TextEditingController> _maxTokensCtrls = {};
  final Map<String, TextEditingController> _tpmCtrls = {};
  final Map<String, TextEditingController> _ollamaUrlCtrls = {};
  final Map<String, TextEditingController> _ollamaCtxCtrls = {};

  // Per-role reasoning level (no controller needed — dropdown tracks it).
  final Map<String, String> _reasoningLevels = {};

  // Per-role debounce timers — coalesce rapid edits into a single save.
  final Map<String, Timer> _saveTimers = {};

  // Per-role transient state for save-feedback indicator.
  final Map<String, _SaveState> _saveState = {};

  // Per-(backend,model-input) cached model list. Refreshes only on user
  // request via the refresh button — never auto-fetched.
  final Map<String, List<String>> _modelsCache = {};

  // Per-role flag while a fetch is in-flight (drives the spinner).
  final Map<String, bool> _modelsLoading = {};

  @override
  void initState() {
    super.initState();
    for (final r in _kAllRolesIncludingLeader) {
      _modelCtrls[r] = TextEditingController();
      _maxTokensCtrls[r] = TextEditingController();
      _tpmCtrls[r] = TextEditingController();
      _ollamaUrlCtrls[r] = TextEditingController();
      _ollamaCtxCtrls[r] = TextEditingController();
    }
    _load();
    AgentRoleSettingsRepository.instance.activeGroupNotifier
        .addListener(_onActiveGroupChanged);
  }

  @override
  void dispose() {
    for (final t in _saveTimers.values) {
      t.cancel();
    }
    for (final c in _modelCtrls.values) {
      c.dispose();
    }
    for (final c in _maxTokensCtrls.values) {
      c.dispose();
    }
    for (final c in _tpmCtrls.values) {
      c.dispose();
    }
    for (final c in _ollamaUrlCtrls.values) {
      c.dispose();
    }
    for (final c in _ollamaCtxCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ─── Load / save plumbing ────────────────────────────────────────────────
  Future<void> _load() async {
    final enabled = await AgentRoleSettingsRepository.instance.isEnabled();
    final teamMode =
        await AgentRoleSettingsRepository.instance.isTeamModeEnabled();
    final groups = await AgentRoleSettingsRepository.instance.listGroups();
    final activeGroupId =
        await AgentRoleSettingsRepository.instance.getActiveGroupId();
    final agents = await WorkflowAgents.loadGroup(activeGroupId);
    // Load the leader role separately — it isn't in WorkflowAgents.byRole
    // by default, but its controllers need a value either way so the UI
    // doesn't flicker when the toggle flips on.
    final leaderCfg =
        await AgentRoleSettingsRepository.instance.getLeader(activeGroupId);
    agents.put(AgentRoleSettingsRepository.leaderRole, leaderCfg);
    // Gemini is the only backend with a *user-editable* saved list (in the
    // Gemini Settings panel the user can add e.g. gemma4). Read it here so
    // the role's model dropdown shows the same options the dedicated panel
    // does, not just the hardcoded defaults.
    final geminiSaved =
        await BackendSettingsRepository.instance.getGeminiModels();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _teamMode = teamMode;
      _groups = groups;
      _activeGroupId = activeGroupId;
      _agents = agents;
      if (geminiSaved.isNotEmpty) _modelsCache['gemini'] = geminiSaved;
      for (final r in _kAllRolesIncludingLeader) {
        final cfg = agents.get(r);
        _modelCtrls[r]!.text = cfg.model;
        _maxTokensCtrls[r]!.text = cfg.maxTokens.toString();
        _tpmCtrls[r]!.text = cfg.tpmLimit.toString();
        _ollamaUrlCtrls[r]!.text = cfg.ollamaBaseUrl ?? '';
        _ollamaCtxCtrls[r]!.text = cfg.ollamaNumCtx?.toString() ?? '';
        _reasoningLevels[r] = cfg.reasoningLevel.isNotEmpty ? cfg.reasoningLevel : 'max';
      }
      _loading = false;
    });
  }

  void _scheduleSave(String role) {
    _saveTimers[role]?.cancel();
    setState(() => _saveState[role] = _SaveState.dirty);
    _saveTimers[role] = Timer(const Duration(milliseconds: 400), () {
      _persist(role);
    });
  }

  Future<void> _persistImmediately(String role) async {
    _saveTimers[role]?.cancel();
    await _persist(role);
  }

  Future<void> _persist(String role) async {
    if (!mounted) return;
    setState(() => _saveState[role] = _SaveState.saving);
    try {
      await _agents.saveRole(role);
      if (!mounted) return;
      setState(() => _saveState[role] = _SaveState.saved);
      // After 1.2s drop the "saved" tick.
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (!mounted) return;
        if (_saveState[role] == _SaveState.saved) {
          setState(() => _saveState[role] = _SaveState.idle);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saveState[role] = _SaveState.error);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed for $role: $e')),
      );
    }
  }

  Future<void> _reset() async {
    await AgentRoleSettingsRepository.instance.resetToDefaults();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Workflow agents reset to defaults.')),
    );
  }

  Future<void> _addGroup() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _GroupNameDialog(
        title: 'New Workflow Group',
        hint: 'e.g., "Python Specialists" or "Logic/Analysis"',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final group = await AgentRoleSettingsRepository.instance.addGroup(
      title: name.trim(),
      seedFromGroupId: _activeGroupId,
    );
    await _load();
    await AgentRoleSettingsRepository.instance.setActiveGroupId(group.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Created group "${group.title}"')),
    );
  }

  Future<void> _renameGroup() async {
    final group = _groups.firstWhere((g) => g.id == _activeGroupId);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _GroupNameDialog(
        title: 'Rename Group',
        hint: 'New name for "${group.title}"',
        initialValue: group.title,
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await AgentRoleSettingsRepository.instance
        .renameGroup(_activeGroupId, name.trim());
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Renamed group to "$name"')),
    );
  }

  Future<void> _deleteGroup() async {
    if (_groups.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the last remaining group')),
      );
      return;
    }
    final group = _groups.firstWhere((g) => g.id == _activeGroupId);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text('Delete "${group.title}" and all its configurations?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final removed =
        await AgentRoleSettingsRepository.instance.removeGroup(_activeGroupId);
    if (!removed) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Deleted group "${group.title}"')),
    );
  }

  Future<void> _duplicateGroup() async {
    final group = _groups.firstWhere((g) => g.id == _activeGroupId);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _GroupNameDialog(
        title: 'Duplicate Group',
        hint: 'Name for the copy of "${group.title}"',
        initialValue: '${group.title} (Copy)',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    final newGroup = await AgentRoleSettingsRepository.instance.addGroup(
      title: name.trim(),
      seedFromGroupId: _activeGroupId,
    );
    await _load();
    await AgentRoleSettingsRepository.instance.setActiveGroupId(newGroup.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Duplicated group as "$name"')),
    );
  }

  void _onActiveGroupChanged() {
    _load();
  }

  // ─── Live model list fetching ────────────────────────────────────────────
  String _cacheKey(String backend, String role) {
    final cfg = _agents.get(role);
    final extra = backend == 'ollama' ? '|${cfg.ollamaBaseUrl ?? ''}' : '';
    return '$backend$extra';
  }

  List<String> _modelsFor(String role) {
    final cfg = _agents.get(role);
    final cached = _modelsCache[_cacheKey(cfg.backend, role)];
    if (cached != null && cached.isNotEmpty) return cached;
    return AgentRoleModelSuggestions.forBackend(cfg.backend);
  }

  Future<void> _refreshModels(String role) async {
    final cfg = _agents.get(role);
    final backend = cfg.backend;
    final key = _cacheKey(backend, role);
    setState(() => _modelsLoading[role] = true);
    try {
      final list = await _fetchLiveModels(backend, role);
      if (!mounted) return;
      setState(() {
        if (list.isNotEmpty) _modelsCache[key] = list;
        _modelsLoading[role] = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(list.isEmpty
                ? 'No models returned for $backend (using suggestions).'
                : 'Loaded ${list.length} $backend models.'),
            duration: const Duration(milliseconds: 1400),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelsLoading[role] = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Refresh failed: $e')),
      );
    }
  }

  Future<List<String>> _fetchLiveModels(String backend, String role) async {
    final settings = BackendSettingsRepository.instance;
    switch (backend) {
      case 'openai':
        return AgentRoleModelSuggestions.forBackend('openai');
      case 'anthropic':
        return AgentRoleModelSuggestions.forBackend('anthropic');
      case 'openrouter':
        final key = await settings.getOpenRouterApiKey() ?? '';
        if (key.isEmpty) throw 'OpenRouter API key not set.';
        return OpenRouterService.instance.listModels(key);
      case 'ollama':
        final cfg = _agents.get(role);
        final url = (cfg.ollamaBaseUrl?.isNotEmpty ?? false)
            ? cfg.ollamaBaseUrl!
            : 'http://localhost:11434';
        final apiKey = await settings.getOllamaApiKey() ?? '';
        return OllamaService.instance
            .listInstalledModels(baseUrl: url, apiKey: apiKey);
      case 'gemini':
        // Pull from the same persisted list the Gemini Settings panel
        // edits, so user-added models (e.g. gemma4) show up here too.
        // Falls back to the bundled defaults if the user never customised it.
        final saved = await settings.getGeminiModels();
        return saved.isEmpty
            ? BackendSettingsRepository.defaultGeminiModels
            : saved;
      default:
        return const [];
    }
  }

  // ─── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
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
              const SizedBox(height: 12),
              _teamModeSwitch(),
              const SizedBox(height: 16),
              _groupManagementControls(),
              const SizedBox(height: 24),
              for (final role in AgentRoleSettingsRepository.roles) ...[
                _roleCard(role),
                const SizedBox(height: 12),
              ],
              if (_teamMode) ...[
                _roleCard(AgentRoleSettingsRepository.leaderRole),
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

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Workflow Agents',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Pick which model handles each role in the agent workflow. '
          'The Reasoner is the strong model that plans and decides; the '
          'Summarizer is a cheaper model that compacts context when needed. '
          'API keys come from the Model Settings tab. Click ↻ to '
          'fetch the live model list from each provider.',
          style: TextStyle(fontSize: 12.5, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 12),
        _infoBanner(),
      ],
    );
  }

  Widget _infoBanner() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(10),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: AppTheme.accent),
              SizedBox(width: 6),
              Text(
                'Max Tokens vs Context Window',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: 6),
          Text(
            '• Max tokens — hard cap on the reply length only. Applies to every '
            'backend (Groq, OpenRouter, Gemini, GitHub Models, Ollama). On '
            'cloud APIs you are billed per token actually emitted, so raising '
            'this does not pre-charge you — it just lets longer answers '
            'through.\n'
            '• Context window (num_ctx) — total budget for the WHOLE call: '
            'system prompt + tool defs + chat history + your message + the '
            'reply, combined. Cloud providers manage this internally (Claude '
            '200K, Gemini 1M, etc.) and ignore the field — it only takes '
            'effect on Ollama backends, where the local Modelfile may default '
            'as low as 4K.\n'
            '• Relation — Max tokens must fit inside what is left of num_ctx '
            'after the prompt, history and tool defs. If Max tokens is set '
            'close to num_ctx the model has no room to read your prompt and '
            'will fail or truncate. Rule of thumb: keep num_ctx ≥ 4× Max '
            'tokens for long-context work.',
            style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
          ),
        ],
      ),
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
              if (!mounted) return;
              setState(() => _enabled = v);
            },
          ),
        ],
      ),
    );
  }

  Widget _teamModeSwitch() {
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
                  'Enable Team Mode',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'Splits heavy tasks across specialized workers. A team-leader '
                  'model assigns work; each worker has its own context window '
                  'and won\'t hit token limits on long jobs. Requires '
                  'multi-agent mode (above) to be on.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Switch(
                value: _teamMode,
                onChanged: (v) async {
                  await AgentRoleSettingsRepository.instance
                      .setTeamModeEnabled(v);
                  // Team Mode requires multi-agent — flip it on automatically
                  // so the user doesn't get a silent no-op when only Team
                  // Mode is set.
                  if (v && !_enabled) {
                    await AgentRoleSettingsRepository.instance.setEnabled(true);
                  }
                  if (!mounted) return;
                  setState(() {
                    _teamMode = v;
                    if (v) _enabled = true;
                  });
                },
              ),
              if (_teamMode) ...[
                const SizedBox(height: 4),
                TextButton.icon(
                  icon: const Icon(Icons.dashboard_outlined, size: 14),
                  label: const Text('View Team Board',
                      style: TextStyle(fontSize: 12)),
                  onPressed: () {
                    final basePath = Directory.current.path;
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TeamBoardViewer(basePath: basePath),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _groupManagementControls() {
    final activeGroup = _groups.firstWhere((g) => g.id == _activeGroupId);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.layers_outlined,
                  size: 18, color: AppTheme.accent),
              const SizedBox(width: 8),
              const Text(
                'Workflow Group',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Active: ${activeGroup.title}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _groupDropdown(),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Create new group',
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: _addGroup,
              ),
              IconButton(
                tooltip: 'Rename current group',
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: _renameGroup,
              ),
              IconButton(
                tooltip: 'Duplicate current group',
                icon: const Icon(Icons.copy_outlined, size: 20),
                onPressed: _duplicateGroup,
              ),
              IconButton(
                tooltip: 'Delete current group',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: _deleteGroup,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _groupDropdown() {
    return DropdownButtonFormField<WorkflowGroup>(
      initialValue: _groups.firstWhere((g) => g.id == _activeGroupId),
      decoration: const InputDecoration(
        labelText: 'Switch group',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final group in _groups)
          DropdownMenuItem(
            value: group,
            child: Text(group.title),
          ),
      ],
      onChanged: (group) async {
        if (group == null) return;
        await AgentRoleSettingsRepository.instance.setActiveGroupId(group.id);
        await _load();
      },
    );
  }

  Widget _roleCard(String role) {
    final cfg = _agents.get(role);
    final state = _saveState[role] ?? _SaveState.idle;
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
              Expanded(
                child: Text(
                  _hintForRole(role),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppTheme.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _saveIndicator(state),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(flex: 2, child: _backendDropdown(role, cfg)),
              const SizedBox(width: 10),
              Expanded(flex: 3, child: _modelDropdown(role, cfg)),
            ],
          ),
          if (cfg.backend == 'ollama') ...[
            const SizedBox(height: 10),
            _ollamaUrlField(role),
            const SizedBox(height: 10),
            _ollamaCtxField(role),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _temperatureSlider(role, cfg)),
              const SizedBox(width: 10),
              Expanded(child: _maxTokensField(role)),
              const SizedBox(width: 10),
              Expanded(child: _tpmField(role)),
              const SizedBox(width: 10),
              Expanded(child: _reasoningLevelDropdown(role)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _saveIndicator(_SaveState state) {
    switch (state) {
      case _SaveState.dirty:
        return const Tooltip(
          message: 'Pending save…',
          child: Icon(Icons.edit_note, size: 18, color: AppTheme.textMuted),
        );
      case _SaveState.saving:
        return const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        );
      case _SaveState.saved:
        return const Tooltip(
          message: 'Saved',
          child:
              Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
        );
      case _SaveState.error:
        return const Icon(Icons.error_outline,
            size: 18, color: AppTheme.danger);
      case _SaveState.idle:
        return const SizedBox.shrink();
    }
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
        var updated = cfg.copyWith(backend: v);
        // If the new backend doesn't list the current model, drop to the
        // first suggestion so we never persist an obviously-incompatible
        // pairing.
        final suggestions = AgentRoleModelSuggestions.forBackend(v);
        if (suggestions.isNotEmpty && !suggestions.contains(updated.model)) {
          updated = updated.copyWith(model: suggestions.first);
          _modelCtrls[role]!.text = suggestions.first;
        }
        setState(() => _agents.put(role, updated));
        await _persistImmediately(role);
      },
    );
  }

  Widget _modelDropdown(String role, AgentRoleConfig cfg) {
    final models = _modelsFor(role);
    final loading = _modelsLoading[role] ?? false;

    // Make sure the current model appears in the list — otherwise the
    // dropdown would render with a blank value.
    final all = <String>{...models};
    if (cfg.model.isNotEmpty) all.add(cfg.model);
    final items = all.toList()..sort();

    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: cfg.model.isEmpty ? null : cfg.model,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final m in items)
                DropdownMenuItem(
                    value: m, child: Text(m, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _agents.put(role, cfg.copyWith(model: v)));
              _modelCtrls[role]!.text = v;
              await _persistImmediately(role);
            },
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Refresh model list from ${cfg.backend}',
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : const Icon(Icons.refresh, size: 18),
          onPressed: loading ? null : () => _refreshModels(role),
        ),
      ],
    );
  }

  Widget _ollamaUrlField(String role) {
    return Focus(
      onFocusChange: (has) {
        if (!has) _persistImmediately(role);
      },
      child: TextField(
        controller: _ollamaUrlCtrls[role],
        decoration: const InputDecoration(
          labelText:
              'Ollama base URL (e.g. http://localhost:11434 or https://ollama.com)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (v) {
          final cfg = _agents.get(role);
          setState(() => _agents.put(role,
              cfg.copyWith(ollamaBaseUrl: v.trim().isEmpty ? null : v.trim())));
          _scheduleSave(role);
        },
      ),
    );
  }

  Widget _ollamaCtxField(String role) {
    return Focus(
      onFocusChange: (has) {
        if (!has) _persistImmediately(role);
      },
      child: TokenCountPicker(
        controller: _ollamaCtxCtrls[role]!,
        presets: TokenCountPicker.numCtxPresets,
        outlined: true,
        isDense: true,
        labelText: 'Context window (num_ctx)',
        hintText: 'e.g. 32768',
        helperText:
            'Total budget — prompt + history + reply. Must comfortably exceed Max tokens. Default 4096; raise for long documents.',
        onChanged: (v) {
          final parsed = int.tryParse(v.trim());
          final cfg = _agents.get(role);
          setState(() => _agents.put(role, cfg.copyWith(ollamaNumCtx: parsed)));
          _scheduleSave(role);
        },
      ),
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
            setState(() => _agents.put(role, cfg.copyWith(temperature: v)));
          },
          onChangeEnd: (_) => _persistImmediately(role),
        ),
      ],
    );
  }

  Widget _maxTokensField(String role) {
    return Focus(
      onFocusChange: (has) {
        if (!has) _persistImmediately(role);
      },
      child: TokenCountPicker(
        controller: _maxTokensCtrls[role]!,
        presets: TokenCountPicker.maxTokensPresets,
        outlined: true,
        isDense: true,
        labelText: 'Max tokens (reply cap)',
        helperText:
            'Caps the reply only. Cloud APIs bill per emitted token, so raising this just allows longer answers.',
        onChanged: (v) {
          final parsed = int.tryParse(v.trim());
          if (parsed == null) return;
          final cfg = _agents.get(role);
          setState(() => _agents.put(role, cfg.copyWith(maxTokens: parsed)));
          _scheduleSave(role);
        },
      ),
    );
  }

  Widget _tpmField(String role) {
    return Focus(
      onFocusChange: (has) {
        if (!has) _persistImmediately(role);
      },
      child: TextField(
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
          final cfg = _agents.get(role);
          setState(() => _agents.put(role, cfg.copyWith(tpmLimit: parsed)));
          _scheduleSave(role);
        },
      ),
    );
  }

  Widget _reasoningLevelDropdown(String role) {
    final cfg = _agents.get(role);
    final current = _reasoningLevels[role] ?? cfg.reasoningLevel;
    const levels = ['minimal', 'low', 'medium', 'high', 'max'];
    const labels = {
      'minimal': 'Minimal',
      'low': 'Low',
      'medium': 'Medium',
      'high': 'High',
      'max': 'Max',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Reasoning',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          initialValue: current,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
          items: [
            for (final l in levels)
              DropdownMenuItem(
                value: l,
                child: Text(labels[l] ?? l, style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _reasoningLevels[role] = v;
              _agents.put(role, cfg.copyWith(reasoningLevel: v));
            });
            _persistImmediately(role);
          },
        ),
      ],
    );
  }

  String _titleForRole(String role) {
    switch (role) {
      case 'reasoner':
        return 'Reasoner';
      case 'summarizer':
        return 'Summarizer';
      case AgentRoleSettingsRepository.leaderRole:
        return 'Team Leader';
    }
    return role;
  }

  String _hintForRole(String role) {
    switch (role) {
      case 'reasoner':
        return '— strong model, plans + decides';
      case 'summarizer':
        return '— cheap model, compacts context';
      case AgentRoleSettingsRepository.leaderRole:
        return '— decomposes heavy tasks into worker groups';
    }
    return '';
  }

  IconData _iconForRole(String role) {
    switch (role) {
      case 'reasoner':
        return Icons.psychology_outlined;
      case 'summarizer':
        return Icons.summarize_outlined;
      case AgentRoleSettingsRepository.leaderRole:
        return Icons.groups_2_outlined;
    }
    return Icons.smart_toy_outlined;
  }
}

enum _SaveState { idle, dirty, saving, saved, error }

/// Dialog for entering a workflow group name.
class _GroupNameDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String? initialValue;

  const _GroupNameDialog({
    required this.title,
    required this.hint,
    this.initialValue,
  });

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        decoration: InputDecoration(
          hintText: widget.hint,
          border: const OutlineInputBorder(),
        ),
        autofocus: true,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('OK'),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }
}

// Silence unused-import lint when SettingsRepository helpers aren't needed
// directly by this file but are used via repositories.
// ignore: unused_element
SettingsRepository _unusedSettingsKeep() => SettingsRepository.instance;
