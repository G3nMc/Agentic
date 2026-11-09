import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';
import 'backend_settings_repository.dart';

/// One row of the per-role agent configuration. Maps onto a single object
/// inside the `agents.json` file the Python side reads at startup.
class AgentRoleConfig {
  /// Identifier used in `agents.json` (must match `bin/agent/core/agent_config.py`).
  final String role;

  /// Backend identifier â€” same string the orchestrator's `--backend` flag uses.
  /// One of: `gemini`, `groq`, `openrouter`, `github`, `huggingface`, `ollama`.
  final String backend;

  final String model;

  /// Tokens-per-minute cap on this role's backend. 0 = unlimited (default).
  /// Roles that pick the same backend+model+tpm share one rate-limited
  /// instance on the Python side, so the cap is "per provider" not "per call".
  final int tpmLimit;

  final double temperature;

  final int maxTokens;

  /// Reasoning effort level: minimal, low, medium, high, max.
  /// Maps to OpenAI `reasoning_effort`, Anthropic `thinking.budget_tokens`,
  /// Gemini `thinkingConfig.thinkingBudget`. Default: max.
  final String reasoningLevel;

  /// Whether extended thinking (reasoning) is on for this role.
  /// Owned by the Workflow Agents cards while MaM is enabled; the chat-view
  /// thinking toggle owns it in single-model mode.
  final bool thinking;

  /// Total context window in tokens: system prompt + tool definitions +
  /// history + message + reply, combined. Applied to Ollama (`num_ctx`) and
  /// OpenRouter (`context_limit`); the remaining providers manage it
  /// themselves. Null lets the backend use its own default.
  ///
  /// Persisted twice for compatibility: as `context_window` and as the legacy
  /// Ollama-flavoured `ollama_num_ctx` key that older readers understand.
  final int? contextWindow;

  /// Per-role base URL override. Honoured by the providers listed in
  /// [AgentRoleSettingsRepository.baseUrlBackends] (Ollama, OpenRouter,
  /// Gemini); ignored elsewhere.
  final String? ollamaBaseUrl;

  const AgentRoleConfig({
    required this.role,
    required this.backend,
    required this.model,
    this.tpmLimit = 0,
    this.temperature = 0.2,
    this.maxTokens = 1024,
    this.reasoningLevel = 'max',
    this.thinking = true,
    this.contextWindow,
    this.ollamaBaseUrl,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'backend': backend,
        'model': model,
        'tpm_limit': tpmLimit,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'reasoning_level': reasoningLevel,
        'thinking': thinking,
        if (contextWindow != null) 'context_window': contextWindow,
        // Legacy mirror: `ollama_num_ctx` is the only context key older
        // `agents.json` consumers know about.
        if (contextWindow != null) 'ollama_num_ctx': contextWindow,
        if (ollamaBaseUrl != null && ollamaBaseUrl!.isNotEmpty) 'ollama_base_url': ollamaBaseUrl,
      };

  factory AgentRoleConfig.fromJson(Map<String, Object?> json, {required String role}) => AgentRoleConfig(
        role: role,
        backend: json['backend'] as String? ?? 'gemini',
        model: json['model'] as String? ?? 'gemini-2.5-flash',
        tpmLimit: (json['tpm_limit'] as num?)?.toInt() ?? 0,
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.2,
        maxTokens: (json['max_tokens'] as num?)?.toInt() ?? 1024,
        reasoningLevel: json['reasoning_level'] as String? ?? 'max',
        thinking: parseBool(json['thinking']) ?? true,
        contextWindow: (json['context_window'] as num?)?.toInt() ??
            (json['ollama_num_ctx'] as num?)?.toInt(),
        ollamaBaseUrl: json['ollama_base_url'] as String?,
      );

  /// Tolerant boolean reader used by both [fromJson] and the SQLite layer,
  /// which stores flags as `'1'` / `'0'`. Returns null when the value is
  /// absent or unrecognised so callers can fall back to a default.
  static bool? parseBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v == '1' || v == 'true' || v == 'yes' || v == 'on') return true;
      if (v == '0' || v == 'false' || v == 'no' || v == 'off') return false;
    }
    return null;
  }

  AgentRoleConfig copyWith({
    String? backend,
    String? model,
    int? tpmLimit,
    double? temperature,
    int? maxTokens,
    String? reasoningLevel,
    bool? thinking,
    int? contextWindow,
    String? ollamaBaseUrl,
  }) {
    return AgentRoleConfig(
      role: role,
      backend: backend ?? this.backend,
      model: model ?? this.model,
      tpmLimit: tpmLimit ?? this.tpmLimit,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      reasoningLevel: reasoningLevel ?? this.reasoningLevel,
      thinking: thinking ?? this.thinking,
      contextWindow: contextWindow ?? this.contextWindow,
      ollamaBaseUrl: ollamaBaseUrl ?? this.ollamaBaseUrl,
    );
  }
}

