import 'dart:convert';
import 'dart:io';

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
        if (ollamaBaseUrl != null && ollamaBaseUrl!.isNotEmpty)
          'ollama_base_url': ollamaBaseUrl,
        if (ollamaNumCtx != null) 'ollama_num_ctx': ollamaNumCtx,
      };

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

/// Persists per-role agent assignments alongside the existing backend
/// settings. Keys live in the same `backend_settings` table as the
/// single-agent settings — no new schema needed. Values are stored as plain
/// strings so the existing read/write helpers translate cleanly.
///
/// Naming convention: `agent.<role>.<field>` — e.g. `agent.router.backend`.
class AgentRoleSettingsRepository {
  AgentRoleSettingsRepository._();

  static final AgentRoleSettingsRepository instance =
      AgentRoleSettingsRepository._();

  /// Roles, in the order they should appear in the Settings UI.
  static const List<String> roles = ['router', 'shaper', 'reasoner', 'executor'];

  /// Master switch. When false, the orchestrator launches in single-agent
  /// mode (the existing run-loop) regardless of the per-role assignments.
  static const String _kEnabled = 'agent.workflow.enabled';

  // ---------------------------------------------------------------------------
  // Defaults — chosen so a user with only a Gemini key gets a working setup.
  // The Reasoner picks the strongest tier; the rest tier down.
  // ---------------------------------------------------------------------------
  static AgentRoleConfig defaultFor(String role) {
    switch (role) {
      case 'router':
        return const AgentRoleConfig(
          role: 'router',
          backend: 'gemini',
          model: 'gemini-2.5-flash-lite',
          temperature: 0.0,
          maxTokens: 8,
        );
      case 'shaper':
        return const AgentRoleConfig(
          role: 'shaper',
          backend: 'gemini',
          model: 'gemini-2.5-flash',
          temperature: 0.2,
          maxTokens: 256,
        );
      case 'reasoner':
        return const AgentRoleConfig(
          role: 'reasoner',
          backend: 'gemini',
          model: 'gemini-2.5-pro',
          temperature: 0.2,
          maxTokens: 4096,
        );
      case 'executor':
        return const AgentRoleConfig(
          role: 'executor',
          backend: 'gemini',
          model: 'gemini-2.5-flash',
          temperature: 0.4,
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
    return v == '1' || v == 'true';
  }

  Future<void> setEnabled(bool enabled) =>
      _write(_kEnabled, enabled ? '1' : '0');

  // ---------------------------------------------------------------------------
  // Per-role getters/setters
  // ---------------------------------------------------------------------------
  Future<AgentRoleConfig> get(String role) async {
    final def = defaultFor(role);
    final backend = (await _read('agent.$role.backend')) ?? def.backend;
    final model = (await _read('agent.$role.model')) ?? def.model;
    final tpm = int.tryParse((await _read('agent.$role.tpm_limit')) ?? '') ?? def.tpmLimit;
    final temp = double.tryParse((await _read('agent.$role.temperature')) ?? '') ?? def.temperature;
    final mx = int.tryParse((await _read('agent.$role.max_tokens')) ?? '') ?? def.maxTokens;
    final ollamaUrl = await _read('agent.$role.ollama_base_url');
    final ollamaCtx = int.tryParse((await _read('agent.$role.ollama_num_ctx')) ?? '');
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

  Future<void> set(String role, AgentRoleConfig cfg) async {
    await _write('agent.$role.backend', cfg.backend);
    await _write('agent.$role.model', cfg.model);
    await _write('agent.$role.tpm_limit', cfg.tpmLimit.toString());
    await _write('agent.$role.temperature', cfg.temperature.toString());
    await _write('agent.$role.max_tokens', cfg.maxTokens.toString());
    if (cfg.ollamaBaseUrl != null) {
      await _write('agent.$role.ollama_base_url', cfg.ollamaBaseUrl!);
    }
    if (cfg.ollamaNumCtx != null) {
      await _write('agent.$role.ollama_num_ctx', cfg.ollamaNumCtx!.toString());
    }
  }

  Future<Map<String, AgentRoleConfig>> getAll() async {
    final out = <String, AgentRoleConfig>{};
    for (final r in roles) {
      out[r] = await get(r);
    }
    return out;
  }

  Future<void> resetToDefaults() async {
    for (final r in roles) {
      await set(r, defaultFor(r));
    }
  }

  // ---------------------------------------------------------------------------
  // agents.json writer — called by orchestrator_manager just before launch.
  // ---------------------------------------------------------------------------
  /// Serialise every role to the JSON shape the Python side expects.
  Future<File> writeAgentConfigJson(String path) async {
    final all = await getAll();
    final body = <String, Object?>{};
    for (final entry in all.entries) {
      body[entry.key] = entry.value.toJson();
    }
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(body));
    return f;
  }

  /// Backend names recognised by the Python `build_backend` factory.
  /// Keep this list in sync with `bin/agent/backends/__init__.py`.
  static const List<String> supportedBackends = <String>[
    'gemini',
    'groq',
    'openrouter',
    'github',
    'huggingface',
    'ollama',
  ];

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
}

/// Suggested model lists per backend. Used by the Settings UI to populate the
/// per-role dropdowns without forcing the user to type the model name. The
/// list is *suggested*, not exhaustive — the user can always override via the
/// existing per-backend "models" lists already configured elsewhere.
class AgentRoleModelSuggestions {
  static List<String> forBackend(String backend) {
    switch (backend) {
      case 'gemini':
        return BackendSettingsRepository.defaultGeminiModels;
      case 'groq':
        return const <String>[
          'llama-3.1-8b-instant',
          'llama-3.3-70b-versatile',
          'mixtral-8x7b-32768',
        ];
      case 'openrouter':
        return const <String>[
          'meta-llama/llama-3.1-8b-instruct',
          'anthropic/claude-3.5-haiku',
          'google/gemini-flash-1.5',
        ];
      case 'github':
        return const <String>[
          'gpt-4o-mini',
          'gpt-4o',
          'meta-llama-3.1-8b-instruct',
        ];
      case 'ollama':
        return const <String>[
          'llama3.2:1b',
          'llama3.2:3b',
          'qwen2.5-coder:7b',
        ];
      case 'huggingface':
        return const <String>[
          'meta-llama/Llama-3.1-8B-Instruct',
          'meta-llama/Llama-3.1-70B-Instruct',
        ];
      default:
        return const <String>[];
    }
  }
}
