import 'package:dio/dio.dart';

import '../data/models/message.dart';

class LocalLlmService {
  LocalLlmService._();

  static final LocalLlmService instance = LocalLlmService._();

  final Dio _dio = Dio();

  /// Send chat to local LLM server (Python/transformers or ollama/llama.cpp)
  /// Expected server endpoint: POST /chat/completions or similar
  Future<String> sendChat({
    required String serverUrl, // e.g., "http://localhost:5000"
    required String modelId, // e.g., "codellama/CodeLlama-34b-Instruct-hf"
    required List<ChatMessage> history,
    int maxTokens = 2048,
    double temperature = 0.7,
  }) async {
    try {
      final messages = history
          .map((m) => {
                "role": switch (m.role) {
                  MessageRole.user => "user",
                  MessageRole.assistant => "assistant",
                  MessageRole.system => "system",
                },
                "content": m.content,
              })
          .toList();

      // Support both OpenAI-compatible and custom endpoints.
      // `validateStatus: (_) => true` so Dio doesn't throw on 4xx/5xx — we
      // want to read the server's JSON body (e.g. `{"error": "..."}`) and
      // surface that to the user instead of the generic "500 server error"
      // message, which hides the root cause.
      final response = await _dio.post(
        "$serverUrl/v1/chat/completions",
        options: Options(
          headers: {"Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 30),
          validateStatus: (_) => true,
        ),
        data: {
          "model": modelId,
          "messages": messages,
          "max_tokens": maxTokens,
          "temperature": temperature,
          "stream": false,
        },
      );

      if (response.statusCode == 200) {
        final content = response.data?["choices"]?[0]?["message"]?["content"]
            as String?;
        if (content != null) return content;
        throw Exception(
          "Local LLM returned 200 but the response had no "
          "`choices[0].message.content`: ${response.data}",
        );
      }

      // Non-200 — extract the server's own error text for the user.
      throw Exception(_formatServerError(response, modelId, serverUrl));
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw Exception(
          "Cannot reach local server at $serverUrl. "
          "Make sure it is running (Settings → Start…).",
        );
      }
      throw Exception("Local LLM transport error: ${e.message}");
    }
  }

  /// Turn a non-200 Dio response into a human-friendly string that includes
  /// the server's own error body when available.
  ///
  /// Handles the three common response shapes:
  ///   * `{"error": "…"}`              (our Python bridge, Ollama native)
  ///   * `{"error": {"message": "…"}}` (OpenAI-style)
  ///   * `{"detail": "…"}`             (FastAPI / transformers servers)
  String _formatServerError(
      Response response, String modelId, String serverUrl) {
    final status = response.statusCode;
    final data = response.data;

    String? serverMsg;
    String? serverHint; // separate field our Python bridge emits
    if (data is Map) {
      final err = data['error'];
      if (err is String) {
        serverMsg = err;
      } else if (err is Map && err['message'] is String) {
        serverMsg = err['message'] as String;
      } else if (data['detail'] is String) {
        serverMsg = data['detail'] as String;
      }
      if (data['hint'] is String) {
        serverHint = data['hint'] as String;
      }
    } else if (data is String && data.trim().isNotEmpty) {
      serverMsg = data;
    }

    final base = "Local LLM server returned $status";
    final body = serverMsg != null && serverMsg.trim().isNotEmpty
        ? ': $serverMsg'
        : (data != null ? ': $data' : '');
    // If the bridge already gave us an actionable hint, prefer it over
    // the heuristics below.
    if (serverHint != null && serverHint.trim().isNotEmpty) {
      return '$base$body\n→ $serverHint';
    }

    // Heuristics: give the user a concrete next step when the cause is
    // obvious from the server message.
    final low = (serverMsg ?? '').toLowerCase();
    String hint = '';
    if (low.contains('requires more system memory') ||
        low.contains('not enough memory') ||
        low.contains('out of memory') ||
        (low.contains('memory') && low.contains('gib'))) {
      hint = _lowMemoryHint(serverMsg ?? '');
    } else if (low.contains('not found') ||
        low.contains('no such model') ||
        low.contains('pull the model') ||
        low.contains('try pulling') ||
        low.contains('model') && low.contains('does not exist')) {
      hint =
          '\n→ The model "$modelId" is not installed in Ollama. Open Settings '
          '→ 🦙 Ollama and click "Pull" for that exact tag (e.g. '
          '`llama3:latest`, not just `llama3`).';
    } else if (low.contains('connection refused') ||
        low.contains('connect: connection refused') ||
        low.contains('11434')) {
      hint =
          '\n→ The Ollama daemon on port 11434 is not reachable. In Settings '
          'click "Start Ollama server" on the 🦙 panel first, then retry.';
    } else if (status == 500 && (serverMsg == null || serverMsg.isEmpty)) {
      hint =
          '\n→ Server returned 500 with no body. Check the bridge log '
          '(Settings → Python bridge log console) for the traceback.';
    }

    return '$base$body$hint';
  }