/// Lightweight descriptor of a workflow group â€” id + user-given title.
/// The actual per-role configs live under `agent.<groupId>.<role>.<field>`
/// keys in the `backend_settings` table.
class WorkflowGroupInfo {
  const WorkflowGroupInfo({required this.id, required this.title});

  final String id;
  final String title;

  Map<String, Object?> toJson() => {'id': id, 'title': title};

  factory WorkflowGroupInfo.fromJson(Map<String, Object?> json) => WorkflowGroupInfo(
        id: json['id'] as String,
        title: json['title'] as String,
      );
}

/// A named bundle of all four role configs (router/shaper/reasoner/executor).
/// This represents a specialized workflow group for specific tasks.
class WorkflowGroup {
  const WorkflowGroup({
    required this.id,
    required this.title,
    required this.roles,
  });

  final String id;
  final String title;
  final Map<String, AgentRoleConfig> roles;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'roles': {for (final entry in roles.entries) entry.key: entry.value.toJson()},
      };

  factory WorkflowGroup.fromJson(Map<String, Object?> json) => WorkflowGroup(
        id: json['id'] as String,
        title: json['title'] as String,
        roles: (json['roles'] as Map<String, Object?>).map((key, value) => MapEntry(key, AgentRoleConfig.fromJson(value as Map<String, Object?>, role: key))),
      );

  WorkflowGroup copyWith({
    String? id,
    String? title,
    Map<String, AgentRoleConfig>? roles,
  }) =>
      WorkflowGroup(
        id: id ?? this.id,
        title: title ?? this.title,
        roles: roles ?? this.roles,
      );
}

/// Persists per-role agent assignments alongside the existing backend
/// settings. Keys live in the same `backend_settings` table as the
/// single-agent settings â€” no new schema needed. Values are stored as plain
/// strings so the existing read/write helpers translate cleanly.
///
/// Naming convention: `agent.<groupId>.<role>.<field>`. The group registry
/// is at `agent.workflow.groups` (JSON array) and the active group id at
/// `agent.workflow.activeGroup`. Pre-groups installs are migrated on first
/// access into a single "Default" group.
class AgentRoleSettingsRepository {
  AgentRoleSettingsRepository._();

  static final AgentRoleSettingsRepository instance = AgentRoleSettingsRepository._();

  /// Reactive view of the master switch. Widgets that need to repaint when
  /// the user flips multi-agent mode on/off can wrap a `ValueListenableBuilder`
  /// around this â€” the repo updates it from `setEnabled` and from the first
  /// `isEnabled()` call that loads from disk.
  final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(false);

  /// Reactive view of [getMaxAutoRounds]. Seeded with the default so a widget
  /// that reads it before the first disk load still shows a sane value.
  final ValueNotifier<int> maxAutoRoundsNotifier =
      ValueNotifier<int>(defaultMaxAutoRounds);

  /// Reactive view of the Team Mode toggle. When true, the orchestrator
  /// adds `--team-mode` to its CLI argv on launch.
  final ValueNotifier<bool> teamModeNotifier = ValueNotifier<bool>(false);

