import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../core/constants/api_constants.dart';

/// Manages a lightweight local Python bridge built on top of the
/// `ollama` Python package.
///
/// The Flutter app already knows how to talk to OpenAI-compatible local
/// servers via [LocalLlmService]. This manager starts one automatically so
/// users can choose a second Ollama approach:
///   1. direct REST calls to the native Ollama daemon
///   2. a Python bridge using `pip install ollama`
class OllamaPythonManager {
  OllamaPythonManager._();

  static final OllamaPythonManager instance = OllamaPythonManager._();

  static const String defaultBridgeUrl = ApiConstants.ollamaPythonBridgeUrl;

  final Dio _dio = Dio();

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  final StringBuffer _log = StringBuffer();

  bool get isManagingBridge => _process != null;
  String get log => _log.toString();

  Future<_PythonCommand?> _detectPythonCommand() async {
    final candidates = <_PythonCommand>[
      const _PythonCommand('python', []),
      const _PythonCommand('py', ['-3']),
      const _PythonCommand('python3', []),
    ];

    for (final candidate in candidates) {
      try {
        final result = await Process.run(
          candidate.executable,
          [...candidate.args, '--version'],
          runInShell: Platform.isWindows,
        );
        if (result.exitCode == 0) {
          return candidate;
        }
      } catch (_) {
        // Try the next candidate.
      }
    }
    return null;
  }

  Future<String?> detectPythonVersion() async {
    final command = await _detectPythonCommand();
    if (command == null) return null;
    try {
      final result = await Process.run(
        command.executable,
        [...command.args, '--version'],
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) return null;
      final stdout = (result.stdout?.toString() ?? '').trim();
      final stderr = (result.stderr?.toString() ?? '').trim();
      final output = stdout.isNotEmpty ? stdout : stderr;
      return output.isEmpty ? 'Python detected' : output;
    } catch (_) {
      return null;
    }
  }

  Future<String?> detectPackageVersion() async {
    final command = await _detectPythonCommand();
    if (command == null) return null;
    try {
      final result = await Process.run(
        command.executable,
        [
          ...command.args,
          '-c',
          "import importlib.metadata as m; print(m.version('ollama'))",
        ],
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) return null;
      final output = (result.stdout?.toString() ?? '').trim();
      return output.isEmpty ? null : output;
    } catch (_) {
      return null;
    }
  }

  Future<bool> installPackage({
    void Function(String line)? onLine,
  }) async {
    final command = await _detectPythonCommand();
    if (command == null) {
      onLine?.call(
        'Python was not found on PATH. Install Python first, then retry.',
      );
      return false;
    }

    onLine?.call('Installing Python package: ollama');
    try {
      final process = await Process.start(
        command.executable,
        [...command.args, '-m', 'pip', 'install', '--upgrade', 'ollama'],
        runInShell: Platform.isWindows,
        mode: ProcessStartMode.normal,
      );

      final stdoutSub = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine ?? (_) {});
      final stderrSub = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(onLine ?? (_) {});

      final exitCode = await process.exitCode;
      await stdoutSub.cancel();
      await stderrSub.cancel();
      if (exitCode != 0) {
        onLine?.call('pip install failed with exit code $exitCode');
        return false;
      }

      final version = await detectPackageVersion();
      onLine?.call(
        version == null
            ? 'Package installed.'
            : 'Installed Python package ollama==$version',
      );
      return true;
    } catch (e) {
      onLine?.call('Failed to install Python package: $e');
      return false;
    }
  }

  Future<bool> isBridgeReachable({String? bridgeUrl}) async {
    final url = _normaliseUrl(bridgeUrl ?? defaultBridgeUrl);
    try {
      final response = await _dio.get(
        '$url/health',
        options: Options(
          receiveTimeout: const Duration(seconds: 3),
          sendTimeout: const Duration(seconds: 3),
        ),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startBridge({
    String? bridgeUrl,
    void Function(String line)? onLine,
    Duration bootTimeout = const Duration(seconds: 20),
  }) async {
    final url = _normaliseUrl(bridgeUrl ?? defaultBridgeUrl);
    if (await isBridgeReachable(bridgeUrl: url)) {
      onLine?.call('Ollama Python bridge already running.');
      return true;
    }

    final command = await _detectPythonCommand();
    if (command == null) {
      onLine?.call('Python was not found on PATH.');
      return false;
    }

    final packageVersion = await detectPackageVersion();
    if (packageVersion == null) {
      onLine?.call(
        'Python package `ollama` is not installed. Run "Install Python package" first.',
      );
      return false;
    }

    final uri = Uri.parse(url);
    final host = uri.host.isEmpty ? '127.0.0.1' : uri.host;
    final port = uri.port == 0 ? 11501 : uri.port;
    final scriptFile = await _writeBridgeScript();

    if (_process != null) {
      onLine?.call('A managed bridge process is already running.');
    } else {
      onLine?.call('Launching Python bridge on http://$host:$port');
      _log.clear();
      try {
        _process = await Process.start(
          command.executable,
          [...command.args, scriptFile.path, '--host', host, '--port', '$port'],
          runInShell: Platform.isWindows,
          mode: ProcessStartMode.normal,
        );
      } catch (e) {
        _process = null;
        onLine?.call('Failed to start Python bridge: $e');
        return false;
      }

      _stdoutSub = _process!.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        _log.writeln(line);
        onLine?.call(line);
      });
      _stderrSub = _process!.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        _log.writeln(line);
        onLine?.call(line);
      });

      // ignore: unawaited_futures
      _process!.exitCode.then((code) async {
        onLine?.call('Ollama Python bridge exited with code $code');
        await _stdoutSub?.cancel();
        await _stderrSub?.cancel();
        _stdoutSub = null;
        _stderrSub = null;
        _process = null;
      });
    }

    final deadline = DateTime.now().add(bootTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isBridgeReachable(bridgeUrl: url)) {
        onLine?.call('Python bridge is ready.');
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    onLine?.call('Timeout while waiting for Python bridge readiness.');
    return false;
  }

  Future<void> stopBridge({void Function(String line)? onLine}) async {
    final process = _process;
    if (process == null) {
      onLine?.call('No managed Python bridge is running.');
      return;
    }
    onLine?.call('Stopping managed Python bridge...');
    try {
      process.kill();
    } catch (_) {}
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process = null;
  }

  String _normaliseUrl(String url) {
    var value = url.trim();
    if (value.isEmpty) value = defaultBridgeUrl;
    if (!value.contains('://')) value = 'http://$value';
    if (value.endsWith('/')) value = value.substring(0, value.length - 1);
    return value;
  }

  Future<File> _writeBridgeScript() async {
    final file = File('${Directory.systemTemp.path}/hf_chat_ollama_bridge.py');
    await file.writeAsString(_bridgeScript);
    return file;
  }
}