  /// Build an actionable hint for the "model requires more system memory
  /// than is available" failure. Picks the right recommendation tier based
  /// on how much RAM Ollama reported as available.
  ///
  /// The OOM number Ollama reports is (weights + KV cache). KV cache scales
  /// with `num_ctx`, and several popular Modelfiles (phi3:mini, llama3.2)
  /// default to 128K context — which can cost 30-50 GiB of cache alone,
  /// even on a 2-3 GB model. The Python bridge now caps `num_ctx` to 4096,
  /// so seeing this error after the fix usually means the weights
  /// themselves don't fit.
  String _lowMemoryHint(String serverMsg) {
    // Try to parse "available (X.Y GiB)" out of Ollama's error text.
    final m = RegExp(
      r'available \(([\d.]+)\s*gib\)',
      caseSensitive: false,
    ).firstMatch(serverMsg);
    final availableGib = m == null ? null : double.tryParse(m.group(1)!);

    final requiredM = RegExp(
      r'requires more system memory \(([\d.]+)\s*gib\)',
      caseSensitive: false,
    ).firstMatch(serverMsg);
    final requiredGib =
        requiredM == null ? null : double.tryParse(requiredM.group(1)!);

    // If a small model "requires 50 GiB", it's a Modelfile context-window
    // issue, not the weights. Tell the user that up front.
    final looksLikeCtxExplosion =
        requiredGib != null && requiredGib >= 15;

    String fitsList;
    if (availableGib == null) {
      fitsList = '`tinyllama` (~0.6 GB), `qwen2.5:0.5b`, `gemma:2b` (~1.7 GB), '
          '`llama3.2:1b` (~1.3 GB).';
    } else if (availableGib < 2) {
      fitsList = '`tinyllama` (~0.6 GB), `qwen2.5:0.5b` (~0.4 GB). '
          'Even 2B models will be tight.';
    } else if (availableGib < 4) {
      fitsList = '`tinyllama`, `qwen2.5:0.5b`, `qwen2.5:1.5b`, '
          '`llama3.2:1b`, `gemma:2b` (~1.7 GB).';
    } else if (availableGib < 6) {
      fitsList = '`llama3.2:3b` (~2 GB), `gemma:2b`, `qwen2.5:1.5b`, '
          '`qwen2.5-coder:1.5b`, `tinyllama`.';
    } else if (availableGib < 10) {
      fitsList = '`llama3.2:3b`, `phi3:mini` (~2.3 GB), `mistral:7b` (~4 GB), '
          '`qwen2.5:7b` (~4.7 GB), `qwen2.5-coder:7b`.';
    } else {
      fitsList = '`llama3:8b`, `qwen2.5:7b`, `qwen2.5-coder:7b`, '
          '`mistral:7b`, `gemma:7b`.';
    }

    final availPart = availableGib == null
        ? ''
        : ' You have ${availableGib.toStringAsFixed(1)} GiB free.';
    final reqPart = requiredGib == null
        ? ''
        : ' Ollama asked for ${requiredGib.toStringAsFixed(1)} GiB.';

    final ctxNote = looksLikeCtxExplosion
        ? '\n→ That number is suspiciously large — it usually means the '
            "model's Modelfile defaults to a huge context window (phi3:mini "
            'and llama3.2 default to 128K). The Python bridge now caps '
            'context at 4096 tokens, so just retry — if the Python bridge '
            'was already running when you upgraded, stop and restart it '
            'from Settings first so the new limit takes effect.'
        : '';

    return '$ctxNote\n→ Model too big for this machine.$availPart$reqPart '
        'Rule of thumb: pick a model whose size is less than your free RAM. '
        'Models that should fit: $fitsList '
        'Open Settings → 🦙 Ollama → Pull, and use one of those tags.';
  }

  /// Check if local server is available
  Future<bool> isServerAvailable(String serverUrl) async {
    try {
      final response = await _dio.get(
        "$serverUrl/health",
        options: Options(receiveTimeout: const Duration(seconds: 5)),
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// List available local models
  Future<List<String>> listModels(String serverUrl) async {
    try {
      final response = await _dio.get("$serverUrl/v1/models");
      if (response.statusCode == 200) {
        final models = response.data["data"] as List?;
        return models?.map((m) => m["id"] as String).toList() ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