  /// Notifies when the active group changes â€” UI rebuilds bind to this.
  final ValueNotifier<String?> activeGroupNotifier = ValueNotifier<String?>(null);

  /// Notifies when any group is mutated (rename / add / remove / reset).
  /// The sidebar dropdown and WorkflowBreadcrumb listen to this so they
  /// reflect renamed groups immediately when the user navigates back.
  final ValueNotifier<int> groupsChangedNotifier = ValueNotifier<int>(0);

  /// Roles, in the order they should appear in the Settings UI.
  /// The first card is the Assistant (reasoner config); the second card is
  /// the user for AUTO INPUT (forwarded to the orchestrator via --user-* flags).
  static const List<String> roles = ['reasoner', 'user'];

  /// Special role used only when Team Mode is on. Stored under the same
  /// `agent.<groupId>.leader.<field>` keys as the regular roles, but kept
  /// out of the main [roles] list so the standard Workflow Agents UI
  /// continues to show only the four core roles.
  static const String leaderRole = 'leader';

  /// Master switch. When false, the orchestrator launches in single-agent
  /// mode (the existing run-loop) regardless of the per-role assignments.
  static const String _kEnabled = 'agent.workflow.enabled';

  /// Maximum AUTO INPUT rounds the run loop performs before it stops and
  /// returns the last answer. Workflow-level, exactly like [_kEnabled]: the
  /// cap bounds the Assistant <-> User *exchange*, not a single role, so it
  /// is one global value instead of a per-group copy. Forwarded to the
  /// orchestrator as `--max-agent-rounds`.
  static const String _kMaxAutoRounds = 'agent.workflow.maxAutoRounds';

  /// Default / bounds for [getMaxAutoRounds]. The upper bound is deliberate:
  /// every round is a full request pass against two models, so an unbounded
  /// value is a cost and latency foot-gun.
  static const int defaultMaxAutoRounds = 20;
  static const int minMaxAutoRounds = 1;
  static const int maxMaxAutoRounds = 200;

  /// Clamps [value] into the supported range. Single source of truth shared by
  /// the Settings panel, the repository accessors and the unit tests, so the
  /// number the UI shows can never disagree with the number Python receives.
  static int clampMaxAutoRounds(int value) {
    if (value < minMaxAutoRounds) return minMaxAutoRounds;
    if (value > maxMaxAutoRounds) return maxMaxAutoRounds;
    return value;
  }

  /// Team Mode toggle. Independent from [_kEnabled]: Team Mode requires
  /// multi-agent under the hood (each worker subprocess runs the
  /// pipeline), but the host enables both flags when Team Mode is on.
  static const String _kTeamMode = 'agent.workflow.teamMode';

  static const String _kGroups = 'agent.workflow.groups';
  static const String _kActive = 'agent.workflow.activeGroup';

  static const String _kDefaultGroupId = 'default';
  static const String _kDefaultGroupTitle = 'Default';

  // ---------------------------------------------------------------------------
  // Defaults â€” chosen so a user with only a Gemini key gets a working setup.
  // The Reasoner picks the strongest tier; the rest tier down.
  // ---------------------------------------------------------------------------
  static AgentRoleConfig defaultFor(String role) {
    switch (role) {
      case 'reasoner':
        return const AgentRoleConfig(
          role: 'reasoner',
          backend: 'gemini',
          model: 'gemini-2.5-pro',
          temperature: 0.2,
          maxTokens: 4096,
          thinking: true,
          contextWindow: 32768,
        );
      case 'user':
        // AUTO INPUT reviewer (the "User" agent): reviews the Assistant's
        // answer and authors the next user prompt while the task is open.
        //
        // The model stays EMPTY on purpose: an unconfigured User slot must be
        // distinguishable from a configured one, otherwise AUTO INPUT would
        // silently pick a model the user never selected and the "no User agent
        // configured" notice could never fire. Python's
        // `_build_user_backend_for_args` treats an empty model the same way
        // (returns None -> run loop fails safe and waits for real input).
        return const AgentRoleConfig(
          role: 'user',
          backend: 'gemini',
          model: '',
          temperature: 0.2,
          maxTokens: 1024,
          thinking: false,
          contextWindow: 32768,
        );
      case leaderRole:
        // The team leader is light coordination â€” a fast model is fine.
        // Users wanting smarter decomposition can pick a stronger one.
        return const AgentRoleConfig(
          role: leaderRole,
          backend: 'gemini',
          model: 'gemini-2.5-flash',
          temperature: 0.2,
          maxTokens: 1024,
        );
      default:
        throw ArgumentError('Unknown agent role: $role');
    }
  }

