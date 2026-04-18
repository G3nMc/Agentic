import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final StringBuffer _stderrBuffer = StringBuffer();

  // Completes when the orchestrator prints `__READY__` on stdout.
  Completer<void>? _readyCompleter;

  // Queue of in-flight requests so sends are serialized on the stdin pipe.
  Future<String> _chain = Future.value('');

  // Per-request assembly state.
  Completer<String>? _activeCompleter;
  final List<String> _activeLines = [];

  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  bool get isRunning => _isRunning;
  bool get isReady => _isReady;
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
  Future<bool> start({
    required String hfToken,
    String? modelId,
    String? workingDirectory,
  }) async {
    if (_isRunning) return false;

    final script = orchestratorScript;
    if (!script.existsSync()) {
      _stderrBuffer.writeln('orchestrator.py not found at ${script.path}');
      return false;
    }

    try {
      _stderrBuffer.clear();
      _readyCompleter = Completer<void>();

      final args = <String>[
        script.path,
        '--hf-token', hfToken,
        '--interactive',
        '--base-path', workingDirectory ?? baseDirectory.path,
      ];
      if (modelId != null && modelId.isNotEmpty) {
        args.addAll(['--model', modelId]);
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
          .listen((line) => _stderrBuffer.writeln(line));

      // Wait up to 30s for the `__READY__` handshake. If the Python side
      // is missing dependencies it will exit with code 2 — we detect that
      // via _onProcessExited and complete the ready future with an error.
      await _readyCompleter!.future.timeout(const Duration(seconds: 30));

      _isRunning = true;
      _isReady = true;
      return true;
    } catch (e) {
      _stderrBuffer.writeln('start() failed: $e');
      await _cleanup();
      return false;
    }
  }

  /// Send a prompt to the orchestrator and await the full response.
  /// [newSession] resets the orchestrator's conversation history.
  Future<String> sendPrompt(String prompt, {bool newSession = false}) {
    // Serialize requests so multiple callers don't interleave on stdin.
    final next = _chain.then((_) => _sendPromptInternal(prompt, newSession));
    _chain = next.catchError((_) => '');
    return next;
  }

  Future<String> _sendPromptInternal(String prompt, bool newSession) async {
    if (!_isRunning || _process == null) {
      return 'Error: Orchestrator not running. Start it from Settings first.';
    }
    if (!_isReady) {
      return 'Error: Orchestrator not ready yet.';
    }

    _activeCompleter = Completer<String>();
    _activeLines.clear();

    final request = jsonEncode({'prompt': prompt, 'new_session': newSession});
    try {
      _process!.stdin.writeln(request);
      await _process!.stdin.flush();
    } catch (e) {
      return 'Error: Failed to write to orchestrator stdin: $e';
    }

    // 5-minute timeout for long-running tool chains.
    try {
      return await _activeCompleter!.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => 'Timeout: orchestrator did not respond within 5 minutes.',
      );
    } finally {
      _activeCompleter = null;
      _activeLines.clear();
    }
  }

  void _onStdoutLine(String line) {
    // Handshake: Python prints `__READY__` exactly once at startup.
    if (!_isReady && line.trim() == '__READY__') {
      _readyCompleter?.complete();
      return;
    }

    if (_activeCompleter == null) return; // Stray line; ignore.

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
    _stderrBuffer.writeln('stdout stream error: $error');
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
  }

  bool checkHealthy() => _isRunning && _isReady && _process != null;
}
