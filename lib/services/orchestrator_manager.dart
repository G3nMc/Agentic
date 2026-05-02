import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agentic/services/project_service.dart';
import 'package:path_provider/path_provider.dart';

import '../data/repositories/agent_role_settings_repository.dart';
import '../data/repositories/backend_settings_repository.dart';
import '../data/repositories/dev_filters_repository.dart';
import '../data/repositories/settings_repository.dart';

// Inactivity timeout: if the orchestrator emits no output on stdout OR
// stderr for this long, we assume it's wedged and give up. Activity
// (including per-chunk heartbeat lines from the Python streaming loops)
// resets it. 10 min gives slow local models (phi3:mini on CPU) enough
// headroom while still catching a truly wedged process.
const Duration _kOrchestratorInactivityTimeout = Duration(minutes: 10);

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
  final StringBuffer _stderrBuffer = StringBuffer();

  // ── Live log stream ────────────────────────────────────────────────────────
  // A broadcast StreamController so multiple widgets can subscribe
  // simultaneously without causing "already subscribed" errors.
  final StreamController<String> _logController = StreamController<String>.broadcast();

  // ── Multi-agent execution-trace stream ─────────────────────────────────────
  // Each entry is one agent activation. Only fires when the orchestrator was
  // launched with `multiAgent: true` and Python actually returned a `trace`
  // array in its response payload. Single-agent mode leaves this idle.
  final StreamController<List<Map<String, Object?>>> _traceController =
      StreamController<List<Map<String, Object?>>>.broadcast();
  Stream<List<Map<String, Object?>>> get traceStream => _traceController.stream;
  List<Map<String, Object?>> _lastTrace = const [];
  List<Map<String, Object?>> get lastTrace => List.unmodifiable(_lastTrace);

  /// Live stream of orchestrator log lines (stderr of the subprocess).
  /// Each event is a single trimmed line such as
  ///   "[orch] Groq streaming 'llama-3.3-70b-versatile' (42 chars)..."
  Stream<String> get logStream => _logController.stream;

  /// Rolling in-memory buffer of the most recent [_kMaxLogLines] lines.
  /// Useful for widgets that appear after the process has already emitted
  /// output (they can populate themselves from this list on first build).
  static const int _kMaxLogLines = 200;
  final List<String> _logLines = [];
  List<String> get logLines => List.unmodifiable(_logLines);

  void _appendLog(String line) {
    _stderrBuffer.writeln(line);
    // Empty lines are pure heartbeat signals from the Python streaming loop.
    // They still bump the inactivity watchdog (the listener calls
    // _bumpInactivityTimer unconditionally) but we don't show them in the
    // visible log so they don't scroll meaningful output off screen.
    if (line.trim().isEmpty) return;
    _logLines.add(line);
    if (_logLines.length > _kMaxLogLines) _logLines.removeAt(0);
    if (!_logController.isClosed) _logController.add(line);
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

  /// The conversation id of the most recent prompt routed through this
  /// orchestrator. Used by the Team Mode UI to point the board viewer
  /// at the current chat's subfolder.
  String? get currentSessionKey => _sessionKey;

  bool get isRunning => _isRunning;
  bool get isReady => _isReady;
  OrchestratorBackend get currentBackend => _currentBackend;
  String get stderrLog => _stderrBuffer.toString();

  /// Platform-appropriate Python executable used as a fallback when the
  /// user has not configured an explicit interpreter in Settings → Developer.
  static String get defaultPythonExecutable =>
      Platform.isWindows ? 'python' : 'python3';

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
  /// don't leave `__pycache__` directories scattered through the install —
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
    final flutterSdk =
        (await SettingsRepository.instance.getFlutterSdkPath())?.trim();
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

  /// Absolute path to the bundled `bin/orchestrator.py` shipped with the app.
  /// Resolves relative to the current working directory because Flutter desktop
  /// is usually launched from the project root.
  static File get orchestratorScript {
    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/bin/orchestrator.py',
      '$cwd/orchestrator.py',
      '${Directory.current.parent.path}/bin/orchestrator.py',
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
    final script = orchestratorScript;
    if (!script.existsSync()) {
      onLine?.call('ERROR: orchestrator.py not found at ${script.path}');
      return false;
    }

    final python = await resolvePythonExecutable();
    onLine?.call('Running: $python ${script.path} --install-deps');
    try {
      final proc = await Process.start(
        python,
        [script.path, '--install-deps'],
        workingDirectory: script.parent.path,
      );

      final stdoutDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
      final stderrDone = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();

      final exitCode = await proc.exitCode;
      await Future.wait([stdoutDone, stderrDone]);
      onLine?.call('Exit code: $exitCode');
      return exitCode == 0;
    } catch (e) {
      onLine?.call('ERROR: $e');
      return false;
    }
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

      final stdoutDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();
      final stderrDone = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) => onLine?.call(l)).asFuture<void>();

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
  /// [ollamaBaseUrl] / [ollamaNumCtx] are forwarded to the Python side.
  Future<bool> start({
    String? hfToken,
    String? modelId,
    String? workingDirectory,
    OrchestratorBackend backend = OrchestratorBackend.huggingface,
    String? ollamaBaseUrl,
    int? ollamaNumCtx,
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
    final effectiveMultiAgent =
        multiAgent ?? await AgentRoleSettingsRepository.instance.isEnabled();

    // In multi-agent mode the agent config can reference any backend
    // regardless of the primary `backend` parameter. Auto-fill any missing
    // key from persistent settings so the Python `SecretsResolver` doesn't
    // crash with `<X> backend requires --<x>-api-key` when a role uses a
    // different provider than the primary one.
    if (effectiveMultiAgent) {
      final backendSettings = BackendSettingsRepository.instance;
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

    final script = orchestratorScript;
    if (!script.existsSync()) {
      _appendLog('orchestrator.py not found at ${script.path}');
      return false;
    }

    if (backend == OrchestratorBackend.huggingface && (hfToken == null || hfToken.isEmpty)) {
      _appendLog(
        'HF orchestrator backend requires a token but none was provided.',
      );
      return false;
    }
    final envGroqKey = Platform.environment['GROQ_API_KEY'] ?? '';
    if (backend == OrchestratorBackend.groq && (groqApiKey == null || groqApiKey.isEmpty) && envGroqKey.isEmpty) {
      _appendLog(
        'Groq orchestrator backend requires an API key but none was provided.',
      );
      return false;
    }
    final envGeminiKey = Platform.environment['GOOGLE_API_KEY'] ?? Platform.environment['GEMINI_API_KEY'] ?? '';
    if (backend == OrchestratorBackend.gemini && (geminiApiKey == null || geminiApiKey.isEmpty) && envGeminiKey.isEmpty) {
      _appendLog(
        'Gemini orchestrator backend requires an API key but none was provided.',
      );
      return false;
    }
    final envOpenRouterKey = Platform.environment['OPENROUTER_API_KEY'] ?? '';
    if (backend == OrchestratorBackend.openrouter && (openRouterApiKey == null || openRouterApiKey.isEmpty) && envOpenRouterKey.isEmpty) {
      _appendLog(
        'OpenRouter orchestrator backend requires an API key but none was provided.',
      );
      return false;
    }
    final envGithubKey = Platform.environment['GITHUB_TOKEN'] ?? Platform.environment['GITHUB_API_KEY'] ?? '';
    if (backend == OrchestratorBackend.github && (githubApiKey == null || githubApiKey.isEmpty) && envGithubKey.isEmpty) {
      _appendLog(
        'GitHub Models orchestrator backend requires a PAT but none was provided.',
      );
      return false;
    }

    try {
      _stderrBuffer.clear();
      _logLines.clear();
      _readyCompleter = Completer<void>();

      final resolvedBasePath = workingDirectory ?? baseDirectory.path;
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
      switch (backend) {
        case OrchestratorBackend.huggingface:
          args.addAll(['--backend', 'huggingface']);
          break;
        case OrchestratorBackend.ollama:
          args.addAll(['--backend', 'ollama']);
          if (ollamaBaseUrl != null && ollamaBaseUrl.isNotEmpty) {
            args.addAll(['--ollama-base-url', ollamaBaseUrl]);
          }
          if (ollamaNumCtx != null) {
            args.addAll(['--ollama-num-ctx', '$ollamaNumCtx']);
          }
          break;
        case OrchestratorBackend.groq:
          args.addAll(['--backend', 'groq']);
          break;
        case OrchestratorBackend.gemini:
          args.addAll(['--backend', 'gemini']);
          break;
        case OrchestratorBackend.openrouter:
          args.addAll(['--backend', 'openrouter']);
          break;
        case OrchestratorBackend.github:
          args.addAll(['--backend', 'github']);
          break;
      }

      // Pass all available keys to support multi-agent workflows where roles use different backends.
      if (hfToken != null && hfToken.isNotEmpty) args.addAll(['--hf-token', hfToken]);
      final finalGroqKey = groqApiKey ?? envGroqKey;
      if (finalGroqKey.isNotEmpty) args.addAll(['--groq-api-key', finalGroqKey]);
      final finalGeminiKey = geminiApiKey ?? envGeminiKey;
      if (finalGeminiKey.isNotEmpty) args.addAll(['--gemini-api-key', finalGeminiKey]);
      final finalOpenRouterKey = openRouterApiKey ?? envOpenRouterKey;
      if (finalOpenRouterKey.isNotEmpty) args.addAll(['--openrouter-api-key', finalOpenRouterKey]);
      final finalGithubKey = githubApiKey ?? envGithubKey;
      if (finalGithubKey.isNotEmpty) args.addAll(['--github-api-key', finalGithubKey]);
      if (modelId != null && modelId.isNotEmpty) {
        args.addAll(['--model', modelId]);
      }
      if (temperature != null) {
        args.addAll(['--temperature', temperature.toString()]);
      }
      if (maxTokens != null) {
        args.addAll(['--max-tokens', maxTokens.toString()]);
      }
      if (ollamaApiKey != null && ollamaApiKey.isNotEmpty) {
        args.addAll(['--ollama-api-key', ollamaApiKey]);
      }
      if (tpmLimit != null && tpmLimit > 0) {
        args.addAll(['--tpm-limit', tpmLimit.toString()]);
      }
      if (disableTools) {
        args.add('--disable-tools');
      }

      // Multi-agent mode: persist the per-role assignments to a JSON file
      // (in the app's temp dir) and tell Python where to find it. The single
      // --backend flag still travels along to provide the API keys / fallback,
      // but the workflow itself is built from agents.json.
      if (effectiveMultiAgent) {
        try {
          final tmp = await getTemporaryDirectory();
          final cfgPath = '${tmp.path}/agentic_agents.json';
          await AgentRoleSettingsRepository.instance
              .writeAgentConfigJson(cfgPath);
          args.addAll(['--multi-agent', '--agent-config', cfgPath]);
          _appendLog('[manager] Multi-agent config written -> $cfgPath');

          // Team Mode rides on top of multi-agent: each worker subprocess
          // boots its own Workflow from the same agents.json. The host
          // process drives the leader and the sequential worker chain.
          if (await AgentRoleSettingsRepository.instance.isTeamModeEnabled()) {
            args.add('--team-mode');
            _appendLog('[manager] Team Mode enabled — workers will run sequentially.');
          }
        } catch (e) {
          _appendLog('[manager] Failed to write agents.json: $e');
          return false;
        }
      }

      // User-configured filesystem filters: list of dirs/files to hide
      // (or re-show) from the orchestrator's discovery tools. Written
      // alongside agents.json so the Python side can mmap a single file
      // at startup. Per-project: the lists are scoped to the current
      // working directory hash inside DevFiltersRepository.
      try {
        final tmp = await getTemporaryDirectory();
        final filtersPath = '${tmp.path}/agentic_filters.json';
        final filtersJson = await DevFiltersRepository.instance
            .toFiltersJson(resolvedBasePath);
        await File(filtersPath).writeAsString(filtersJson, flush: true);
        // Only attach the flag when the user has at least one rule
        // configured — empty config means "no filters" and Python's
        // default already covers that, no need for an extra arg.
        final hasAnyRule = !filtersJson.contains('"exclude_dirs":[]') ||
            !filtersJson.contains('"include_dirs":[]') ||
            !filtersJson.contains('"exclude_files":[]') ||
            !filtersJson.contains('"include_files":[]');
        if (hasAnyRule) {
          args.addAll(['--filters-config', filtersPath]);
          _appendLog('[manager] Filesystem filters written -> $filtersPath');
        }
      } catch (e) {
        _appendLog('[manager] Failed to write filters config: $e (continuing without filters)');
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

      _stdoutSub = _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onStdoutLine, onError: _onStreamError, onDone: _onProcessExited);

      _stderrSub = _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        _appendLog(line);
        // stderr activity (e.g. `[orch] Model reply (iter 0) …`) counts as
        // a heartbeat — the subprocess is alive and making progress.
        _bumpInactivityTimer();
      });

      // Wait for the `__READY__` handshake. If the Python side is missing
      // dependencies it will exit with code 2 — we detect that via
      // _onProcessExited and complete the ready future with an error.
      // Multi-agent startup is heavier (loads + validates each role's
      // backend before signalling ready), so give it a longer budget.
      final readyTimeout = effectiveMultiAgent
          ? const Duration(seconds: 90)
          : const Duration(seconds: 30);
      await _readyCompleter!.future.timeout(readyTimeout);

      _isRunning = true;
      _isReady = true;
      _currentBackend = backend;
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
  /// the Python side is reset and optionally re-seeded with [seedHistory] so
  /// switching chats does not leak hidden state across conversations.
  Future<String> sendPrompt(
    String prompt, {
    bool newSession = false,
    String? sessionKey,
    List<Map<String, String>> seedHistory = const [],
  }) {
    // Serialize requests so multiple callers don't interleave on stdin.
    final next = _chain.then(
      (_) => _sendPromptInternal(
        prompt,
        newSession,
        sessionKey: sessionKey,
        seedHistory: seedHistory,
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
  }) async {
    if (!_isRunning || _process == null) {
      return 'Error: Orchestrator not running. Start it from Settings first.';
    }
    if (!_isReady) {
      return 'Error: Orchestrator not ready yet.';
    }

    final shouldResetSession = newSession || (sessionKey != null && sessionKey != _sessionKey);
    if (shouldResetSession) {
      _sessionKey = sessionKey;
    }

    _activeCompleter = Completer<String>();
    _activeLines.clear();
    _requestStartedAt = DateTime.now();
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
    });
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
    // a request was in flight) — never legitimate request payload, so drop
    // it unconditionally rather than letting it leak into _activeLines.
    if (line.trim() == '__READY__') {
      if (!_isReady) _readyCompleter?.complete();
      return;
    }

    if (_activeCompleter == null) return; // Stray line; ignore.

    // Any stdout line during an active request is progress → reset watchdog.
    _bumpInactivityTimer();

    if (line.trim() == '__RESPONSE_END__') {
      final response = _extractResponseFromBuffer();
      if (!_activeCompleter!.isCompleted) {
        _activeCompleter!.complete(response);
      }
      return;
    }

    _activeLines.add(line);
  }

  /// Pull a clean user-facing reply out of `_activeLines`. Handles the normal
  /// case (`{"response": "...", "trace": [...]}`) and tolerates stray lines
  /// like a leftover `__READY__` from a respawn. Also publishes the trace
  /// when present.
  String _extractResponseFromBuffer() {
    final cleaned = _activeLines
        .where((l) => l.trim() != '__READY__')
        .toList();
    final joined = cleaned.join('\n').trim();
    if (!joined.startsWith('{')) {
      _lastTrace = const [];
      return joined;
    }
    try {
      final obj = jsonDecode(joined);
      if (obj is Map) {
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
        if (obj['response'] is String) {
          return obj['response'] as String;
        }
      }
    } catch (_) {
      // Not JSON — fall through.
    }
    return joined;
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
}