  // ---------------------------------------------------------------------------
  // Master switch
  // ---------------------------------------------------------------------------
  Future<bool> isEnabled() async {
    final v = await _read(_kEnabled);
    final enabled = v == '1' || v == 'true';
    if (enabledNotifier.value != enabled) enabledNotifier.value = enabled;
    return enabled;
  }

  Future<void> setEnabled(bool enabled) async {
    await _write(_kEnabled, enabled ? '1' : '0');
    enabledNotifier.value = enabled;
  }

  // ---------------------------------------------------------------------------
  // Maximum Auto Round Actions (workflow-level, like the master switch)
  // ---------------------------------------------------------------------------
  Future<int> getMaxAutoRounds() async {
    final raw = await _read(_kMaxAutoRounds);
    final parsed = int.tryParse((raw ?? '').trim());
    if (parsed == null) {
      // Absent or corrupt row: fall back to the default and back-fill it, so an
      // existing install stops re-reading a missing key on every access.
      await _write(_kMaxAutoRounds, defaultMaxAutoRounds.toString());
      if (maxAutoRoundsNotifier.value != defaultMaxAutoRounds) {
        maxAutoRoundsNotifier.value = defaultMaxAutoRounds;
      }
      return defaultMaxAutoRounds;
    }
    final value = clampMaxAutoRounds(parsed);
    if (maxAutoRoundsNotifier.value != value) {
      maxAutoRoundsNotifier.value = value;
    }
    return value;
  }

  Future<void> setMaxAutoRounds(int rounds) async {
    final value = clampMaxAutoRounds(rounds);
    await _write(_kMaxAutoRounds, value.toString());
    maxAutoRoundsNotifier.value = value;
  }

  // ---------------------------------------------------------------------------
  // Team Mode toggle
  // ---------------------------------------------------------------------------
  Future<bool> isTeamModeEnabled() async {
    final v = await _read(_kTeamMode);
    final on = v == '1' || v == 'true';
    if (teamModeNotifier.value != on) teamModeNotifier.value = on;
    return on;
  }

  Future<void> setTeamModeEnabled(bool enabled) async {
    await _write(_kTeamMode, enabled ? '1' : '0');
    teamModeNotifier.value = enabled;
  }

  // ---------------------------------------------------------------------------
  // Leader role getter/setter (group-scoped, like the four core roles)
  // ---------------------------------------------------------------------------
  Future<AgentRoleConfig> getLeader(String groupId) =>
      getRole(groupId, leaderRole);

  Future<void> setLeader(String groupId, AgentRoleConfig cfg) =>
      setRole(groupId, cfg, role: leaderRole);

  // ---------------------------------------------------------------------------
  // Group registry
  // ---------------------------------------------------------------------------

  /// Reads the saved group list. Performs one-time migration for pre-groups
  /// installs: if no registry exists, seeds a single "Default" group whose
  /// per-role values come from the legacy `agent.<role>.<field>` keys (or the
  /// hardcoded defaults if those are also absent).
  Future<List<WorkflowGroup>> listGroups() async {
    final raw = await _read(_kGroups);
    if (raw == null || raw.isEmpty) {
      await _migrateLegacyToDefaultGroup();
      final rolesMap = <String, AgentRoleConfig>{};
      for (final r in roles) {
        rolesMap[r] = defaultFor(r);
      }
      return [
        WorkflowGroup(id: _kDefaultGroupId, title: _kDefaultGroupTitle, roles: rolesMap),
      ];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final groups = <WorkflowGroup>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final groupInfo = WorkflowGroupInfo.fromJson(item.cast<String, Object?>());
      final rolesMap = <String, AgentRoleConfig>{};
      for (final r in roles) {
        rolesMap[r] = await getRole(groupInfo.id, r);
      }
      groups.add(WorkflowGroup(id: groupInfo.id, title: groupInfo.title, roles: rolesMap));
    }
    return groups;
  }

