import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants/api_constants.dart';
import 'ollama_service.dart';

/// Manages the local `ollama serve` subprocess so the user can install and
/// start Ollama without leaving the app.
///
/// Design:
///   * `checkBinary()` runs `ollama --version` and caches the result; if the
///     CLI is missing the UI tells the user to install from ollama.com
///     (we don't attempt to drive the OS installer ourselves — that needs
///     admin privileges and is OS-specific).
///   * `startServer()` spawns `ollama serve` as a detached-ish subprocess and
///     polls `http://localhost:11434/api/tags` until it responds (or times
///     out). If the daemon is already running externally, startServer is a
///     no-op that succeeds immediately.
///   * `stopServer()` kills only the subprocess *we* launched — we never
///     kill an ollama daemon we didn't start, because it may be shared with
///     other tools.
class OllamaManager {
  OllamaManager._();

  static final OllamaManager instance = OllamaManager._();

  Process? _process;
  final StringBuffer _log = StringBuffer();
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  bool get isManagingProcess => _process != null;
  String get log => _log.toString();

  bool get supportsUiInstall => Platform.isWindows;

  // ---------------------------------------------------------------------------
  // Binary detection
  // ---------------------------------------------------------------------------

  /// Try to run `ollama --version`. Returns the version string on success,
  /// `null` if the binary is not on PATH / cannot be executed.
  Future<String?> detectBinary() async {
    try {
      final r = await Process.run('ollama', ['--version'],
          runInShell: Platform.isWindows);
      if (r.exitCode == 0) {
        final out = (r.stdout?.toString() ?? '').trim();
        return out.isEmpty ? 'installed' : out;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Attempt a one-click Ollama installation from the UI.
  ///
  /// Right now this is implemented for Windows via `winget`, which matches
  /// the primary desktop target of this app.
  Future<bool> installBinary({
    void Function(String line)? onLine,
  }) async {
    final existing = await detectBinary();
    if (existing != null) {
      onLine?.call('Ollama is already installed: $existing');
      return true;
    }

    if (!supportsUiInstall) {
      onLine?.call(
        'Automatic Ollama install is currently supported only on Windows. '
        'Install it from ${ApiConstants.ollamaDownloadUrl} and retry.',
      );
      return false;
    }

    onLine?.call('Running winget install for Ollama...');
    try {
      final process = await Process.start(
        'winget',
        [
          'install',
          '-e',
          '--id',
          'Ollama.Ollama',
          '--accept-package-agreements',
          '--accept-source-agreements',
        ],
        runInShell: true,
        mode: ProcessStartMode.normal,
      );

      final stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine ?? (_) {});
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(onLine ?? (_) {});

      final exitCode = await process.exitCode;
      await stdoutSub.cancel();
      await stderrSub.cancel();
      if (exitCode != 0) {
        onLine?.call('winget install failed with exit code $exitCode');
        return false;
      }

      final version = await detectBinary();
      if (version == null) {
        onLine?.call(
          'Installer finished but the ollama binary is still not visible on PATH yet. '
          'If needed, restart the app and retry.',
        );
        return false;
      }

      onLine?.call('Installed Ollama successfully: $version');
      return true;
    } catch (e) {
      onLine?.call('Failed to run winget install: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Server lifecycle
  // ---------------------------------------------------------------------------

  /// Start `ollama serve` if it isn't already reachable. Streams log lines
  /// to [onLine] as they arrive. Returns true if the daemon is responsive at
  /// the end of the call.
  Future<bool> startServer({
    String? baseUrl,
    void Function(String line)? onLine,
    Duration bootTimeout = const Duration(seconds: 20),
  }) async {
    // If something is already listening on 11434, no need to spawn anything.
    if (await OllamaService.instance.isServerReachable(baseUrl: baseUrl)) {
      onLine?.call('Ollama server already running — no new process spawned.');
      return true;
    }

    if (_process != null) {
      onLine?.call('A managed ollama process is already running.');
      // Fall through to the readiness poll below.
    } else {
      final version = await detectBinary();
      if (version == null) {
        onLine?.call(
          'ERROR: `ollama` binary not found on PATH. Install it from '
          '${ApiConstants.ollamaDownloadUrl} and restart this app.',
        );
        return false;
      }
      onLine?.call('Detected Ollama: $version');
      onLine?.call('Launching: ollama serve');

      try {
        _log.clear();
        _process = await Process.start(
          'ollama',
          ['serve'],
          runInShell: Platform.isWindows,
          mode: ProcessStartMode.normal,
        );
      } catch (e) {
        onLine?.call('ERROR: failed to spawn `ollama serve`: $e');
        _process = null;
        return false;
      }

      _stdoutSub = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _log.writeln(line);
        onLine?.call(line);
      });
      _stderrSub = _process!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _log.writeln(line);
        onLine?.call(line);
      });

      // Clean up when the daemon exits so we don't hold a zombie handle.
      // ignore: unawaited_futures
      _process!.exitCode.then((code) {
        onLine?.call('ollama serve exited with code $code');
        _stdoutSub?.cancel();
        _stderrSub?.cancel();
        _stdoutSub = null;
        _stderrSub = null;
        _process = null;
      });
    }

    // Poll until the daemon answers or we time out.
    final deadline = DateTime.now().add(bootTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await OllamaService.instance.isServerReachable(baseUrl: baseUrl)) {
        onLine?.call('✓ Ollama is ready.');
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    onLine?.call('TIMEOUT: ollama did not become ready within '
        '${bootTimeout.inSeconds}s.');
    return false;
  }

  /// Kill the subprocess we launched. A no-op if we didn't start one.
  Future<void> stopServer({void Function(String line)? onLine}) async {
    final p = _process;
    if (p == null) {
      onLine?.call('No managed ollama process to stop.');
      return;
    }
    onLine?.call('Stopping managed ollama serve…');
    try {
      p.kill();
    } catch (_) {}
    try {
      await p.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      // On timeout, try SIGKILL-equivalent.
      try {
        p.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process = null;
  }
}
