import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Inactivity timeout: if the orchestrator emits no output on stdout OR
// stderr for this long, we assume it's wedged and give up. Activity
// (including `[orch] Model reply …` heartbeats from Python) resets it.
const Duration _kOrchestratorInactivityTimeout = Duration(minutes: 3);

// Absolute ceiling: even if the orchestrator keeps heart-beating, refuse to
// wait longer than this for a single prompt. Prevents runaway tool chains.
const Duration _kOrchestratorAbsoluteTimeout = Duration(minutes: 20);

/// Which model backend the orchestrator subprocess should use.
///
/// The orchestrator's tool protocol is backend-agnostic; this only decides
/// who actually runs inference. [huggingface] hits the HF router (needs a
/// token), [ollama] hits a local Ollama daemon (needs the daemon running).
enum OrchestratorBackend { huggingface, ollama, groq }

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
  OrchestratorBackend _currentBackend = OrchestratorBackend.huggingface;
  final StringBuffer _stderrBuffer = StringBuffer();

  // ── Live log stream ────────────────────────────────────────────────────────
  // A broadcast StreamController so multiple widgets can subscribe
  // simultaneously without causing "already subscribed" errors.
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

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

  bool get isRunning => _isRunning;
  bool get isReady => _isReady;
  OrchestratorBackend get currentBackend => _currentBackend;
  String get stderrLog => _stderrBuffer.toString();

  /// Platform-appropriate Python executable. Windows ships with `python`;
  /// most Linux/macOS systems expose `python3`.
  static String get pythonExecutable => Platform.isWindows ? 'python' : 'python3';

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
  static Directory get baseDirectory => Directory.current;

  /// Install Python dependencies the orchestrator needs. Runs synchronously
  /// (streams output via [onLine] if provided) and returns true on success.
  Future<bool> installDependencies({void Function(String line)? onLine}) async {
    final script = orchestratorScript;
    if (!script.existsSync()) {
      onLine?.call('ERROR: orchestrator.py not found at ${script.path}');
      return false;
    }

    onLine?.call('Running: $pythonExecutable ${script.path} --install-deps');
    try {
      final proc = await Process.start(
        pythonExecutable,
        [script.path, '--install-deps'],
        workingDirectory: script.parent.path,
      );

      final stdoutDone = proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => onLine?.call(l))
          .asFuture<void>();
      final stderrDone = proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((l) => onLine?.call(l))
          .asFuture<void>();

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
  /// must be an Ollama tag (e.g. `qwen2.5-coder:7b`). Optional
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
  }) async {
    if (_isRunning) return false;

    final script = orchestratorScript;
    if (!script.existsSync()) {
      _appendLog('orchestrator.py not found at ${script.path}');
      return false;
    }

    if (backend == OrchestratorBackend.huggingface &&
        (hfToken == null || hfToken.isEmpty)) {
      _appendLog(
        'HF orchestrator backend requires a token but none was provided.',
      );
      return false;
    }
    if (backend == OrchestratorBackend.groq &&
        (groqApiKey == null || groqApiKey.isEmpty)) {
      _appendLog(
        'Groq orchestrator backend requires an API key but none was provided.',
      );
      return false;
    }

    try {
      _stderrBuffer.clear();
      _logLines.clear();
      _readyCompleter = Completer<void>();

      final args = <String>[
        script.path,
        '--interactive',
        '--base-path', workingDirectory ?? baseDirectory.path,
      ];
      switch (backend) {
        case OrchestratorBackend.huggingface:
          args.addAll(['--backend', 'huggingface', '--hf-token', hfToken!]);
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
          args.addAll(['--backend', 'groq', '--groq-api-key', groqApiKey!]);
          break;
      }
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

      _process = await Process.start(
        pythonExecutable,
        args,
        workingDirectory: script.parent.path,
      );

      _stdoutSub = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onStdoutLine, onError: _onStreamError, onDone: _onProcessExited);

      _stderrSub = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _appendLog(line);
        // stderr activity (e.g. `[orch] Model reply (iter 0) …`) counts as
        // a heartbeat — the subprocess is alive and making progress.
        _bumpInactivityTimer();
      });

      // Wait up to 30s for the `__READY__` handshake. If the Python side
      // is missing dependencies it will exit with code 2 — we detect that
      // via _onProcessExited and complete the ready future with an error.
      await _readyCompleter!.future.timeout(const Duration(seconds: 30));

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

    final shouldResetSession =
        newSession || (sessionKey != null && sessionKey != _sessionKey);
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
        onTimeout: () =>
            'Timeout: orchestrator exceeded the absolute ceiling of '
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
      final waited = _requestStartedAt == null
          ? 'unknown'
          : '${DateTime.now().difference(_requestStartedAt!).inSeconds}s';
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
    // Handshake: Python prints `__READY__` exactly once at startup.
    if (!_isReady && line.trim() == '__READY__') {
      _readyCompleter?.complete();
      return;
    }

    if (_activeCompleter == null) return; // Stray line; ignore.

    // Any stdout line during an active request is progress → reset watchdog.
    _bumpInactivityTimer();

    if (line.trim() == '__RESPONSE_END__') {
      final joined = _activeLines.join('\n').trim();
      String response = joined;
      // Orchestrator wraps the response in {"response": "..."} so embedded
      // newlines survive the line-oriented protocol.
      if (joined.startsWith('{')) {
        try {
          final obj = jsonDecode(joined);
          if (obj is Map && obj['response'] is String) {
            response = obj['response'] as String;
          }
        } catch (_) {
          // Not JSON — treat as raw text.
        }
      }
      if (!_activeCompleter!.isCompleted) {
        _activeCompleter!.complete(response);
      }
      return;
    }

    _activeLines.add(line);
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
      _activeCompleter!.complete(
        'Error: orchestrator process exited. stderr: ${_stderrBuffer.toString()}',
      );
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
