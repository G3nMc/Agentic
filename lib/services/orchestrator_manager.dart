import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agentic/services/project_service.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models/conversation_task.dart';
import '../data/repositories/agent_role_settings_repository.dart';
import '../data/repositories/backend_settings_repository.dart';
import '../data/repositories/database_connections_repository.dart';
import '../data/repositories/dev_filters_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/task_repository.dart';

/// Structured event emitted by the Python orchestrator while running
/// in TASK COMPLIANCE mode. Two concrete shapes:
///   - [OrchestratorTasksProposed]: a fresh plan was declared.
///   - [OrchestratorTaskStatusChanged]: one task moved to a new state.
sealed class OrchestratorTaskEvent {
  const OrchestratorTaskEvent({required this.conversationId});
  final String conversationId;
}

class OrchestratorTasksProposed extends OrchestratorTaskEvent {
  const OrchestratorTasksProposed({
    required super.conversationId,
    required this.tasks,
  });
  final List<ConversationTask> tasks;
}

class OrchestratorTaskStatusChanged extends OrchestratorTaskEvent {
  const OrchestratorTaskStatusChanged({
    required super.conversationId,
    required this.taskId,
    required this.status,
    this.note = '',
    this.description = '',
  });
  final int taskId;
  final TaskStatus status;
  final String note;

  /// Human-readable task description, mirrored from the plan so the UI can
  /// show what the model is working on without a separate DB lookup.
  final String description;
}

// Inactivity timeout: if the orchestrator emits no output on stdout OR
// stderr for this long, we assume it's wedged and give up. Activity
// (including per-chunk heartbeat lines from the Python streaming loops)
// resets it. 10 min gives slow local models (phi3:mini on CPU) enough
// headroom while still catching a truly wedged process.
const Duration _kOrchestratorInactivityTimeout = Duration(minutes: 60);

// Absolute ceiling: even if the orchestrator keeps heart-beating, refuse to
// wait longer than this for a single prompt. Prevents runaway tool chains.
// Set high enough to cover long multi-agent chains where each role may take
// multiple minutes (slow cloud reasoners, large file edits + repeated
// flutter_analyze cycles). The inactivity timeout above still catches a
// truly wedged process within 10 min of silence.
const Duration _kOrchestratorAbsoluteTimeout = Duration(minutes: 120);

/// Which model backend the orchestrator subprocess should use.
///
/// The orchestrator's tool protocol is backend-agnostic; this only decides
/// who actually runs inference. [huggingface] hits the HF router (needs a
/// token), [ollama] hits a local Ollama daemon (needs the daemon running),
/// [groq] hits Groq Cloud, [gemini] hits Google AI Studio / Gemini Cloud,
/// and [openrouter] routes to any supported provider via OpenRouter.
enum OrchestratorBackend { huggingface, ollama, groq, gemini, openrouter, github }

/// Manages the lifecycle of the local Python orchestrator subprocess that
/// bridges the Flutter UI with remote Hugging Face models + local tools.
///
/// Protocol (must match `bin/orchestrator.py`):
///   - Orchestrator is launched with `--interactive`.
///   - When ready it prints a single line: `__READY__`
///   - Client writes ONE JSON line per request:
///       {"prompt": "...", "new_session": true|false}
///   - Orchestrator replies with exactly one JSON line:
///       {"response": "..."}
///     followed by a single line:
///       __RESPONSE_END__
class OrchestratorManager {
  OrchestratorManager._internal();
  static final OrchestratorManager instance = OrchestratorManager._internal();

  Process? _process;
  bool _isRunning = false;
  bool _isReady = false;
  // Guards against concurrent start() calls before _isRunning flips true.
  // Holds the in-flight start() future so overlapping callers await the same
  // result instead of each spawning their own subprocess.
  Future<bool>? _startingFuture;
  OrchestratorBackend _currentBackend = OrchestratorBackend.huggingface;
  String? _currentModelId;
  double? _currentTemperature;
  final StringBuffer _stderrBuffer = StringBuffer();

  // â”€â”€ Live log stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // A broadcast StreamController so multiple widgets can subscribe
  // simultaneously without causing "already subscribed" errors.
  final StreamController<String> _logController = StreamController<String>.broadcast();

  // â”€â”€ Multi-agent execution-trace stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Each entry is one agent activation. Only fires when the orchestrator was
  // launched with `multiAgent: true` and Python actually returned a `trace`
  // array in its response payload. Single-agent mode leaves this idle.
  final StreamController<List<Map<String, Object?>>> _traceController = StreamController<List<Map<String, Object?>>>.broadcast();
  Stream<List<Map<String, Object?>>> get traceStream => _traceController.stream;
  List<Map<String, Object?>> _lastTrace = const [];
  List<Map<String, Object?>> get lastTrace => List.unmodifiable(_lastTrace);

  // â”€â”€ Human-friendly status stream â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  // Each event is a short label like "Reading file..." or "Analyzing Dart
  // code..." that the typing indicator displays instead of "Working...".
  final StreamController<String> _statusController = StreamController<String>.broadcast();

  /// Live stream of human-friendly status labels derived from orchestrator
  /// log lines. Use this to show what the model is doing right now.
  Stream<String> get statusStream => _statusController.stream;

  /// Live stream of orchestrator log lines (stderr of the subprocess).
  /// Each event is a single trimmed line such as
  ///   "[orch] Groq streaming 'llama-3.3-70b-versatile' (42 chars)..."
  Stream<String> get logStream => _logController.stream;

  // ── Task-flow event stream ────────────────────────────────────────
  // Carries structured events emitted by the Python orchestrator while
  // running in TASK COMPLIANCE mode: ``tasks_proposed`` (plan
  // declared), ``task_status`` (one task moved to a new state). The UI
  // subscribes via ``taskStream`` to update the checklist panel live
  // and the persistence layer subscribes to mirror changes into the
  // ``conversation_tasks`` SQLite table.
  final StreamController<OrchestratorTaskEvent> _taskController =
      StreamController<OrchestratorTaskEvent>.broadcast();

  /// Live stream of structured task-flow events. Idle when the chat
  /// runs in OPEN mode.
  Stream<OrchestratorTaskEvent> get taskStream => _taskController.stream;

  /// Conversation id currently being processed. Set by
  /// [_sendPromptInternal] just before writing to stdin so the
  /// dispatcher can attach it to incoming task events (Python doesn't
  /// re-echo it on every event).
  String? _currentConversationId;

