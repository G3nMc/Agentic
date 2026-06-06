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

  /// Backend identifier — same string the orchestrator's `--backend` flag uses.
  /// One of: `gemini`, `groq`, `openrouter`, `github`, `huggingface`, `ollama`.
  final String backend;

  final String model;

  /// Tokens-per-minute cap on this role's backend. 0 = unlimited (default).
  /// Roles that pick the same backend+model+tpm share one rate-limited
  /// instance on the Python side, so the cap is "per provider" not "per call".
  final int tpmLimit;

  final double temperature;

  final int maxTokens;

  /// Optional Ollama-specific overrides; ignored when [backend] != ollama.
  final String? ollamaBaseUrl;
  final int? ollamaNumCtx;

  const AgentRoleConfig({
    required this.role,
    required this.backend,
    required this.model,
    this.tpmLimit = 0,
    this.temperature = 0.2,
    this.maxTokens = 1024,
    this.ollamaBaseUrl,
    this.ollamaNumCtx,
  });

  Map<String, Object?> toJson() => <String, Object?>{
        'backend': backend,
        'model': model,
        'tpm_limit': tpmLimit,
        'temperature': temperature,
        'max_tokens': maxTokens,
        if (ollamaBaseUrl != null && ollamaBaseUrl!.isNotEmpty) 'ollama_base_url': ollamaBaseUrl,
        if (ollamaNumCtx != null) 'ollama_num_ctx': ollamaNumCtx,
      };

  factory AgentRoleConfig.fromJson(Map<String, Object?> json, {required String role}) => AgentRoleConfig(
        role: role,
        backend: json['backend'] as String? ?? 'gemini',
        model: json['model'] as String? ?? 'gemini-2.5-flash',
        tpmLimit: json['tpm_limit'] as int? ?? 0,
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.2,
        maxTokens: json['max_tokens'] as int? ?? 1024,
        ollamaBaseUrl: json['ollama_base_url'] as String?,
        ollamaNumCtx: json['ollama_num_ctx'] as int?,
      );

  AgentRoleConfig copyWith({
    String? backend,
    String? model,
    int? tpmLimit,
    double? temperature,
    int? maxTokens,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
  }) {
    return AgentRoleConfig(
      role: role,
      backend: backend ?? this.backend,
      model: model ?? this.model,
      tpmLimit: tpmLimit ?? this.tpmLimit,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      ollamaBaseUrl: ollamaBaseUrl ?? this.ollamaBaseUrl,
      ollamaNumCtx: ollamaNumCtx ?? this.ollamaNumCtx,
    );
  }
}

