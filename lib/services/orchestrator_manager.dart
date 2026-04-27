import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hf_chat_flutter/services/project_service.dart';
import 'package:path_provider/path_provider.dart';

import '../data/repositories/agent_role_settings_repository.dart';
import '../data/repositories/backend_settings_repository.dart';
import '../data/repositories/settings_repository.dart';

// Inactivity timeout: if the orchestrator emits no output on stdout OR
// stderr for this long, we assume it's wedged and give up. Activity
// (including per-chunk heartbeat lines from the Python streaming loops)
// resets it. 10 min gives slow local models (phi3:mini on CPU) enough
// headroom while still catching a truly wedged process.
const Duration _kOrchestratorInactivityTimeout = Duration(minutes: 10);

// Absolute ceiling: even if the orchestrator keeps heart-beating, refuse to
// wait longer than this for a single prompt. Prevents runaway tool chains.
const Duration _kOrchestratorAbsoluteTimeout = Duration(minutes: 20);

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
  static Directory get baseDirectory => Directory(ProjectService().currentPath);

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
    onLine?.call('Running: $pythonExecutable -m pip install --user $packageName');
    try {
      final proc = await Process.start(
        pythonExecutable,
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
  }) async {
    if (_isRunning) return false;
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

      final args = <String>[
        script.path,
        '--interactive',
        '--base-path',
        workingDirectory ?? baseDirectory.path,
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
          final cfgPath = '${tmp.path}/hf_chat_flutter_agents.json';
          await AgentRoleSettingsRepository.instance
              .writeAgentConfigJson(cfgPath);
          args.addAll(['--multi-agent', '--agent-config', cfgPath]);
          _appendLog('[manager] Multi-agent config written -> $cfgPath');
        } catch (e) {
          _appendLog('[manager] Failed to write agents.json: $e');
          return false;
        }
      }

      _process = await Process.start(
        pythonExecutable,
        args,
        workingDirectory: script.parent.path,
      );

      _stdoutSub = _process!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onStdoutLine, onError: _onStreamError, onDone: _onProcessExited);

      _stderrSub = _process!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
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
      // newlines survive the line-oriented protocol. In multi-agent mode the
      // same payload also carries a `trace` array — surface it on the trace
      // stream without changing the public sendPrompt contract.
      if (joined.startsWith('{')) {
        try {
          final obj = jsonDecode(joined);
          if (obj is Map) {
            if (obj['response'] is String) {
              response = obj['response'] as String;
            }
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