  /// Rolling in-memory buffer of the most recent [_kMaxLogLines] lines.
  /// Useful for widgets that appear after the process has already emitted
  /// output (they can populate themselves from this list on first build).
  static const int _kMaxLogLines = 2000;
  final List<String> _logLines = [];
  List<String> get logLines => List.unmodifiable(_logLines);
  String? _lastNonEmptyLogLine;

  void _appendLog(String line) {
    final trimmed = line.trim();
    // Empty lines are pure heartbeat signals from the Python streaming loop.
    // They still bump the inactivity watchdog (the listener calls
    // _bumpInactivityTimer unconditionally) but we don't show them in the
    // visible log so they don't scroll meaningful output off screen.
    if (trimmed.isEmpty) return;

    // Avoid repeated noise when the same startup/preflight error is emitted
    // multiple times in quick succession.
    if (_lastNonEmptyLogLine == trimmed) return;
    _lastNonEmptyLogLine = trimmed;

    _stderrBuffer.writeln(trimmed);
    _logLines.add(trimmed);
    if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
    if (!_logController.isClosed) _logController.add(trimmed);

    // Persist to the per-chat log file so logs survive process restarts.
    _writeToLogFile(trimmed);

    // Derive a human-friendly status label from the raw log line and push
    // it onto the status stream so the typing indicator can show what the
    // model is doing right now instead of a generic "Working...".
    final status = _deriveStatus(trimmed);
    if (status != null) {
      _lastStatus = status;
      if (!_statusController.isClosed) _statusController.add(status);
    }
  }

  /// Append a single line to `<basePath>/logs/<sessionKey>.log`.
  ///
  /// Creates the `logs/` directory on first write. When a previous chat is
  /// reloaded the file already exists, so new lines naturally append after
  /// the previous session's output â€” no explicit prepend step needed.
  void _writeToLogFile(String line) {
    final base = _basePath;
    final key = _sessionKey;
    if (base == null || key == null || key.isEmpty) return;
    try {
      final dir = Directory('$base${Platform.pathSeparator}logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}$key.log',
      );
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort: never let a disk write failure crash the orchestrator
      // or leak into the visible log stream.
    }
  }

