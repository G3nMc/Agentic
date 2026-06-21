import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String _dbName = "hf_chat.db";
  static const int _dbVersion = 13;

  Database? _db;
  Completer<Database>? _opening;

  // Must be called once at app start-up to pick the correct sqflite backend.
  static void configurePlatform() {
    if (kIsWeb) {
      // Web is currently not supported by this build; fallback would require
      // sqflite_common_ffi_web. The rest of the app still runs, but DB ops
      // will throw until web support is added.
      return;
    }
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  Future<Database> get database async {
    if (_db != null) return _db!;
    if (_opening != null) return _opening!.future;

    _opening = Completer<Database>();
    try {
      final db = await _openDatabase();
      _db = db;
      _opening!.complete(db);
    } catch (e, st) {
      _opening!.completeError(e, st);
      _opening = null;
      rethrow;
    }
    return _db!;
  }

  Future<Database> _openDatabase() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final appDir = Directory(p.join(docsDir.path, "agentic"));

    if (!await appDir.exists()) {
      await appDir.create(recursive: true);
    }

    final path = p.join(appDir.path, _dbName);
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onConfigure: _onConfigure,
      ),
    );
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute("PRAGMA foreign_keys = ON;");
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    // Key/value application settings (HF token, selected model, etc.).
    batch.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      );
    ''');

    // Saved HF model IDs for quick switching.
    batch.execute('''
      CREATE TABLE models (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      );
    ''');

    // Conversations metadata.
    batch.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        model_id TEXT,
        backend TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        group_id TEXT,
        thinking INTEGER NOT NULL DEFAULT 0,
        effort TEXT NOT NULL DEFAULT 'medium'
      );
    ''');

    batch.execute('''
      CREATE INDEX idx_conversations_updated_at
      ON conversations(updated_at DESC);
    ''');

    // Individual chat messages.
    // `agent` is nullable: legacy single-agent replies leave it NULL, the
    // multi-agent workflow sets it to the producing role (router/shaper/
    // reasoner/executor/workflow) so the UI can render per-step badges.
    // `response_time_ms` is nullable: only assistant messages carry the
    // time it took to generate the reply.
    batch.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        agent TEXT,
        response_time_ms INTEGER,
        hidden INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (conversation_id)
          REFERENCES conversations(id)
          ON DELETE CASCADE
      );
    ''');

    batch.execute('''
      CREATE INDEX idx_messages_conversation
      ON messages(conversation_id, created_at ASC);
    ''');

    // Backend settings (remote API vs local server)
    batch.execute('''
      CREATE TABLE backend_settings (
        id TEXT PRIMARY KEY,
        value TEXT
      );
    ''');

    // Local server configurations per model
    batch.execute('''
      CREATE TABLE local_server_configs (
        model_id TEXT PRIMARY KEY,
        python_code TEXT NOT NULL,
        host TEXT NOT NULL DEFAULT 'localhost',
        port INTEGER NOT NULL DEFAULT 5000,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      );
    ''');

    // Agent credentials (HF token and local API key)
    batch.execute('''
      CREATE TABLE agent_credentials (
        id TEXT PRIMARY KEY,
        hf_token TEXT,
        local_key TEXT,
        updated_at INTEGER
      );
    ''');

    // Context summaries for conversations
    batch.execute('''
      CREATE TABLE context_summaries (
        conversation_id TEXT PRIMARY KEY,
        summary_text TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (conversation_id)
          REFERENCES conversations(id)
          ON DELETE CASCADE
      );
    ''');

    // Structured task list per conversation (TASK COMPLIANCE mode).
    // task_id is the model-assigned sequence within the conversation
    // (1, 2, 3, ...). status is one of:
    //   pending, in_progress, done, partial, blocked, failed, skipped.
    // depends_on stores a JSON array of task_id values.
    batch.execute('''
      CREATE TABLE conversation_tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id TEXT NOT NULL,
        task_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        description TEXT,
        success_criteria TEXT,
        depends_on TEXT,
        status TEXT NOT NULL DEFAULT 'pending',
        note TEXT,
        started_at INTEGER,
        completed_at INTEGER,
        iterations_used INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY (conversation_id)
          REFERENCES conversations(id)
          ON DELETE CASCADE,
        UNIQUE (conversation_id, task_id)
      );
    ''');

    batch.execute('''
      CREATE INDEX idx_conversation_tasks_conv
      ON conversation_tasks(conversation_id, task_id ASC);
    ''');

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Migrate to v2: add backend settings and local server configs
      await db.execute('''
        CREATE TABLE IF NOT EXISTS backend_settings (
          id TEXT PRIMARY KEY,
          value TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE IF NOT EXISTS local_server_configs (
          model_id TEXT PRIMARY KEY,
          python_code TEXT NOT NULL,
          host TEXT NOT NULL DEFAULT 'localhost',
          port INTEGER NOT NULL DEFAULT 5000,
          is_enabled INTEGER NOT NULL DEFAULT 1,
          created_at INTEGER NOT NULL
        )
      ''');
    }
    if (oldVersion < 3) {
      // Migrate to v3: add agent credentials
      await db.execute('''
        CREATE TABLE IF NOT EXISTS agent_credentials (
          id TEXT PRIMARY KEY,
          hf_token TEXT,
          local_key TEXT,
          updated_at INTEGER
        )
      ''');
    }
    if (oldVersion < 4) {
      // Migrate to v4: associate each conversation with its LLM backend.
      await db.execute('ALTER TABLE conversations ADD COLUMN backend TEXT');

      // Back-fill existing rows with the currently active backend so the
      // user does not lose access to them when the sidebar starts
      // filtering. Non-orchestrator backends are coerced to their
      // orchestrator equivalent because the UI no longer exposes direct
      // variants.
      String defaultBackend = 'orchestrator';
      final rows = await db.query(
        'backend_settings',
        where: 'id = ?',
        whereArgs: ['active_backend'],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        final stored = (rows.first['value'] as String?) ?? '';
        final name = stored.contains('.') ? stored.split('.').last : stored;
        defaultBackend = _coerceToOrchestratorName(name);
      }
      await db.update(
        'conversations',
        {'backend': defaultBackend},
        where: 'backend IS NULL',
      );
    }
    if (oldVersion < 5) {
      // Migrate to v5: tag each assistant reply with the workflow agent
      // that produced it. Nullable so single-agent rows stay untouched.
      await db.execute('ALTER TABLE messages ADD COLUMN agent TEXT');
    }
    if (oldVersion < 6) {
      // Migrate to v6: associate each conversation with a workflow group.
      await db.execute('ALTER TABLE conversations ADD COLUMN group_id TEXT');
    }
    if (oldVersion < 7) {
      // Defensive: earlier builds shipped a v6 _onCreate that omitted
      // `group_id`, leaving fresh installs at v6 without the column. Add it
      // if missing so those users recover without wiping the DB.
      final cols = await db.rawQuery('PRAGMA table_info(conversations)');
      final hasGroupId = cols.any((row) => row['name'] == 'group_id');
      if (!hasGroupId) {
        await db.execute('ALTER TABLE conversations ADD COLUMN group_id TEXT');
      }
    }
    if (oldVersion < 8) {
      // Migrate to v8: store assistant response time (ms) per message.
      // Defensive: an earlier build added this column directly in
      // _onCreate, leaving some installs already in possession of it
      // before the version bump landed. Skip the ALTER in that case so
      // the upgrade doesn't fault on "duplicate column".
      final cols = await db.rawQuery('PRAGMA table_info(messages)');
      final hasResponseTime =
          cols.any((row) => row['name'] == 'response_time_ms');
      if (!hasResponseTime) {
        await db.execute(
            'ALTER TABLE messages ADD COLUMN response_time_ms INTEGER');
      }
    }
    if (oldVersion < 9) {
      // Migrate to v9: add context summaries table
      await db.execute('''
        CREATE TABLE IF NOT EXISTS context_summaries (
          conversation_id TEXT PRIMARY KEY,
          summary_text TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (conversation_id)
            REFERENCES conversations(id)
            ON DELETE CASCADE
        )
      ''');
    }
    if (oldVersion < 10) {
      // Migrate to v10: add project_path to conversations for project scoping.
      // Existing rows get NULL — they will appear in all projects until the
      // user explicitly assigns them (or we backfill from a heuristic later).
      await db.execute(
        'ALTER TABLE conversations ADD COLUMN project_path TEXT',
      );
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_conversations_project_path
        ON conversations(project_path)
      ''');
    }
    if (oldVersion < 11) {
      // Migrate to v11: structured task list per conversation. Existing
      // chats simply have no rows here and the UI task panel stays
      // hidden for them (no migration of historical data needed).
      await db.execute('''
        CREATE TABLE IF NOT EXISTS conversation_tasks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          conversation_id TEXT NOT NULL,
          task_id INTEGER NOT NULL,
          name TEXT NOT NULL,
          description TEXT,
          success_criteria TEXT,
          depends_on TEXT,
          status TEXT NOT NULL DEFAULT 'pending',
          note TEXT,
          started_at INTEGER,
          completed_at INTEGER,
          iterations_used INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          FOREIGN KEY (conversation_id)
            REFERENCES conversations(id)
            ON DELETE CASCADE,
          UNIQUE (conversation_id, task_id)
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_conversation_tasks_conv
        ON conversation_tasks(conversation_id, task_id ASC)
      ''');
    }
    if (oldVersion < 12) {
      // Migrate to v12: per-conversation thinking mode and effort level.
      final cols = await db.rawQuery('PRAGMA table_info(conversations)');
      final hasThinking = cols.any((row) => row['name'] == 'thinking');
      final hasEffort = cols.any((row) => row['name'] == 'effort');
      if (!hasThinking) {
        await db.execute(
          'ALTER TABLE conversations ADD COLUMN thinking INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (!hasEffort) {
        await db.execute(
          "ALTER TABLE conversations ADD COLUMN effort TEXT NOT NULL DEFAULT 'medium'",
        );
      }
    }
    if (oldVersion < 13) {
      // Migrate to v13: hidden status messages that are visible in the UI
      // but excluded from the model's history.
      final cols = await db.rawQuery('PRAGMA table_info(messages)');
      final hasHidden = cols.any((row) => row['name'] == 'hidden');
      if (!hasHidden) {
        await db.execute(
          'ALTER TABLE messages ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0',
        );
      }
    }
  }

  String _coerceToOrchestratorName(String name) {
    switch (name) {
      case 'huggingFace':
      case 'local':
      case '':
        return 'orchestrator';
      case 'ollama':
      case 'ollamaPython':
      case 'ollamaGenerate':
        return 'ollamaOrchestrator';
      case 'groq':
        return 'groqOrchestrator';
      case 'openRouter':
        return 'openRouterOrchestrator';
      default:
        return name; // already an orchestrator variant
    }
  }

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