  Future<void> _saveGroupList(List<WorkflowGroupInfo> groups) async {
    final body = jsonEncode([for (final g in groups) g.toJson()]);
    await _write(_kGroups, body);
  }

  Future<void> _saveGroupListFromWorkflowGroups(List<WorkflowGroup> groups) async {
    final body = jsonEncode([for (final g in groups) WorkflowGroupInfo(id: g.id, title: g.title).toJson()]);
    await _write(_kGroups, body);
  }

  /// Currently-selected group id (the one the orchestrator will use).
  Future<String> getActiveGroupId() async {
    final groups = await listGroups();
    final active = await _read(_kActive);
    if (active != null && groups.any((g) => g.id == active)) {
      activeGroupNotifier.value = active;
      return active;
    }
    final fallback = groups.isNotEmpty ? groups.first.id : _kDefaultGroupId;
    await _write(_kActive, fallback);
    activeGroupNotifier.value = fallback;
    return fallback;
  }

  Future<void> setActiveGroupId(String id) async {
    await _write(_kActive, id);
    activeGroupNotifier.value = id;
  }

  /// Adds a new group with the given title. If [seedFromGroupId] is provided,
  /// copies that group's per-role configs into the new group; otherwise seeds
  /// from the hardcoded defaults.
  Future<WorkflowGroup> addGroup({
    required String title,
    String? seedFromGroupId,
  }) async {
    final groups = await listGroups();
    final id = _newGroupId(groups.map((g) => g.id).toSet());
    final info = WorkflowGroupInfo(id: id, title: title.trim());
    final next = <WorkflowGroupInfo>[...groups.map((g) => WorkflowGroupInfo(id: g.id, title: g.title)), info];
    await _saveGroupList(next);

    // Seed per-role configs.
    final rolesMap = <String, AgentRoleConfig>{};
    for (final r in roles) {
      final cfg = seedFromGroupId == null ? defaultFor(r) : await getRole(seedFromGroupId, r);
      await setRole(id, cfg, role: r);
      rolesMap[r] = cfg;
    }
    return WorkflowGroup(id: id, title: title.trim(), roles: rolesMap);
  }

  Future<void> renameGroup(String id, String newTitle) async {
    final groups = await listGroups();
    final idx = groups.indexWhere((g) => g.id == id);
    if (idx < 0) return;
    final next = [...groups];
    next[idx] = groups[idx].copyWith(title: newTitle.trim());
    await _saveGroupListFromWorkflowGroups(next);
    groupsChangedNotifier.value++;
  }