  /// Push a synthetic line into the log buffer + stream + on-disk file.
  /// Used by the UI to surface client-side events (e.g. task_action
  /// envelopes leaving the Flutter side) in the same panel as the
  /// orchestrator-side stderr output, so a debugger can see the full
  /// model<->orchestrator<->UI exchange in chronological order.
  void _injectLogLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _logLines.add(trimmed);
    if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
    if (!_logController.isClosed) _logController.add(trimmed);
    _writeToLogFile(trimmed);
  }

  /// Read the on-disk log file for [sessionKey] and push every line into the
  /// in-memory buffer and live stream so the log panel shows previous-session
  /// output immediately when a chat is reloaded.
  ///
  /// Safe to call before the orchestrator subprocess is running â€” only needs
  /// [_basePath] to be set (which happens during [start]).
  void loadLogFromDisk(String sessionKey) {
    final base = _basePath;
    if (base == null || sessionKey.isEmpty) return;
    try {
      final file = File(
        '$base${Platform.pathSeparator}logs${Platform.pathSeparator}$sessionKey.log',
      );
      if (!file.existsSync()) return;
      final lines = file.readAsLinesSync();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        _logLines.add(trimmed);
        if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
        if (!_logController.isClosed) _logController.add(trimmed);
      }
    } catch (_) {
      // Best-effort: never let a disk read failure block the UI.
    }
  }

  /// Latest human-friendly status label, or null if nothing has been derived
  /// yet. Widgets that mount late can read this to show the current activity.
  String? _lastStatus;

  /// Current human-friendly status label (may be null).
  String? get lastStatus => _lastStatus;

  /// Map a raw orchestrator log line to a short, user-facing label.
  ///
  /// Returns null when the line doesn't carry a meaningful activity signal
  /// (e.g. pure heartbeat, token-budget trimming, circuit-breaker chatter).
  /// The returned string should be short enough to fit next to the three
  /// animated dots â€” aim for â‰¤ 40 characters.
  static String? _deriveStatus(String line) {
    final l = line.toLowerCase();

    // â”€â”€ Task-flow progress (show in typing indicator) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[task]') && l.contains('-> in_progress')) {
      final note = _extractAfter(line, ': ');
      if (note != null && note.isNotEmpty) return note;
      return 'Working on task...';
    }
    if (l.contains('[task] proposed plan')) return 'Planning...';

    // â”€â”€ Tool calls â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[orch] -> tool ')) {
      final tool = _extractAfter(line, '[orch] -> tool ');
      if (tool == null) return null;
      return _labelForTool(tool);
    }

    // â”€â”€ Model reply arrived â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[orch] model reply')) return 'Thinking...';

    // â”€â”€ Request dispatched â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[orch] request (tool-enabled)')) return 'Planning...';
    if (l.contains('[orch] request (chat)')) return 'Reasoning...';

    // â”€â”€ Multi-agent role transitions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[agent:router')) return 'Routing task...';
    if (l.contains('[agent:shaper')) return 'Shaping plan...';
    if (l.contains('[agent:reasoner')) return 'Reasoning...';
    if (l.contains('[agent:executor')) return 'Executing tools...';

    // â”€â”€ Retry / recovery signals â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('retrying in tool mode')) return 'Switching to tools...';
    if (l.contains('malformed tool call detected')) return 'Correcting format...';
    if (l.contains('truncated tool call detected')) return 'Continuing tool call...';
    if (l.contains('truncated final answer detected')) return 'Continuing answer...';
    if (l.contains('refusal detected')) return 'Overcoming refusal...';
    if (l.contains('cliffhanger reply detected')) return 'Pushing to act...';

    // â”€â”€ Validation runs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('flutter_analyze')) return 'Analyzing Dart code...';
    if (l.contains('python_check')) return 'Checking Python syntax...';
    if (l.contains('python_lint')) return 'Linting Python...';
    if (l.contains('python_test')) return 'Running tests...';

    // â”€â”€ Synthesis / recap â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('synthesis succeeded')) return 'Summarizing...';
    if (l.contains('synthesis call failed')) return 'Summarizing...';
    if (l.contains('max iterations reached')) return 'Wrapping up...';
    if (l.contains('repeat-call cap reached')) return 'Wrapping up...';

    // â”€â”€ Progress / extension â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('progress detected')) return 'Making progress...';
    if (l.contains('complex multi-file')) return 'Working on multiple files...';

    // â”€â”€ Nudge / pressure â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('[nudge]')) return 'Nudging to act...';
    if (l.contains('[final warning]')) return 'Final push to act...';

    // â”€â”€ History trimming (noise â€” don't show) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('history trimmed')) return null;
    if (l.contains('history over token budget')) return null;

    // â”€â”€ Rate-limit / circuit-breaker (noise) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    if (l.contains('tpm limit')) return null;
    if (l.contains('transient error')) return null;
    if (l.contains('circuit breaker')) return null;

    return null;
  }

  static String? _extractAfter(String line, String prefix) {
    final idx = line.indexOf(prefix);
    if (idx == -1) return null;
    final after = line.substring(idx + prefix.length);
    // Tool calls look like: read_file(path='...', start_line=...)
    final paren = after.indexOf('(');
    if (paren == -1) return after.trim();
    return after.substring(0, paren).trim();
  }

  static String _labelForTool(String toolName) {
    switch (toolName) {
      case 'read_file':
        return 'Reading file...';
      case 'read_files':
        return 'Reading files...';
      case 'write_file':
        return 'Writing file...';
      case 'append_file':
        return 'Appending to file...';
      case 'patch_file':
        return 'Patching file...';
      case 'delete_file':
        return 'Deleting file...';
      case 'move_file':
        return 'Moving file...';
      case 'create_directory':
        return 'Creating directory...';
      case 'list_files':
        return 'Listing files...';
      case 'list_files_recursive':
        return 'Exploring project...';
      case 'search_in_files':
        return 'Searching code...';
      case 'find_files':
        return 'Finding files...';
      case 'run_command':
        return 'Running command...';
      case 'git_status':
        return 'Checking git status...';
      case 'git_diff':
        return 'Viewing git diff...';
      case 'git_log':
        return 'Reading git history...';
      case 'git_commit':
        return 'Committing changes...';
      case 'git_checkout':
        return 'Switching branch...';
      case 'git_branches':
        return 'Listing branches...';
      case 'flutter_analyze':
        return 'Analyzing Dart code...';
      case 'python_check':
        return 'Checking Python syntax...';
      case 'python_lint':
        return 'Linting Python...';
      case 'python_format':
        return 'Formatting Python...';
      case 'python_test':
        return 'Running tests...';
      case 'db_query':
        return 'Querying database...';
      default:
        return 'Working...';
    }
  }

  // Completes when the orchestrator prints `__READY__` on stdout.
  Completer<void>? _readyCompleter;

  // Queue of in-flight requests so sends are serialized on the stdin pipe.
  Future<String> _chain = Future.value('');

  // Per-request assembly state.
  Completer<String>? _activeCompleter;
  final List<String> _activeLines = [];

  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  // Inactivity watchdog for the currently active request.
  Timer? _inactivityTimer;
  DateTime? _requestStartedAt;
  String? _sessionKey;
  String? _basePath;

  /// The conversation id of the most recent prompt routed through this
  /// orchestrator. Used by the Team Mode UI to point the board viewer
  /// at the current chat's subfolder.
  String? get currentSessionKey => _sessionKey;

  bool get isRunning => _isRunning;
  bool get isReady => _isReady;
  OrchestratorBackend get currentBackend => _currentBackend;
  String? get currentModelId => _currentModelId;
  double? get currentTemperature => _currentTemperature;
  String get stderrLog => _stderrBuffer.toString();

  /// Platform-appropriate Python executable used as a fallback when the
  /// user has not configured an explicit interpreter in Settings â†’ Developer.
  static String get defaultPythonExecutable => Platform.isWindows ? 'python' : 'python3';

  /// Resolves the Python interpreter to launch the orchestrator with.
  /// Honours the user-configured override in SettingsRepository, otherwise
  /// falls back to the platform default (PATH lookup).
  static Future<String> resolvePythonExecutable() async {
    final configured = await SettingsRepository.instance.getPythonPath();
    if (configured != null && configured.trim().isNotEmpty) {
      return configured.trim();
    }
    return defaultPythonExecutable;
  }

  /// Builds the environment map handed to the orchestrator subprocess.
  /// Always sets `PYTHONDONTWRITEBYTECODE=1` so the bundled Python sources
  /// don't leave `__pycache__` directories scattered through the install â€”
  /// has to be in the env (not just sys.dont_write_bytecode) because the
  /// flag must be active before Python parses the entry script itself.
  /// Prepends `<flutterSdkPath>/bin` to `PATH` when the user has configured
  /// a Flutter SDK location, so `subprocess.run(["flutter", ...])` inside
  /// the Python tools resolves without requiring system-wide PATH setup.
  static Future<Map<String, String>> resolveSubprocessEnvironment() async {
    final base = <String, String>{
      ...Platform.environment,
      'PYTHONDONTWRITEBYTECODE': '1',
    };
    final flutterSdk = (await SettingsRepository.instance.getFlutterSdkPath())?.trim();
    if (flutterSdk == null || flutterSdk.isEmpty) return base;
    final flutterBin = '$flutterSdk${Platform.pathSeparator}bin';
    final currentPath = base['PATH'] ?? '';
    final sep = Platform.isWindows ? ';' : ':';
    return {
      ...base,
      'PATH': '$flutterBin$sep$currentPath',
      'FLUTTER_ROOT': flutterSdk,
    };
  }

  /// Resolve the orchestrator script path based on whether multi-agent mode is
  /// active. Single-agent mode uses the legacy `orchestrator.py`; multi-agent
  /// mode uses the new `orchestrator_v2.py`.
  static File _resolveScriptPath(bool multiAgent) {
    final scriptName = multiAgent ? 'orchestrator_multi.py' : 'orchestrator.py';
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/bin/$scriptName',
      '$cwd/$scriptName',
      '${Directory.current.parent.path}/bin/$scriptName',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (f.existsSync()) return f;
    }
    // Fall back to the first candidate (caller will surface the error).
    return File(candidates.first);
  }

  /// Directory the orchestrator is allowed to touch (its --base-path).
  /// Defaults to the project root so tools operate on the current project.
  static Directory get baseDirectory => Directory(ProjectService().currentPath);

  /// Install Python dependencies the orchestrator needs. Runs synchronously
  /// (streams output via [onLine] if provided) and returns true on success.
  Future<bool> installDependencies({void Function(String line)? onLine}) async {
    // Install deps for both the legacy single-agent orchestrator and the
    // new multi-agent orchestrator_v2, so the button works regardless of
    // which mode the user later switches to.
    final scripts = <File>[
      _resolveScriptPath(false),
      _resolveScriptPath(true),
    ];
    bool allOk = true;
    for (final script in scripts) {
      if (!script.existsSync()) {
        onLine?.call('Skipping ${script.path} (not found)');
        continue;
      }
      final python = await resolvePythonExecutable();
      onLine?.call('Running: $python ${script.path} --install-deps');
      try {
        final proc = await Process.start(
          python,
          [script.path, '--install-deps'],
          workingDirectory: script.parent.path,
        );
        final stdoutDone = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
        final stderrDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
        final exitCode = await proc.exitCode;
        await Future.wait([stdoutDone, stderrDone]);
        onLine?.call('Exit code: $exitCode');
        if (exitCode != 0) allOk = false;
      } catch (e) {
        onLine?.call('ERROR: $e');
        allOk = false;
      }
    }
    return allOk;
  }

  /// Install a single Python package via `python -m pip install <package>`.
  Future<bool> installPackage(
    String packageName, {
    void Function(String line)? onLine,
  }) async {
    final python = await resolvePythonExecutable();
    onLine?.call('Running: $python -m pip install --user $packageName');
    try {
      final proc = await Process.start(
        python,
        ['-m', 'pip', 'install', '--user', packageName],
      );

      final stdoutDone = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
      final stderrDone = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();

      final exitCode = await proc.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      onLine?.call('Exit code: $exitCode');
      return exitCode == 0;
    } catch (e) {
      onLine?.call('ERROR: $e');
      return false;
    }
  }

  /// Start the orchestrator subprocess. Returns false if it was already
  /// running or if launch failed.
  ///
  /// For [OrchestratorBackend.huggingface] (default), [hfToken] is required.
  /// For [OrchestratorBackend.ollama], [hfToken] is ignored and [modelId]
  /// must be an Ollama tag (e.g. `qwen2.5-coder:7b`). For
  /// [OrchestratorBackend.gemini], pass a Gemini model (e.g.
  /// `gemini-2.5-flash`) and a Google AI Studio key. Optional
  /// [ollamaBaseUrl] / [ollamaNumCtx] / [ollamaAutoNumCtx] are forwarded to the Python side.
  Future<bool> start({
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
    bool? ollamaAutoNumCtx,
    double? temperature,
    int? maxTokens,
    String? ollamaApiKey,
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    String? githubApiKey,
    int? tpmLimit,
    bool disableTools = false,
    bool? multiAgent,
  }) {
    if (_isRunning) return Future.value(false);
    // Coalesce: a second caller while the first is still awaiting __READY__
    // must NOT spawn a second subprocess. Return the in-flight future instead.
    final inflight = _startingFuture;
    if (inflight != null) return inflight;
    final fut = _startInternal(
      hfToken: hfToken,
      modelId: modelId,
      workingDirectory: workingDirectory,
      backend: backend,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaNumCtx: ollamaNumCtx,
      ollamaAutoNumCtx: ollamaAutoNumCtx,
      temperature: temperature,
      maxTokens: maxTokens,
      ollamaApiKey: ollamaApiKey,
      groqApiKey: groqApiKey,
      geminiApiKey: geminiApiKey,
      openRouterApiKey: openRouterApiKey,
      githubApiKey: githubApiKey,
      tpmLimit: tpmLimit,
      disableTools: disableTools,
      multiAgent: multiAgent,
    ).whenComplete(() => _startingFuture = null);
    _startingFuture = fut;
    return fut;
  }

  Future<bool> _startInternal({
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
    bool? ollamaAutoNumCtx,
    double? temperature,
    int? maxTokens,
    String? ollamaApiKey,
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    String? githubApiKey,
    int? tpmLimit,
    bool disableTools = false,
    bool? multiAgent,
  }) async {
    // When the caller doesn't override, honour the toggle the user set in the
    // Workflow Agents settings panel. This way every existing start-button
    // wiring flips into multi-agent mode automatically once the user enables
    // it, without each caller having to thread the flag through.
    final effectiveMultiAgent = multiAgent ?? await AgentRoleSettingsRepository.instance.isEnabled();
    final backendSettings = BackendSettingsRepository.instance;

    // Ollama cloud requires a Bearer key when talking directly to ollama.com.
    // Fill from persisted settings if the caller didn't pass explicit values.
    if (backend == OrchestratorBackend.ollama) {
      if (ollamaBaseUrl == null || ollamaBaseUrl.isEmpty) {
        ollamaBaseUrl = await backendSettings.getOllamaBaseUrl();
      }
      if (ollamaApiKey == null || ollamaApiKey.isEmpty) {
        ollamaApiKey = await backendSettings.getOllamaApiKey();
      }
    }

    // In multi-agent mode the agent config can reference any backend
    // regardless of the primary `backend` parameter. Auto-fill any missing
    // key from persistent settings so the Python `SecretsResolver` doesn't
    // crash with `<X> backend requires --<x>-api-key` when a role uses a
    // different provider than the primary one.
    if (effectiveMultiAgent) {
      if (hfToken == null || hfToken.isEmpty) {
        hfToken = await SettingsRepository.instance.getHfToken();
      }
      if (groqApiKey == null || groqApiKey.isEmpty) {
        groqApiKey = await backendSettings.getGroqApiKey();
      }
      if (geminiApiKey == null || geminiApiKey.isEmpty) {
        geminiApiKey = await backendSettings.getGeminiApiKey();
      }
      if (openRouterApiKey == null || openRouterApiKey.isEmpty) {
        openRouterApiKey = await backendSettings.getOpenRouterApiKey();
      }
      if (githubApiKey == null || githubApiKey.isEmpty) {
        githubApiKey = await backendSettings.getGithubApiKey();
      }
      if (ollamaApiKey == null || ollamaApiKey.isEmpty) {
        ollamaApiKey = await backendSettings.getOllamaApiKey();
      }
    }

    final script = _resolveScriptPath(effectiveMultiAgent);
    if (!script.existsSync()) {
      _appendLog('orchestrator script not found at ${script.path}');
      return false;
    }

    // Backend-specific key checks are now handled by the Python side;
    // missing keys will result in a clear error message from the orchestrator.

    try {
      _stderrBuffer.clear();
      _logLines.clear();
      _lastNonEmptyLogLine = null;
      _readyCompleter = Completer<void>();

      final resolvedBasePath = workingDirectory ?? baseDirectory.path;
      _basePath = resolvedBasePath;
      _appendLog('[manager] --base-path -> $resolvedBasePath');
      if (!ProjectService().hasExplicitFolder && workingDirectory == null) {
        _appendLog(
          '[manager] WARNING: no project folder selected; falling back to '
          'Directory.current ($resolvedBasePath). Pick a project folder from '
          'the chat input so file tools resolve relative paths against your '
          'project, not the app install directory.',
        );
      }
      final args = <String>[
        script.path,
        '--interactive',
        '--base-path',
        resolvedBasePath,
      ];

      // Build reasoner/summarizer args from multi-agent config or fallback to primary backend.
      if (effectiveMultiAgent) {
        final agents = await WorkflowAgents.load();
        final reasonerCfg = agents.get('reasoner');
        final summarizerCfg = agents.get('summarizer');

        final rProvider = _toProviderString(reasonerCfg.backend);
        final sProvider = _toProviderString(summarizerCfg.backend);

        args.addAll(['--reasoner-provider', rProvider]);
        args.addAll(['--reasoner-model', reasonerCfg.model]);
        args.addAll(['--temperature', reasonerCfg.temperature.toString()]);
        args.addAll(['--max-tokens', reasonerCfg.maxTokens.toString()]);
        final rKey = _apiKeyForProvider(rProvider,
            groqApiKey: groqApiKey, geminiApiKey: geminiApiKey, openRouterApiKey: openRouterApiKey, githubApiKey: githubApiKey, hfToken: hfToken, ollamaApiKey: ollamaApiKey);
        if (rKey != null && rKey.isNotEmpty) {
          args.addAll(['--reasoner-api-key', rKey]);
        }
        if (rProvider == 'ollama' && ollamaBaseUrl != null && ollamaBaseUrl.isNotEmpty) {
          args.addAll(['--reasoner-base-url', ollamaBaseUrl]);
        }

        // Reasoning level: pass through to the Python orchestrator.
        // Defaults to 'max' if not set in the agent config.
        final rReasoningLevel = reasonerCfg.reasoningLevel.isNotEmpty
            ? reasonerCfg.reasoningLevel
            : 'max';
        args.addAll(['--reasoning-level', rReasoningLevel]);

        args.addAll(['--summarizer-provider', sProvider]);
        args.addAll(['--summarizer-model', summarizerCfg.model]);
        final sKey = _apiKeyForProvider(sProvider,
            groqApiKey: groqApiKey, geminiApiKey: geminiApiKey, openRouterApiKey: openRouterApiKey, githubApiKey: githubApiKey, hfToken: hfToken, ollamaApiKey: ollamaApiKey);
        if (sKey != null && sKey.isNotEmpty) {
          args.addAll(['--summarizer-api-key', sKey]);
        }
        if (sProvider == 'ollama' && ollamaBaseUrl != null && ollamaBaseUrl.isNotEmpty) {
          args.addAll(['--summarizer-base-url', ollamaBaseUrl]);
        }

        // Team Mode is not yet supported by multi_mode; log a warning.
        if (await AgentRoleSettingsRepository.instance.isTeamModeEnabled()) {
          _appendLog('[manager] Team Mode is not supported by orchestrator_v2; ignoring.');
        }
      } else {
        // Single-agent mode: use the legacy orchestrator.py with its own flags.
        args.addAll(['--backend', _backendToString(backend)]);
        if (modelId != null && modelId.isNotEmpty) {
          args.addAll(['--model', modelId]);
        }
        // Fetch temperature from settings if not provided
        double effectiveTemperature = temperature ?? await _getDefaultTemperatureForBackend(backend);
        // Format temperature as a clean decimal (e.g., 0.30 instead of 0.30000000000000004)
        final formattedTemperature = double.parse(effectiveTemperature.toStringAsFixed(2));
        args.addAll(['--temperature', formattedTemperature.toString()]);
        if (maxTokens != null) {
          args.addAll(['--max-tokens', maxTokens.toString()]);
        }
        // Backend-specific keys
        switch (backend) {
          case OrchestratorBackend.huggingface:
            if (hfToken != null && hfToken.isNotEmpty) args.addAll(['--hf-token', hfToken]);
            break;
          case OrchestratorBackend.ollama:
            if (ollamaBaseUrl != null && ollamaBaseUrl.isNotEmpty) args.addAll(['--ollama-base-url', ollamaBaseUrl]);
            if (ollamaApiKey != null && ollamaApiKey.isNotEmpty) args.addAll(['--ollama-api-key', ollamaApiKey]);
            if (ollamaNumCtx != null) args.addAll(['--ollama-num-ctx', ollamaNumCtx.toString()]);
            if (ollamaAutoNumCtx == true) args.add('--auto-num-ctx');
            break;
          case OrchestratorBackend.groq:
            if (groqApiKey != null && groqApiKey.isNotEmpty) args.addAll(['--groq-api-key', groqApiKey]);
            break;
          case OrchestratorBackend.gemini:
            if (geminiApiKey != null && geminiApiKey.isNotEmpty) args.addAll(['--gemini-api-key', geminiApiKey]);
            break;
          case OrchestratorBackend.openrouter:
            if (openRouterApiKey != null && openRouterApiKey.isNotEmpty) args.addAll(['--openrouter-api-key', openRouterApiKey]);
            break;
          case OrchestratorBackend.github:
            if (githubApiKey != null && githubApiKey.isNotEmpty) args.addAll(['--github-api-key', githubApiKey]);
            break;
        }
        if (tpmLimit != null) args.addAll(['--tpm-limit', tpmLimit.toString()]);
      }

      if (disableTools) {
        args.add('--disable-tools');
      }

      // User-configured filesystem filters: list of dirs/files to hide
      // (or re-show) from the orchestrator's discovery tools. Written
      // alongside agents.json so the Python side can mmap a single file
      // at startup. Per-project: the lists are scoped to the current
      // working directory hash inside DevFiltersRepository.
      try {
        final tmp = await getTemporaryDirectory();
        final filtersPath = '${tmp.path}/agentic_filters.json';
        final filtersJson = await DevFiltersRepository.instance.toFiltersJson(resolvedBasePath);
        await File(filtersPath).writeAsString(filtersJson, flush: true);
        // Only attach the flag when the user has at least one rule
        // configured â€” empty config means "no filters" and Python's
        // default already covers that, no need for an extra arg.
        final hasAnyRule =
            !filtersJson.contains('"exclude_dirs":[]') || !filtersJson.contains('"include_dirs":[]') || !filtersJson.contains('"exclude_files":[]') || !filtersJson.contains('"include_files":[]');
        if (hasAnyRule) {
          args.addAll(['--filters-config', filtersPath]);
          _appendLog('[manager] Filesystem filters written -> $filtersPath');
        }
      } catch (e) {
        _appendLog('[manager] Failed to write filters config: $e (continuing without filters)');
      }

      // User-configured database connections (Settings â†’ Developer â†’
      // Database Connections). The Flutter UI persists these in the
      // app's SQLite settings table; we serialise the current snapshot
      // to a temp file and hand the path to Python so the db_query tool
      // can resolve a connection key the model passes in.
      try {
        final tmp = await getTemporaryDirectory();
        final dbConnPath = '${tmp.path}/agentic_db_connections.json';
        await DatabaseConnectionsRepository.instance.writeConfigJson(dbConnPath, workingDir: ProjectService().currentPath);
        args.addAll(['--db-connections-config', dbConnPath]);
        _appendLog('[manager] DB connections written -> $dbConnPath');
      } catch (e) {
        _appendLog('[manager] Failed to write DB connections config: $e (continuing without DB tool)');
      }

      final python = await resolvePythonExecutable();
      final env = await resolveSubprocessEnvironment();
      _appendLog('[manager] Python -> $python');
      final flutterRoot = env['FLUTTER_ROOT'];
      if (flutterRoot != null) {
        _appendLog('[manager] FLUTTER_ROOT -> $flutterRoot');
      }
      _process = await Process.start(
        python,
        args,
        workingDirectory: script.parent.path,
        environment: env,
      );

      _stdoutSub = _process!.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen(_onStdoutLine, onError: _onStreamError, onDone: _onProcessExited);

      _stderrSub = _process!.stderr.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
        _appendLog(line);
        // stderr activity (e.g. `[orch] Model reply (iter 0) â€¦`) counts as
        // a heartbeat â€” the subprocess is alive and making progress.
        _bumpInactivityTimer();
      });

      // Wait for the `__READY__` handshake. If the Python side is missing
      // dependencies it will exit with code 2 â€” we detect that via
      // _onProcessExited and complete the ready future with an error.
      // Multi-agent startup is heavier (loads + validates each role's
      // backend before signalling ready), so give it a longer budget.
      final readyTimeout = effectiveMultiAgent ? const Duration(seconds: 90) : const Duration(seconds: 30);
      await _readyCompleter!.future.timeout(readyTimeout);

      _isRunning = true;
      _isReady = true;
      _currentBackend = backend;
      _currentModelId = modelId;
      _currentTemperature = temperature;
      return true;
    } catch (e) {
      _appendLog('start() failed: $e');
      await _cleanup();
      return false;
    }
  }

  /// Send a prompt to the orchestrator and await the full response.
  ///
  /// [sessionKey] identifies the visible chat conversation. When it changes,
  /// or when [forceHistorySync] is true, the Python side is reset and
  /// re-seeded with [seedHistory] so hidden orchestrator memory cannot drift
  /// away from the visible chat history.
  Future<String> sendPrompt(
    String prompt, {
    bool newSession = false,
    String? sessionKey,
    List<Map<String, String>> seedHistory = const [],
    bool forceHistorySync = false,
    String taskMode = 'open',
    bool thinking = false,
    String? effort,
  }) {
    // Serialize requests so multiple callers don't interleave on stdin.
    final next = _chain.then(
      (_) => _sendPromptInternal(
        prompt,
        newSession,
        sessionKey: sessionKey,
        seedHistory: seedHistory,
        forceHistorySync: forceHistorySync,
        taskMode: taskMode,
        thinking: thinking,
        effort: effort,
      ),
    );
    _chain = next.catchError((_) => '');
    return next;
  }

  Future<String> _sendPromptInternal(
    String prompt,
    bool newSession, {
    String? sessionKey,
    List<Map<String, String>> seedHistory = const [],
    bool forceHistorySync = false,
    String taskMode = 'open',
    bool thinking = false,
    String? effort,
  }) async {
    if (!_isRunning || _process == null) {
      return 'Error: Orchestrator not running. Start it from Settings first.';
    }
    if (!_isReady) {
      return 'Error: Orchestrator not ready yet.';
    }

    final shouldResetSession = forceHistorySync || newSession || (sessionKey != null && sessionKey != _sessionKey);
    if (shouldResetSession) {
      _sessionKey = sessionKey;
    }

    _activeCompleter = Completer<String>();
    _activeLines.clear();
    _requestStartedAt = DateTime.now();
    // Stash the conversation id so the stdout dispatcher can attach it
    // to incoming task-flow events (Python doesn't re-echo it on every
    // event for the sake of payload size).
    _currentConversationId = sessionKey;
    _bumpInactivityTimer();

    final request = jsonEncode({
      'prompt': prompt,
      'new_session': shouldResetSession,
      if (seedHistory.isNotEmpty) 'history': seedHistory,
      if (sessionKey != null && sessionKey.isNotEmpty) 'session_key': sessionKey,
      // Sent explicitly so Team Mode can isolate per-chat board/artifacts.
      // Same value as session_key — kept as a separate field so the
      // Python side has a stable contract independent of the legacy
      // session_key plumbing.
      if (sessionKey != null && sessionKey.isNotEmpty) 'conversation_id': sessionKey,
      // Task-flow dropdown selection. Python looks at this on every
      // request and switches the system prompt + event emission in or
      // out of TASK COMPLIANCE mode accordingly.
      'task_mode': taskMode,
      // Thinking ON/OFF master switch + Effort level. Sent per-request
      // so the Flutter UI controls take effect immediately without
      // restarting the orchestrator subprocess.
      'thinking': thinking,
      if (effort != null && effort.isNotEmpty) 'effort': effort,
    });
    // Fix 10c: when the outgoing prompt is itself a <task_action>
    // envelope (sent by the TaskChecklistPanel buttons), inject a
    // synthetic log line so the orchestrator log panel shows the
    // user-driven action alongside the model-driven [task] lines.
    // Pattern: ``<task_action><id>N</id><action>value</action></task_action>``.
    final taskActionMatch = RegExp(
      r'<\s*task_action\s*>\s*(.*?)<\s*/\s*task_action\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(prompt);
    if (taskActionMatch != null) {
      final body = taskActionMatch.group(1) ?? '';
      _injectLogLine('[task-action-ui] sent $body');
    }

    try {
      _process!.stdin.writeln(request);
      await _process!.stdin.flush();
    } catch (e) {
      return 'Error: Failed to write to orchestrator stdin: $e';
    }

    // Inactivity-based timeout: the request is only cancelled if neither
    // stdout nor stderr has produced a line for `_kOrchestratorInactivityTimeout`,
    // capped by `_kOrchestratorAbsoluteTimeout`. Long-but-progressing tool
    // chains keep extending the deadline via `_bumpInactivityTimer`.
    try {
      return await _activeCompleter!.future.timeout(
        _kOrchestratorAbsoluteTimeout,
        onTimeout: () => 'Timeout: orchestrator exceeded the absolute ceiling of '
            '${_kOrchestratorAbsoluteTimeout.inMinutes} minutes.',
      );
    } finally {
      _activeCompleter = null;
      _activeLines.clear();
      _cancelInactivityTimer();
      _requestStartedAt = null;
    }
  }

  void _bumpInactivityTimer() {
    if (_activeCompleter == null) return;
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(_kOrchestratorInactivityTimeout, () {
      if (_activeCompleter == null || _activeCompleter!.isCompleted) return;
      // If a complete JSON envelope already landed (sentinel just hadn't
      // arrived), recover the parsed reply instead of clobbering it with a
      // timeout string.
      final recovered = _extractResponseFromBuffer();
      if (recovered.isNotEmpty && recovered != _activeLines.join('\n').trim()) {
        _activeCompleter!.complete(recovered);
        return;
      }
      final waited = _requestStartedAt == null ? 'unknown' : '${DateTime.now().difference(_requestStartedAt!).inSeconds}s';
      _activeCompleter!.complete(
        'Timeout: orchestrator was silent for '
        '${_kOrchestratorInactivityTimeout.inMinutes} minutes '
        '(total wait $waited). Check the orchestrator log.',
      );
    });
  }

  void _cancelInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
  }

  void _onStdoutLine(String line) {
    // Handshake: Python prints `__READY__` once at startup. A second one
    // means the subprocess respawned (crash + restart, or stop+start while
    // a request was in flight) â€” never legitimate request payload, so drop
    // it unconditionally rather than letting it leak into _activeLines.
    if (line.trim() == '__READY__') {
      if (!_isReady) _readyCompleter?.complete();
      return;
    }

    if (_activeCompleter == null) return; // Stray line; ignore.

    // Any stdout line during an active request is progress â†’ reset watchdog.
    _bumpInactivityTimer();

    if (line.trim() == '__RESPONSE_END__') {
      final response = _extractResponseFromBuffer();
      if (!_activeCompleter!.isCompleted) {
        _activeCompleter!.complete(response);
      }
      return;
    }

    // Task-flow event interception: lines that parse as an XML envelope
    // carrying a ``type`` child (e.g. ``<event><type>tasks_proposed</type>...</event>``
    // or ``<event><type>task_status</type>...</event>``) are NOT the
    // response envelope -- they are intermediate structured events emitted
    // by Python while running in TASK COMPLIANCE mode. Route them to
    // ``taskStream`` and mirror to SQLite via TaskRepository. The line is
    // then dropped from ``_activeLines`` so it never reaches the response
    // extractor.
    final maybeEvent = _tryParseTaskEvent(line);
    if (maybeEvent) {
      return;
    }

    _activeLines.add(line);
  }

  /// Reverse the XML character-reference escaping applied by Python's
  /// ``_escape_xml`` so the Flutter side sees the original text (newlines,
  /// ampersands, angle brackets) as the model intended.
  static String _unescapeXml(String value) {
    return value
        .replaceAll('&#10;', '\n')
        .replaceAll('&#13;', '\r')
        .replaceAll('&quot;', '"')
        .replaceAll('&gt;', '>')
        .replaceAll('&lt;', '<')
        .replaceAll('&amp;', '&');
  }

  /// Attempt to parse ``line`` as a task-flow XML envelope. Returns ``true``
  /// when the line was an event (and was therefore consumed); ``false``
  /// otherwise so the caller falls back to the normal response buffer.
  bool _tryParseTaskEvent(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('<event>')) return false;

    // Extract the direct children of the <event> wrapper; we must not
    // match nested <task> tags at the same level or the outer <event>
    // tag itself would overwrite every key.
    final eventMatch = RegExp(
      r'<\s*event\s*>\s*(.*?)\s*<\s*/\s*event\s*>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(trimmed);
    if (eventMatch == null) return false;
    final eventBody = eventMatch.group(1)!;

    // Same convention as the Python side: <tag>value</tag>, no attributes.
    final childTagRe = RegExp(
      r'<\s*(\w+)\s*>\s*(.*?)\s*<\s*/\s*\1\s*>',
      caseSensitive: false,
      dotAll: true,
    );
    final tags = <String, String>{};
    for (final m in childTagRe.allMatches(eventBody)) {
      tags[m.group(1)!.toLowerCase()] = _unescapeXml(m.group(2)!);
    }

    final eventType = tags['type'];
    if (eventType == null) return false;

    final convId = _currentConversationId;
    if (convId == null || convId.isEmpty) {
      // Without a conversation context we can't persist or attach the
      // event meaningfully. Treat as consumed to avoid leaking it into
      // the response buffer but skip the broadcast.
      return true;
    }

    final now = DateTime.now().millisecondsSinceEpoch;

    if (eventType == 'tasks_proposed') {
      // The payload is nested inside <tasks>...</tasks>.
      final tasks = <ConversationTask>[];
      final tasksMatch = RegExp(
        r'<\s*tasks\s*>(.*?)<\s*/\s*tasks\s*>',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(trimmed);
      if (tasksMatch != null) {
        final taskBlock = tasksMatch.group(1)!;
        final taskRe = RegExp(
          r'<\s*task\s*>(.*?)<\s*/\s*task\s*>',
          caseSensitive: false,
          dotAll: true,
        );
        for (final tm in taskRe.allMatches(taskBlock)) {
          final taskTags = <String, String>{};
          for (final m in childTagRe.allMatches(tm.group(1)!)) {
            taskTags[m.group(1)!.toLowerCase()] = m.group(2)!;
          }
          if (taskTags['id'] == null || taskTags['name'] == null) continue;
          final deps = <int>[];
          final dependsRaw = taskTags['depends_on'];
          if (dependsRaw != null && dependsRaw.trim().isNotEmpty) {
            for (final part in dependsRaw.split(',')) {
              final n = int.tryParse(part.trim());
              if (n != null) deps.add(n);
            }
          }
          tasks.add(
            ConversationTask(
              taskId: int.tryParse(taskTags['id']!) ?? 0,
              conversationId: convId,
              name: taskTags['name']!,
              description: taskTags['description'] ?? '',
              successCriteria: taskTags['success_criteria'] ?? '',
              dependsOn: deps,
              status: TaskStatusX.parse(taskTags['status']),
              createdAt: now,
              updatedAt: now,
            ),
          );
        }
      }
      // Persist + broadcast.
      TaskRepository.instance.replacePlan(convId, tasks);
      _taskController.add(
        OrchestratorTasksProposed(conversationId: convId, tasks: tasks),
      );
      return true;
    }

    if (eventType == 'task_status') {
      final id = int.tryParse(tags['id'] ?? '');
      final statusRaw = tags['status'];
      if (id == null || statusRaw == null) return true;
      final status = TaskStatusX.parse(statusRaw);
      final note = tags['note'] ?? '';
      final description = tags['description'] ?? '';
      TaskRepository.instance.applyStatusUpdate(
        conversationId: convId,
        taskId: id,
        status: status,
        note: note,
        now: now,
      );
      _taskController.add(
        OrchestratorTaskStatusChanged(
          conversationId: convId,
          taskId: id,
          status: status,
          note: note,
          description: description,
        ),
      );
      return true;
    }

    // Unknown event types are silently consumed -- forwards
    // compatibility with future protocol extensions.
    return true;
  }

  /// Pull a clean user-facing reply out of `_activeLines`. Handles the normal
  /// case (`{"response": "...", "trace": [...]}`) and tolerates stray lines
  /// like a leftover `__READY__` from a respawn or stray Python prints that
  /// landed on stdout instead of stderr. Also publishes the trace when
  /// present.
  ///
  /// Strategy: scan from the end for the last line that parses as a JSON
  /// object containing a `"response"` key. That envelope is authoritative â€”
  /// anything before it is treated as noise and discarded. Falls back to the
  /// joined text only if no such envelope exists.
  String _extractResponseFromBuffer() {
    final cleaned = _activeLines.where((l) => l.trim() != '__READY__').toList();

    for (var i = cleaned.length - 1; i >= 0; i--) {
      final line = cleaned[i].trim();
      if (!line.startsWith('{') || !line.endsWith('}')) continue;
      try {
        final obj = jsonDecode(line);
        if (obj is! Map || obj['response'] is! String) continue;
        final rawTrace = obj['trace'];
        if (rawTrace is List) {
          final entries = <Map<String, Object?>>[];
          for (final e in rawTrace) {
            if (e is Map) {
              entries.add(e.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
          _lastTrace = entries;
          if (!_traceController.isClosed) _traceController.add(entries);
        } else {
          _lastTrace = const [];
        }
        return obj['response'] as String;
      } catch (_) {
        // Not parseable â€” keep scanning earlier lines.
      }
    }

    _lastTrace = const [];
    return cleaned.join('\n').trim();
  }

  void _onStreamError(Object error) {
    _appendLog('stdout stream error: $error');
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      _activeCompleter!.completeError(error);
    }
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(error);
    }
  }

  void _onProcessExited() {
    _isRunning = false;
    _isReady = false;
    _sessionKey = null;
    _cancelInactivityTimer();
    if (_readyCompleter != null && !_readyCompleter!.isCompleted) {
      _readyCompleter!.completeError(
        StateError('Orchestrator process exited before signalling ready. '
            'stderr: ${_stderrBuffer.toString()}'),
      );
    }
    if (_activeCompleter != null && !_activeCompleter!.isCompleted) {
      // If the JSON envelope already arrived before the process died, prefer
      // delivering the real reply over the generic "process exited" error.
      final recovered = _extractResponseFromBuffer();
      if (recovered.isNotEmpty && recovered.startsWith('{') == false) {
        _activeCompleter!.complete(recovered);
      } else {
        _activeCompleter!.complete(
          'Error: orchestrator process exited. stderr: ${_stderrBuffer.toString()}',
        );
      }
    }
  }

  /// Stop the orchestrator subprocess.
  Future<void> stop() async {
    await _cleanup();
  }

  Future<void> _cleanup() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
    _isRunning = false;
    _isReady = false;
    _sessionKey = null;
  }

  bool checkHealthy() => _isRunning && _isReady && _process != null;

  // ---------------------------------------------------------------------------
  // Helpers for building orchestrator_v2 CLI args
  // ---------------------------------------------------------------------------

  /// Map an [OrchestratorBackend] to the provider string expected by
  /// orchestrator_v2 (e.g. "openai", "anthropic", "ollama", "gemini",
  /// "openrouter", "github").
  static String _backendToString(OrchestratorBackend b) {
    switch (b) {
      case OrchestratorBackend.huggingface:
        return 'huggingface';
      case OrchestratorBackend.ollama:
        return 'ollama';
      case OrchestratorBackend.groq:
        return 'groq';
      case OrchestratorBackend.gemini:
        return 'gemini';
      case OrchestratorBackend.openrouter:
        return 'openrouter';
      case OrchestratorBackend.github:
        return 'github';
    }
  }

  /// Map a backend identifier string (from [WorkflowAgentConfig.backend] or
  /// [_backendToString]) to the canonical provider name used by
  /// orchestrator_v2's `--reasoner-provider` / `--summarizer-provider` flags.
  static String _toProviderString(String backend) {
    switch (backend) {
      case 'huggingface':
        return 'openai'; // HF router uses OpenAI-compatible endpoint
      case 'ollama':
        return 'ollama';
      case 'groq':
        return 'groq';
      case 'gemini':
        return 'gemini';
      case 'openrouter':
        return 'openrouter';
      case 'github':
        return 'github';
      default:
        return backend; // pass through unknown values
    }
  }

  /// Return the API key for a given provider string, drawing from the
  /// appropriate parameter.
  static String? _apiKeyForProvider(
    String provider, {
    String? groqApiKey,
    String? geminiApiKey,
    String? openRouterApiKey,
    String? githubApiKey,
    String? hfToken,
    String? ollamaApiKey,
  }) {
    switch (provider) {
      case 'groq':
        return groqApiKey;
      case 'gemini':
        return geminiApiKey;
      case 'openrouter':
        return openRouterApiKey;
      case 'github':
        return githubApiKey;
      case 'openai':
      case 'huggingface':
        return hfToken;
      case 'ollama':
        return ollamaApiKey;
      default:
        return null;
    }
  }
}

  /// Returns the default temperature for the given backend from BackendSettingsRepository.
  Future<double> _getDefaultTemperatureForBackend(OrchestratorBackend backend) async {
    final backendSettings = BackendSettingsRepository.instance;
    switch (backend) {
      case OrchestratorBackend.huggingface:
        return await backendSettings.getHuggingFaceTemperature();
      case OrchestratorBackend.ollama:
        return await backendSettings.getOllamaTemperature();
      case OrchestratorBackend.groq:
        return await backendSettings.getGroqTemperature();
      case OrchestratorBackend.gemini:
        return await backendSettings.getGeminiTemperature();
      case OrchestratorBackend.openrouter:
        return await backendSettings.getOpenRouterTemperature();
      case OrchestratorBackend.github:
        return await backendSettings.getGitHubTemperature();
      // Fallback for unknown backends
    }
  }
