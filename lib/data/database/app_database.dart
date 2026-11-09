import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String _dbRelativePath = "data/agentic_data.db";
  static const String _projectDbRelativePath = ".agentic/data/agentic_project_data.db";
  static const int _dbVersion = 15;

  Database? _db;
  Completer<Database>? _opening;
  String? _activeDbPath;

  Database? _globalDb;
  Completer<Database>? _globalOpening;
  String? _globalDbPath;

  /// Provided by ProjectService at startup. When non-null, the database is
  /// opened inside the active project folder instead of the global user data
  /// directory. Changing the returned value triggers a reopen on next access.
  static String? Function()? projectPathProvider;

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

  /// The project-local database. Contains only project-scoped tables:
  /// conversations, messages, context_summaries, conversation_tasks.
  Future<Database> get database async {
    final desiredPath = await databasePath();
    final current = _db;
    if (current != null && _activeDbPath == desiredPath && current.isOpen) {
      return current;
    }
    final opening = _opening;
    if (opening != null && _activeDbPath == desiredPath) {
      return opening.future;
    }

    // The active project changed (or this is the first open). Close the old
    // connection and open the new database so repositories transparently
    // switch to the project-local file.
    if (current != null) {
      _db = null;
      try {
        await current.close();
      } catch (_) {
        // Already closed by another caller; ignore.
      }
    }

    _activeDbPath = desiredPath;
    final completer = Completer<Database>();
    _opening = completer;
    try {
      final db = await _openDatabase(desiredPath, _DatabaseKind.project);
      _db = db;
      if (!completer.isCompleted) completer.complete(db);
      return db;
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
      _activeDbPath = null;
      rethrow;
    } finally {
      if (identical(_opening, completer)) _opening = null;
    }
  }

  /// The global user-level database. Contains only global tables:
  /// settings, models, backend_settings, local_server_configs,
  /// agent_credentials. This is where Model Settings and API keys live so
  /// they never travel with a project folder.
  Future<Database> get globalDatabase async {
    final desiredPath = await globalDatabasePath();
    final current = _globalDb;
    if (current != null && _globalDbPath == desiredPath && current.isOpen) {
      return current;
    }
    final opening = _globalOpening;
    if (opening != null && _globalDbPath == desiredPath) {
      return opening.future;
    }

    if (current != null) {
      _globalDb = null;
      try {
        await current.close();
      } catch (_) {
        // Already closed by another caller; ignore.
      }
    }

    _globalDbPath = desiredPath;
    final completer = Completer<Database>();
    _globalOpening = completer;
    try {
      final db = await _openDatabase(desiredPath, _DatabaseKind.global);
      _globalDb = db;
      if (!completer.isCompleted) completer.complete(db);
      return db;
    } catch (e, st) {
      if (!completer.isCompleted) completer.completeError(e, st);
      _globalDbPath = null;
      rethrow;
    } finally {
      if (identical(_globalOpening, completer)) _globalOpening = null;
    }
  }

  /// Test-only override for the project-scoped database file. Widget and unit
  /// tests point this (and [debugGlobalDatabasePathOverride]) at throwaway
  /// files so they exercise the real repositories against a private schema:
  /// no user data is read or written, and parallel suites cannot collide.
  @visibleForTesting
  static String? debugProjectDatabasePathOverride;

  /// Test-only override for the global database file.
  @visibleForTesting
  static String? debugGlobalDatabasePathOverride;

  // Resolves to the project-local database path. When no project is active
  // this falls back to a project-scoped file inside the global data
  // directory so the app still works before a project is selected without
  // mixing project tables into the global database.
  static Future<String> databasePath() async {
    final override = debugProjectDatabasePathOverride;
    if (override != null) return override;
    final projectPath = projectPathProvider?.call();
    if (projectPath != null && projectPath.trim().isNotEmpty) {
      return p.join(projectPath, _projectDbRelativePath);
    }
    final globalDir = p.dirname(await globalDatabasePath());
    return p.join(globalDir, 'agentic_project_data.db');
  }

  // Resolves to a stable per-user system data directory (e.g.
  // %LOCALAPPDATA%\.agentic\agentic_data.db on Windows) so the database
  // survives debug/release executable path changes.
  static Future<String> globalDatabasePath() async {
    final override = debugGlobalDatabasePathOverride;
    if (override != null) return override;
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return p.join("$localAppData/.agentic", _dbRelativePath);
      }
    }
    final baseDir = await getApplicationSupportDirectory();
    return p.join("${baseDir.path}/.agentic", _dbRelativePath);
  }

  Future<Database> _openDatabase(String path, _DatabaseKind kind) async {
    final appDir = Directory(p.dirname(path));
    if (!await appDir.exists()) {
      await appDir.create(recursive: true);
    }

    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _dbVersion,
        onCreate: (db, version) => _onCreate(db, version, kind),
        onUpgrade: (db, oldVersion, newVersion) =>
            _onUpgrade(db, oldVersion, newVersion, kind),
        onConfigure: _onConfigure,
      ),
    );

    // Existing databases may contain tables that belong to the other scope
    // (the previous single-DB design stored everything in one file). Drop
    // them so each database contains only its context-related tables.
    await _dropForeignTables(db, kind);

    return db;
  }

  static const List<String> _globalTables = [
    'settings',
    'models',
    'backend_settings',
    'local_server_configs',
    'agent_credentials',
  ];

  static const List<String> _projectTables = [
    'messages',
    'context_summaries',
    'conversation_tasks',
    'conversation_turns',
    'conversations',
  ];

  Future<void> _dropForeignTables(Database db, _DatabaseKind kind) async {
    final keep = kind == _DatabaseKind.global ? _globalTables : _projectTables;
    final drop = kind == _DatabaseKind.global ? _projectTables : _globalTables;

    for (final table in drop) {
      if (keep.contains(table)) continue;
      try {
        await db.execute('DROP TABLE IF EXISTS $table');
      } catch (_) {
        // Table may not exist in this database; ignore.
      }
    }
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute("PRAGMA foreign_keys = ON;");
  }

  Future<void> _onCreate(Database db, int version, _DatabaseKind kind) async {
    final batch = db.batch();

    if (kind == _DatabaseKind.global) {
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
    } else {
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
          project_path TEXT,
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

      // Structured task list per conversation (task-checklist mode).
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

      // One row per chat turn (the prompt -> reply transaction). A turn is
      // opened as `running` and closed on completion / failure / abort, so a
      // turn interrupted by a crash or a forced stop stays visible as such
      // instead of silently vanishing from the transcript.
      batch.execute('''
        CREATE TABLE conversation_turns (
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          status TEXT NOT NULL,
          prompt TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          error TEXT,
          backend TEXT,
          model_id TEXT,
          FOREIGN KEY (conversation_id)
            REFERENCES conversations(id)
            ON DELETE CASCADE
        );
      ''');

      batch.execute('''
        CREATE INDEX idx_turns_conversation
        ON conversation_turns(conversation_id, started_at DESC);
      ''');
    }

    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
    _DatabaseKind kind,
  ) async {
    final isGlobal = kind == _DatabaseKind.global;

    if (oldVersion < 2 && isGlobal) {
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
    if (oldVersion < 3 && isGlobal) {
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
    if (oldVersion < 4 && !isGlobal) {
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
    if (oldVersion < 5 && !isGlobal) {
      // Migrate to v5: tag each assistant reply with the workflow agent
      // that produced it. Nullable so single-agent rows stay untouched.
      await db.execute('ALTER TABLE messages ADD COLUMN agent TEXT');
    }
    if (oldVersion < 6 && !isGlobal) {
      // Migrate to v6: associate each conversation with a workflow group.
      await db.execute('ALTER TABLE conversations ADD COLUMN group_id TEXT');
    }
    if (oldVersion < 7 && !isGlobal) {
      // Defensive: earlier builds shipped a v6 _onCreate that omitted
      // `group_id`, leaving fresh installs at v6 without the column. Add it
      // if missing so those users recover without wiping the DB.
      final cols = await db.rawQuery('PRAGMA table_info(conversations)');
      final hasGroupId = cols.any((row) => row['name'] == 'group_id');
      if (!hasGroupId) {
        await db.execute('ALTER TABLE conversations ADD COLUMN group_id TEXT');
      }
    }
    if (oldVersion < 8 && !isGlobal) {
      // Migrate to v8: store assistant response time (ms) per message.
      // Defensive: an earlier build added this column directly in
      // _onCreate, leaving some installs already in possession of it
      // before the version bump landed. Skip the ALTER in that case so
      // the upgrade doesn't fault on "duplicate column".
      final cols = await db.rawQuery('PRAGMA table_info(messages)');
      final hasResponseTime = cols.any((row) => row['name'] == 'response_time_ms');
      if (!hasResponseTime) {
        await db.execute('ALTER TABLE messages ADD COLUMN response_time_ms INTEGER');
      }
    }
    if (oldVersion < 9 && !isGlobal) {
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
    if (oldVersion < 10 && !isGlobal) {
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
    if (oldVersion < 11 && !isGlobal) {
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
    if (oldVersion < 12 && !isGlobal) {
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
    if (oldVersion < 13 && !isGlobal) {
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
    if (oldVersion < 14 && !isGlobal) {
      // Migrate to v14: add project_path to conversations for project
      // scoping. Defensive: an earlier v13 build added this column directly
      // in _onCreate, leaving some installs already in possession of it
      // before the version bump landed. Skip the ALTER in that case so the
      // upgrade doesn't fault on "duplicate column".
      final convCols = await db.rawQuery('PRAGMA table_info(conversations)');
      final hasProjectPath = convCols.any((row) => row['name'] == 'project_path');
      if (!hasProjectPath) {
        await db.execute(
          'ALTER TABLE conversations ADD COLUMN project_path TEXT',
        );
      }
    }
    if (oldVersion < 15 && !isGlobal) {
      // Migrate to v15: per-turn journal so an interrupted turn stays visible.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS conversation_turns (
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          status TEXT NOT NULL,
          prompt TEXT NOT NULL,
          started_at INTEGER NOT NULL,
          ended_at INTEGER,
          error TEXT,
          backend TEXT,
          model_id TEXT,
          FOREIGN KEY (conversation_id)
            REFERENCES conversations(id)
            ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_turns_conversation
        ON conversation_turns(conversation_id, started_at DESC)
      ''');
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
      _db = null;
      try {
        await db.close();
      } catch (_) {
        // Already closed by another caller; ignore.
      }
    }
    _activeDbPath = null;

    final globalDb = _globalDb;
    if (globalDb != null) {
      _globalDb = null;
      try {
        await globalDb.close();
      } catch (_) {
        // Already closed by another caller; ignore.
      }
    }
    _globalDbPath = null;
  }

  /// Invalidates the cached connections so the next [database] access opens
  /// the database at the path resolved from [projectPathProvider]. The
  /// previous connections are intentionally left open: repositories may still
  /// hold a reference to them, and closing them underneath them causes
  /// `DatabaseException(error database_closed)`. They are closed on app exit
  /// via [close]. Safe to call before the database has ever been opened.
  Future<void> reopen() async {
    _db = null;
    _activeDbPath = null;
    _globalDb = null;
    _globalDbPath = null;
  }
}

enum _DatabaseKind { global, project }