  /// Removes a group and all its per-role keys. Refuses to remove the last
  /// remaining group. If the active group is removed, falls back to the first
  /// remaining one.
  Future<bool> removeGroup(String id) async {
    final groups = await listGroups();
    if (groups.length <= 1) return false;
    final next = groups.where((g) => g.id != id).toList();
    await _saveGroupList([for (final g in next) WorkflowGroupInfo(id: g.id, title: g.title)]);
    for (final r in roles) {
      await _deletePrefix('agent.$id.$r.');
    }
    final active = await _read(_kActive);
    if (active == id) {
      await setActiveGroupId(next.first.id);
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // Per-role getters/setters (group-scoped)
  // ---------------------------------------------------------------------------

  Future<AgentRoleConfig> getRole(String groupId, String role) async {
    final def = defaultFor(role);
    final p = 'agent.$groupId.$role';
    final backend = (await _read('$p.backend')) ?? def.backend;
    final model = (await _read('$p.model')) ?? def.model;
    final tpm = int.tryParse((await _read('$p.tpm_limit')) ?? '') ?? def.tpmLimit;
    final temp = double.tryParse((await _read('$p.temperature')) ?? '') ?? def.temperature;
    final mx = int.tryParse((await _read('$p.max_tokens')) ?? '') ?? def.maxTokens;
    final reasoningRaw = await _read('$p.reasoning_level');
    final thinkingRaw = await _read('$p.thinking');
    final contextRaw = await _read('$p.context_window');
    final legacyContextRaw = await _read('$p.ollama_num_ctx');
    final ollamaUrl = await _read('$p.ollama_base_url');

    final reasoningLevel =
        (reasoningRaw == null || reasoningRaw.isEmpty) ? def.reasoningLevel : reasoningRaw;
    final thinking = AgentRoleConfig.parseBool(thinkingRaw) ?? def.thinking;
    final contextWindow = int.tryParse(contextRaw ?? '') ??
        int.tryParse(legacyContextRaw ?? '') ??
        def.contextWindow;

    // One-shot, idempotent back-fill: persist the canonical keys when they were
    // missing, so an existing install stops silently resetting the value on
    // every load and the legacy `ollama_num_ctx` key migrates to the generic
    // `context_window`.
    if (reasoningRaw == null || reasoningRaw.isEmpty) {
      await _write('$p.reasoning_level', reasoningLevel);
    }
    if (thinkingRaw == null) {
      await _write('$p.thinking', thinking ? '1' : '0');
    }
    if (contextRaw == null && contextWindow != null) {
      await _write('$p.context_window', contextWindow.toString());
    }

    return AgentRoleConfig(
      role: role,
      backend: backend,
      model: model,
      tpmLimit: tpm,
      temperature: temp,
      maxTokens: mx,
      reasoningLevel: reasoningLevel,
      thinking: thinking,
      contextWindow: contextWindow,
      ollamaBaseUrl: (ollamaUrl == null || ollamaUrl.isEmpty) ? null : ollamaUrl,
    );
  }

  Future<void> setRole(String groupId, AgentRoleConfig cfg, {String? role}) async {
    final r = role ?? cfg.role;
    final p = 'agent.$groupId.$r';
    await _write('$p.backend', cfg.backend);
    await _write('$p.model', cfg.model);
    await _write('$p.tpm_limit', cfg.tpmLimit.toString());
    await _write('$p.temperature', cfg.temperature.toString());
    await _write('$p.max_tokens', cfg.maxTokens.toString());
    await _write('$p.reasoning_level', cfg.reasoningLevel);
    await _write('$p.thinking', cfg.thinking ? '1' : '0');
    if (cfg.contextWindow != null) {
      await _write('$p.context_window', cfg.contextWindow!.toString());
      // Legacy mirror so older `agents.json` readers keep seeing a value.
      await _write('$p.ollama_num_ctx', cfg.contextWindow!.toString());
    } else {
      await _deleteKey('$p.context_window');
      await _deleteKey('$p.ollama_num_ctx');
    }
    if (cfg.ollamaBaseUrl != null && cfg.ollamaBaseUrl!.isNotEmpty) {
      await _write('$p.ollama_base_url', cfg.ollamaBaseUrl!);
    } else {
      await _deleteKey('$p.ollama_base_url');
    }
    // Notify any UI that mirrors role configs (e.g. WorkflowBreadcrumb) so it
    // reloads â€” without this the breadcrumb keeps showing the model that was
    // assigned at app start until restart.
    groupsChangedNotifier.value++;
  }

  Future<Map<String, AgentRoleConfig>> getAllForGroup(String groupId) async {
    final out = <String, AgentRoleConfig>{};
    for (final r in roles) {
      out[r] = await getRole(groupId, r);
    }
    return out;
  }

  /// Convenience: read every role from the *active* group.
  Future<Map<String, AgentRoleConfig>> getAll() async {
    final id = await getActiveGroupId();
    return getAllForGroup(id);
  }

  Future<void> resetGroupToDefaults(String groupId) async {
    for (final r in roles) {
      await setRole(groupId, defaultFor(r), role: r);
    }
  }

  /// Resets the *active* group to defaults. Kept for callers/tests that don't
  /// care about groups.
  Future<void> resetToDefaults() async {
    final id = await getActiveGroupId();
    await resetGroupToDefaults(id);
  }

  // ---------------------------------------------------------------------------
  // agents.json writer â€” called by orchestrator_manager just before launch.
  // Always writes the active group's configs.
  // ---------------------------------------------------------------------------
  Future<File> writeAgentConfigJson(String path) async {
    final all = await getAll();
    final body = <String, Object?>{};
    for (final entry in all.entries) {
      body[entry.key] = entry.value.toJson();
    }
    // If Team Mode is on, emit the optional `leader` role too. Python's
    // load_role_configs ignores it when --team-mode isn't passed.
    if (await isTeamModeEnabled()) {
      final activeGroupId = await getActiveGroupId();
      final leaderCfg = await getLeader(activeGroupId);
      body[leaderRole] = leaderCfg.toJson();
    }
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(body));
    return f;
  }

  /// Backend names recognised by the Python `build_backend` factory.
  ///
  /// This list MUST stay identical to the branch table in
  /// `bin/agent/backends/__init__.py::build_backend` — the value picked here is
  /// passed straight through as `--reasoner-provider` / `--user-provider`, and
  /// an unknown name makes the orchestrator fail to build the slot backend.
  /// `tests/test_backend_registry_parity.py` asserts the two sets are equal.
  static const List<String> supportedBackends = <String>[
    'gemini',
    'groq',
    'openrouter',
    'github',
    'huggingface',
    'ollama',
  ];

  /// Providers that honour a per-role base URL override
  /// (mirrors `_BASE_URL_PROVIDERS` in `bin/orchestrator_multi.py`).
  static const Set<String> baseUrlBackends = <String>{
    'ollama',
    'openrouter',
    'gemini',
  };

  /// Providers whose context window the orchestrator can actually apply
  /// (mirrors `_CONTEXT_WINDOW_PROVIDERS` in `bin/orchestrator_multi.py`).
  /// Everywhere else the value is persisted but ignored by the provider, and
  /// the UI says so instead of silently dropping it.
  static const Set<String> contextWindowBackends = <String>{
    'ollama',
    'openrouter',
  };

  // ---------------------------------------------------------------------------
  // Migration â€” copy any legacy `agent.<role>.<field>` keys (no group segment)
  // into the Default group's namespace, then register the Default group.
  // ---------------------------------------------------------------------------
  Future<void> _migrateLegacyToDefaultGroup() async {
    for (final r in roles) {
      final legacy = 'agent.$r';
      final prefixed = 'agent.$_kDefaultGroupId.$r';
      for (final field in const [
        'backend',
        'model',
        'tpm_limit',
        'temperature',
        'max_tokens',
        'reasoning_level',
        'thinking',
        'context_window',
        'ollama_base_url',
        'ollama_num_ctx',
      ]) {
        final v = await _read('$legacy.$field');
        if (v != null) {
          await _write('$prefixed.$field', v);
        }
      }
    }
    await _saveGroupList(const [
      WorkflowGroupInfo(id: _kDefaultGroupId, title: _kDefaultGroupTitle),
    ]);
    await _write(_kActive, _kDefaultGroupId);
    activeGroupNotifier.value = _kDefaultGroupId;
  }

  String _newGroupId(Set<String> taken) {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    var id = 'g_$ts';
    var n = 0;
    while (taken.contains(id)) {
      n += 1;
      id = 'g_${ts}_$n';
    }
    return id;
  }

  // ---------------------------------------------------------------------------
  // Private helpers â€” same shape as BackendSettingsRepository's _read/_write so
  // we don't fork the persistence convention.
  // ---------------------------------------------------------------------------
  Future<String?> _read(String key) async {
    final db = await AppDatabase.instance.globalDatabase;
    final rows = await db.query(
      'backend_settings',
      where: 'id = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _write(String key, String value) async {
    final db = await AppDatabase.instance.globalDatabase;
    await db.insert(
      'backend_settings',
      {'id': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _deleteKey(String key) async {
    final db = await AppDatabase.instance.globalDatabase;
    await db.delete(
      'backend_settings',
      where: 'id = ?',
      whereArgs: [key],
    );
  }

  Future<void> _deletePrefix(String prefix) async {
    final db = await AppDatabase.instance.globalDatabase;
    await db.delete(
      'backend_settings',
      where: 'id LIKE ?',
      whereArgs: ['$prefix%'],
    );
  }
}

/// In-memory aggregate of all four role configs for a single group. Acts like
/// a tiny ORM: pull every row in one go, mutate locally, then `save()` the
/// whole thing back. The Settings UI binds to one of these instead of
/// juggling four scattered keys; the orchestrator launcher reads from the
/// same aggregate.
class WorkflowAgents {
  WorkflowAgents(this.byRole, {this.groupId = 'default'});

  final Map<String, AgentRoleConfig> byRole;
  final String groupId;

  AgentRoleConfig get(String role) => byRole[role] ?? AgentRoleSettingsRepository.defaultFor(role);

  void put(String role, AgentRoleConfig cfg) {
    byRole[role] = cfg;
  }

  /// Snapshot the current state into the JSON shape the Python side reads.
  Map<String, Object?> toJson() => <String, Object?>{
        for (final entry in byRole.entries) entry.key: entry.value.toJson(),
      };

  /// Pull every role of the *active* group from SQLite.
  static Future<WorkflowAgents> load() async {
    final id = await AgentRoleSettingsRepository.instance.getActiveGroupId();
    return loadGroup(id);
  }

  /// Pull every role of a specific group.
  static Future<WorkflowAgents> loadGroup(String groupId) async {
    final all = await AgentRoleSettingsRepository.instance.getAllForGroup(groupId);
    return WorkflowAgents(all, groupId: groupId);
  }

  /// Persist the whole aggregate back to SQLite in one shot.
  Future<void> save() async {
    final repo = AgentRoleSettingsRepository.instance;
    for (final entry in byRole.entries) {
      await repo.setRole(groupId, entry.value, role: entry.key);
    }
  }

  /// Persist a single role only â€” used by the Settings UI when one card edits.
  Future<void> saveRole(String role) async {
    final cfg = byRole[role];
    if (cfg == null) return;
    await AgentRoleSettingsRepository.instance.setRole(groupId, cfg, role: role);
  }
}

// extension _Run<T> on T {
//   R run<R>(R Function(T) f) => f(this);
// }

/// Suggested model lists per backend. Used by the Settings UI to populate the
/// per-role dropdowns without forcing the user to type the model name. The
/// list is *suggested*, not exhaustive â€” the user can always override via the
/// existing per-backend "models" lists already configured elsewhere.
class AgentRoleModelSuggestions {
  static List<String> forBackend(String backend) {
    switch (backend) {
      case 'gemini':
        return BackendSettingsRepository.defaultGeminiModels;
      case 'groq':
        return const <String>[
          'llama-3.3-70b-versatile',
          'llama-3.1-8b-instant',
          'qwen/qwen3-32b',
        ];
      case 'openrouter':
        return const <String>[
          'openai/gpt-4o',
          'anthropic/claude-3.5-sonnet',
          'google/gemini-2.5-pro',
        ];
      case 'github':
        return const <String>[
          'openai/gpt-4o',
          'openai/gpt-4o-mini',
          'meta/Llama-3.3-70B-Instruct',
        ];
      case 'huggingface':
        return const <String>[
          'Qwen/Qwen2.5-72B-Instruct',
          'meta-llama/Llama-3.3-70B-Instruct',
          'mistralai/Mistral-Small-24B-Instruct-2501',
        ];
      case 'ollama':
        return const <String>[
          'llama3.2:1b',
          'llama3.2:3b',
          'qwen2.5-coder:7b',
        ];
      default:
        return const <String>[];
    }
  }
}