class _PythonCommand {
  final String executable;
  final List<String> args;

  const _PythonCommand(this.executable, this.args);
}

const String _bridgeScript = r'''
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import ollama


def _health_payload():
    try:
        result = ollama.list()
        models = result.get("models", [])
        return 200, {
            "status": "ok",
            "daemon": True,
            "models": [m.get("name") for m in models if isinstance(m, dict)],
        }
    except Exception as exc:
        return 503, {"status": "error", "daemon": False, "error": str(exc)}


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, format, *args):
        print(format % args)

    def do_GET(self):
        if self.path == "/health":
            status, payload = _health_payload()
            self._send_json(status, payload)
            return
        if self.path == "/v1/models":
            try:
                result = ollama.list()
                models = result.get("models", [])
                self._send_json(
                    200,
                    {
                        "data": [
                            {"id": m.get("name"), "object": "model"}
                            for m in models
                            if isinstance(m, dict) and m.get("name")
                        ]
                    },
                )
            except Exception as exc:
                self._send_json(500, {"error": str(exc)})
            return
        self._send_json(404, {"error": "Not found"})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._send_json(404, {"error": "Not found"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length)
            data = json.loads(body.decode("utf-8"))
        except Exception as exc:
            self._send_json(400, {"error": f"Invalid JSON: {exc}"})
            return

        model = data.get("model")
        messages = data.get("messages", [])
        if not model:
            self._send_json(400, {"error": "model is required"})
            return

        options = {}
        temperature = data.get("temperature")
        if temperature is not None:
            options["temperature"] = temperature
        max_tokens = data.get("max_tokens")
        if max_tokens is not None:
            options["num_predict"] = max_tokens
        # IMPORTANT: cap the context window. Several Ollama models
        # (notably phi3:mini and llama3.2) ship a Modelfile with
        # num_ctx=128K. Allocating that KV cache costs tens of GiB of
        # RAM, even for a 2-3 GB model — leading to confusing
        # "model requires 50 GiB" errors on machines with 8 GB free.
        # 4096 is plenty for chat and keeps cache allocation < 1 GiB.
        # Callers can override by passing "num_ctx" in the JSON body.
        num_ctx = data.get("num_ctx", 4096)
        if num_ctx is not None:
            options["num_ctx"] = num_ctx

        try:
            response = ollama.chat(
                model=model,
                messages=messages,
                options=options or None,
                stream=False,
            )
            content = response.get("message", {}).get("content", "")
            self._send_json(
                200,
                {
                    "choices": [
                        {
                            "index": 0,
                            "finish_reason": "stop",
                            "message": {"role": "assistant", "content": content},
                        }
                    ]
                },
            )
        except Exception as exc:
            # Enrich the error body so the Dart side can point the user at
            # the real cause. Most frequent failure: the requested model
            # tag isn't installed — the user asked for "llama3" but Ollama
            # has it stored as "llama3:latest".
            err_text = str(exc)
            low = err_text.lower()
            hint = None
            try:
                installed = [
                    m.get("name")
                    for m in ollama.list().get("models", [])
                    if isinstance(m, dict) and m.get("name")
                ]
            except Exception:
                installed = []
            if ("not found" in low or "no such model" in low or
                    "try pulling" in low):
                if installed:
                    hint = (
                        f"model '{model}' is not installed. "
                        f"Installed models: {installed}. "
                        f"Either pull '{model}' from Settings or select one "
                        f"of the installed tags."
                    )
                else:
                    hint = (
                        f"model '{model}' is not installed and no other "
                        f"models are installed either. Pull one from "
                        f"Settings (e.g. 'llama3:latest')."
                    )
            elif "connection refused" in low or "11434" in low:
                hint = (
                    "Ollama daemon on 11434 is not running. "
                    "Start it from Settings (🦙 Ollama → Start Ollama server)."
                )
            payload = {"error": err_text}
            if hint:
                payload["hint"] = hint
            self._send_json(500, payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11501)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Ollama Python bridge listening on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
''';