/// Lightweight descriptor of a workflow group — id + user-given title.
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
/// single-agent settings — no new schema needed. Values are stored as plain
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
  /// around this — the repo updates it from `setEnabled` and from the first
  /// `isEnabled()` call that loads from disk.
  final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(false);

  /// Reactive view of the Team Mode toggle. When true, the orchestrator
  /// adds `--team-mode` to its CLI argv on launch.
  final ValueNotifier<bool> teamModeNotifier = ValueNotifier<bool>(false);

  /// Notifies when the active group changes — UI rebuilds bind to this.
  final ValueNotifier<String?> activeGroupNotifier = ValueNotifier<String?>(null);

  /// Notifies when any group is mutated (rename / add / remove / reset).
  /// The sidebar dropdown and WorkflowBreadcrumb listen to this so they
  /// reflect renamed groups immediately when the user navigates back.
  final ValueNotifier<int> groupsChangedNotifier = ValueNotifier<int>(0);

  /// Roles, in the order they should appear in the Settings UI.
  static const List<String> roles = ['reasoner', 'summarizer'];

  /// Special role used only when Team Mode is on. Stored under the same
  /// `agent.<groupId>.leader.<field>` keys as the regular roles, but kept
  /// out of the main [roles] list so the standard Workflow Agents UI
  /// continues to show only the four core roles.
  static const String leaderRole = 'leader';

  /// Master switch. When false, the orchestrator launches in single-agent
  /// mode (the existing run-loop) regardless of the per-role assignments.
  static const String _kEnabled = 'agent.workflow.enabled';

  /// Team Mode toggle. Independent from [_kEnabled]: Team Mode requires
  /// multi-agent under the hood (each worker subprocess runs the
  /// pipeline), but the host enables both flags when Team Mode is on.
  static const String _kTeamMode = 'agent.workflow.teamMode';

  static const String _kGroups = 'agent.workflow.groups';
  static const String _kActive = 'agent.workflow.activeGroup';

  static const String _kDefaultGroupId = 'default';
  static const String _kDefaultGroupTitle = 'Default';

  // ---------------------------------------------------------------------------
  // Defaults — chosen so a user with only a Gemini key gets a working setup.
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
        );
      case 'summarizer':
        return const AgentRoleConfig(
          role: 'summarizer',
          backend: 'gemini',
          model: 'gemini-2.5-flash',
          temperature: 0.2,
          maxTokens: 1024,
        );
      case leaderRole:
        // The team leader is light coordination — a fast model is fine.
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
    final ollamaUrl = await _read('$p.ollama_base_url');
    final ollamaCtx = int.tryParse((await _read('$p.ollama_num_ctx')) ?? '');
    return AgentRoleConfig(
      role: role,
      backend: backend,
      model: model,
      tpmLimit: tpm,
      temperature: temp,
      maxTokens: mx,
      ollamaBaseUrl: (ollamaUrl == null || ollamaUrl.isEmpty) ? null : ollamaUrl,
      ollamaNumCtx: ollamaCtx,
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
    if (cfg.ollamaBaseUrl != null) {
      await _write('$p.ollama_base_url', cfg.ollamaBaseUrl!);
    }
    if (cfg.ollamaNumCtx != null) {
      await _write('$p.ollama_num_ctx', cfg.ollamaNumCtx!.toString());
    }
    // Notify any UI that mirrors role configs (e.g. WorkflowBreadcrumb) so it
    // reloads — without this the breadcrumb keeps showing the model that was
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
  // agents.json writer — called by orchestrator_manager just before launch.
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
  /// Keep this list in sync with `agent_core/backends/__init__.py`.
  static const List<String> supportedBackends = <String>[
    'openai',
    'anthropic',
    'gemini',
    'ollama',
    'openrouter',
  ];

  // ---------------------------------------------------------------------------
  // Migration — copy any legacy `agent.<role>.<field>` keys (no group segment)
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
        'ollama_base_url',
        'ollama_num_ctx',
      ]) {
        final v = await _read('$legacy.$field');
        if (v != null) {
          await _write('$prefixed.$field', v);
        }
      }
    }
    // If summarizer has no settings, try to seed from old executor.
    final summarizerBackend = await _read('agent.$_kDefaultGroupId.summarizer.backend');
    if (summarizerBackend == null) {
      final oldExecutorBackend = await _read('agent.executor.backend');
      if (oldExecutorBackend != null) {
        // Copy all executor fields to summarizer.
        for (final field in const [
          'backend',
          'model',
          'tpm_limit',
          'temperature',
          'max_tokens',
          'ollama_base_url',
          'ollama_num_ctx',
        ]) {
          final v = await _read('agent.executor.$field');
          if (v != null) {
            await _write('agent.$_kDefaultGroupId.summarizer.$field', v);
          }
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
  // Private helpers — same shape as BackendSettingsRepository's _read/_write so
  // we don't fork the persistence convention.
  // ---------------------------------------------------------------------------
  Future<String?> _read(String key) async {
    final db = await AppDatabase.instance.database;
    final rows = await db.query(
      'backend_settings',
      where: 'id = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> _write(String key, String value) async {
    final db = await AppDatabase.instance.database;
    await db.insert(
      'backend_settings',
      {'id': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _deletePrefix(String prefix) async {
    final db = await AppDatabase.instance.database;
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

  /// Persist a single role only — used by the Settings UI when one card edits.
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
/// list is *suggested*, not exhaustive — the user can always override via the
/// existing per-backend "models" lists already configured elsewhere.
class AgentRoleModelSuggestions {
  static List<String> forBackend(String backend) {
    switch (backend) {
      case 'openai':
        return const <String>[
          'gpt-4o',
          'gpt-4o-mini',
          'gpt-4-turbo',
        ];
      case 'anthropic':
        return const <String>[
          'claude-3-5-sonnet-20241022',
          'claude-3-5-haiku-20241022',
          'claude-3-opus-20240229',
        ];
      case 'gemini':
        return BackendSettingsRepository.defaultGeminiModels;
      case 'openrouter':
        return const <String>[
          'openai/gpt-4o',
          'anthropic/claude-3.5-sonnet',
          'google/gemini-2.5-pro',
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
