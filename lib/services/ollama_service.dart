import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../core/constants/api_constants.dart';
import '../data/models/message.dart';

/// Thin wrapper around Ollama's native REST API (http://localhost:11434).
///
/// Ollama binary exposes these endpoints out-of-the-box, so we don't need
/// the `ollama` Python library at all — Dart + Dio is enough for chat,
/// listing installed models, and pulling new ones.
///
/// API reference: https://github.com/ollama/ollama/blob/main/docs/api.md
class OllamaService {
  OllamaService._();

  static final OllamaService instance = OllamaService._();

  /// Default Ollama daemon address.
  static const String defaultBaseUrl = ApiConstants.ollamaLocalBaseUrl;

  final Dio _dio = Dio();

  String _normalise(String base) {
    var b = base.trim();
    if (b.isEmpty) b = defaultBaseUrl;
    if (b.endsWith('/')) b = b.substring(0, b.length - 1);
    return b;
  }

  /// Returns Dio request headers. When [apiKey] is non-empty an
  /// `Authorization: Bearer <key>` header is added so the same code works
  /// against local Ollama (no key) and cloud endpoints like
  /// https://api.ollama.ai that require a Bearer token.
  ///
  /// Falls back to the `OLLAMA_API_KEY` environment variable when the
  /// caller passes no key — this lets users who have the env var set
  /// (locally or via the Settings "Set as env variable" button) work
  /// without also filling in the Settings field.
  Map<String, String> _headers({String? apiKey}) {
    final h = <String, String>{'Content-Type': 'application/json'};
    final k = (apiKey ?? '').trim().isNotEmpty
        ? apiKey!.trim()
        : (Platform.environment['OLLAMA_API_KEY'] ?? '').trim();
    if (k.isNotEmpty) h['Authorization'] = 'Bearer $k';
    return h;
  }

  // ---------------------------------------------------------------------------
  // Health check
  // ---------------------------------------------------------------------------

  /// Returns true if the daemon/cloud endpoint is answering at [baseUrl].
  Future<bool> isServerReachable({String? baseUrl, String? apiKey}) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);
    try {
      final resp = await _dio.get(
        '$url/api/tags',
        options: Options(
          headers: _headers(apiKey: apiKey),
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
        ),
      );
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Model listing
  // ---------------------------------------------------------------------------

  /// List available models from the daemon or cloud endpoint.
  Future<List<String>> listInstalledModels({
    String? baseUrl,
    String? apiKey,
  }) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);
    final resp = await _dio.get(
      '$url/api/tags',
      options: Options(
        headers: _headers(apiKey: apiKey),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    if (resp.statusCode != 200) {
      throw Exception('Ollama /api/tags returned ${resp.statusCode}');
    }
    final models = resp.data?['models'] as List? ?? const [];
    return models
        .map((m) => (m is Map ? m['name'] : null) as String?)
        .whereType<String>()
        .toList();
  }

  /// Rich catalog of installed models — combines `/api/tags` (size, family,
  /// quantization, modified date) with `/api/show` (capabilities, e.g.
  /// `tools`, `vision`). The `show` calls are fanned out in parallel; if any
  /// individual one fails the row is still returned with empty capabilities.
  Future<List<OllamaCatalogModel>> listCatalog({
    String? baseUrl,
    String? apiKey,
  }) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);
    final resp = await _dio.get(
      '$url/api/tags',
      options: Options(
        headers: _headers(apiKey: apiKey),
        receiveTimeout: const Duration(seconds: 10),
      ),
    );
    if (resp.statusCode != 200) {
      throw Exception('Ollama /api/tags returned ${resp.statusCode}');
    }
    final raw = (resp.data?['models'] as List?) ?? const [];
    final base = raw
        .whereType<Map>()
        .map((m) => OllamaCatalogModel.fromTagJson(
              Map<String, dynamic>.from(m),
            ))
        .where((m) => m.name.isNotEmpty)
        .toList();

    // Fan out /api/show — capability data is the part that lets us draw a
    // Tools ✓ column matching OpenRouter / GitHub catalogs.
    final futures = base.map((m) async {
      try {
        final showResp = await _dio.post(
          '$url/api/show',
          data: jsonEncode({'name': m.name}),
          options: Options(
            headers: _headers(apiKey: apiKey),
            receiveTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 5),
            validateStatus: (_) => true,
          ),
        );
        if (showResp.statusCode != 200) return m;
        final data = showResp.data;
        if (data is! Map) return m;
        final caps = (data['capabilities'] as List?)
                ?.whereType<String>()
                .toList() ??
            const <String>[];
        return m.withCapabilities(caps);
      } catch (_) {
        return m;
      }
    });
    final enriched = await Future.wait(futures);
    enriched.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return enriched;
  }

  // ---------------------------------------------------------------------------
  // Delete an installed model
  // ---------------------------------------------------------------------------

  /// Remove [modelName] (e.g. `llama3:latest`) from the Ollama daemon.
  /// Uses `DELETE /api/delete` with `{"name": "<model>"}` body.
  Future<void> deleteModel(
    String modelName, {
    String? baseUrl,
    String? apiKey,
  }) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);
    final resp = await _dio.delete(
      '$url/api/delete',
      data: {'name': modelName},
      options: Options(
        headers: _headers(apiKey: apiKey),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 10),
        validateStatus: (_) => true,
      ),
    );
    if (resp.statusCode != 200) {
      final data = resp.data;
      final err = (data is Map && data['error'] is String) ? data['error'] : '$data';
      throw Exception('Ollama /api/delete returned ${resp.statusCode}: $err');
    }
  }

  // ---------------------------------------------------------------------------
  // Pull (download) a model — streams progress JSON lines
  // ---------------------------------------------------------------------------

  /// Download [modelName] (e.g. `llama3`, `qwen2.5-coder:7b`).
  /// [onProgress] is invoked for every progress line ollama streams back,
  /// which typically looks like
  ///   `{"status":"downloading digest","digest":"sha256:…","total":…,"completed":…}`
  /// Completes when the model is fully downloaded (server closes the stream).
  Future<void> pullModel(
    String modelName, {
    String? baseUrl,
    String? apiKey,
    void Function(String line)? onProgress,
    /// Optional callback fired whenever the server reports progress on a
    /// digest. `completed` and `total` are bytes; both are 0 before the
    /// transfer phase begins.
    void Function(int completed, int total)? onBytes,
    /// Pass a Dio [CancelToken] to abort the pull mid-stream. Cancelling
    /// closes the HTTP connection — Ollama then stops fetching, but any
    /// blobs it already wrote stay in its store. Callers that want to
    /// reclaim the disk space should follow up with [deleteModel] (which
    /// the daemon handles silently if the manifest hasn't been written).
    CancelToken? cancelToken,
  }) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);
    final resp = await _dio.post<ResponseBody>(
      '$url/api/pull',
      data: jsonEncode({'name': modelName, 'stream': true}),
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: _headers(apiKey: apiKey),
        // No total timeout — large models can take many minutes.
        receiveTimeout: Duration.zero,
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    if (resp.statusCode != 200) {
      throw Exception('Ollama /api/pull returned ${resp.statusCode}');
    }

    final data = resp.data;
    if (data == null) return;

    // Buffer partial chunks — a line may span two network reads.
    final buffer = StringBuffer();
    await for (final chunk in data.stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      final raw = buffer.toString();
      final lines = raw.split('\n');
      // Keep the last (possibly incomplete) segment for the next iteration.
      buffer.clear();
      buffer.write(lines.removeLast());
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        onProgress?.call(trimmed);
        // Fail fast if server reports an error status, and surface byte
        // progress when present so the UI can show a real progress bar.
        try {
          final obj = jsonDecode(trimmed);
          if (obj is Map) {
            if (obj['error'] is String) {
              throw Exception('Ollama pull error: ${obj['error']}');
            }
            final completed = obj['completed'];
            final total = obj['total'];
            if (completed is num && total is num && total > 0) {
              onBytes?.call(completed.toInt(), total.toInt());
            }
          }
        } catch (e) {
          // Not JSON — just forward as-is; already sent to onProgress.
          if (e is Exception && e.toString().contains('Ollama pull error')) {
            rethrow;
          }
        }
      }
    }
    // Flush any final line left in the buffer.
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) onProgress?.call(tail);
  }

  // ---------------------------------------------------------------------------
  // Chat via /api/generate (streaming)
  // ---------------------------------------------------------------------------

  /// Send the [history] to Ollama via `/api/generate` and return the
  /// assistant's full reply. Streaming is used so the UI stays responsive.
  Future<String> sendChat({
    required String modelId,
    required List<ChatMessage> history,
    String? baseUrl,
    String? apiKey,
    double temperature = 0.7,
    int? numPredict,
    int numCtx = 4096,
    // --- New parameters matching Ollama /api/generate spec ---
    String? suffix,
    List<String>? images,
    Object? format,
    bool raw = false,
    String? keepAlive,
    bool logprobs = false,
    int? topLogprobs,
    int? seed,
    int? topK,
    double? topP,
    double? minP,
    List<String>? stop,
  }) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);

    // Split system messages from conversational turns.
    final systemParts = history
        .where((m) => m.role == MessageRole.system)
        .map((m) => m.content)
        .toList();
    final turns = history
        .where((m) => m.role != MessageRole.system)
        .toList();

    final systemText = systemParts.join('\n\n');
    final prompt = _buildPrompt(turns);

    final options = <String, Object?>{
      'temperature': temperature,
      'num_ctx': numCtx,
      if (numPredict != null) 'num_predict': numPredict,
      if (seed != null) 'seed': seed,
      if (topK != null) 'top_k': topK,
      if (topP != null) 'top_p': topP,
      if (minP != null) 'min_p': minP,
      if (stop != null && stop.isNotEmpty) 'stop': stop,
    };

    final body = <String, Object?>{
      'model': modelId,
      'prompt': prompt,
      'stream': true,
      'options': options,
      if (systemText.isNotEmpty) 'system': systemText,
      if (suffix != null && suffix.isNotEmpty) 'suffix': suffix,
      if (images != null && images.isNotEmpty) 'images': images,
      if (format != null) 'format': format,
      if (raw) 'raw': true,
      if (keepAlive != null && keepAlive.isNotEmpty) 'keep_alive': keepAlive,
      if (logprobs) 'logprobs': true,
      if (topLogprobs != null) 'top_logprobs': topLogprobs,
    };

    try {
      final resp = await _dio.post<ResponseBody>(
        '$url/api/generate',
        data: jsonEncode(body),
        options: Options(
          responseType: ResponseType.stream,
          headers: _headers(apiKey: apiKey),
          receiveTimeout: Duration.zero,
          sendTimeout: const Duration(minutes: 1),
          validateStatus: (_) => true,
        ),
      );

      if (resp.statusCode != 200) {
        String errBody = '';
        try {
          final chunks = <int>[];
          await resp.data!.stream.listen((c) => chunks.addAll(c)).asFuture();
          errBody = utf8.decode(chunks, allowMalformed: true);
        } catch (_) {}

        // Try to extract Ollama's own error field.
        String errMsg = errBody;
        try {
          final obj = jsonDecode(errBody);
          if (obj is Map && obj['error'] is String) {
            errMsg = obj['error'] as String;
          }
        } catch (_) {}

        final lower = errMsg.toLowerCase();
        String hint = '';
        if (lower.contains('requires more system memory') ||
            lower.contains('not enough memory') ||
            lower.contains('out of memory') ||
            (lower.contains('memory') && lower.contains('gib'))) {
          hint = _lowMemoryHint(errMsg);
        } else if (lower.contains('not found') ||
            lower.contains('no such model') ||
            lower.contains('try pulling')) {
          try {
            final installed = await listInstalledModels(baseUrl: baseUrl);
            hint = installed.isEmpty
                ? '\n→ No models are installed yet. Open Settings → 🦙 Ollama '
                    'and click "Pull" (e.g. `llama3:latest`).'
                : '\n→ "$modelId" is not installed. '
                    'Installed: ${installed.join(", ")}. '
                    'Pick one of those in Settings, or pull the exact tag.';
          } catch (_) {
            hint = '\n→ Model "$modelId" is not installed. Pull it from '
                'Settings → 🦙 Ollama.';
          }
        }
        throw Exception(
          'Ollama /api/generate returned ${resp.statusCode}: $errMsg$hint',
        );
      }

      return await _readStream(resp.data!);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw Exception(
          'Cannot reach Ollama at $url. Start the daemon from Settings '
          '("Start Ollama server") or run `ollama serve` in a terminal.',
        );
      }
      throw Exception('Ollama error: ${e.message}');
    }
  }

  // ---------------------------------------------------------------------------
  // Stream reader
  // ---------------------------------------------------------------------------

  Future<String> _readStream(ResponseBody body) async {
    final buffer = StringBuffer();
    final response = StringBuffer();

    await for (final chunk in body.stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      final raw = buffer.toString();
      final lines = raw.split('\n');
      buffer.clear();
      buffer.write(lines.removeLast());

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final obj = jsonDecode(trimmed) as Map<String, dynamic>;
          final chunkText = obj['response'] as String? ?? '';
          if (chunkText.isNotEmpty) response.write(chunkText);
          if (obj['error'] is String) {
            throw Exception('Ollama generate error: ${obj['error']}');
          }
        } catch (e) {
          if (e is Exception && e.toString().contains('Ollama generate error')) {
            rethrow;
          }
        }
      }
    }

    // Flush trailing partial line.
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      try {
        final obj = jsonDecode(tail) as Map<String, dynamic>;
        final chunkText = obj['response'] as String? ?? '';
        if (chunkText.isNotEmpty) response.write(chunkText);
      } catch (_) {}
    }

    var responseText = response.toString().trim();
    // Some models echo the trailing "Assistant:" prompt cue, producing a
    // reply that starts with a stray colon. Strip it before returning.
    if (responseText.startsWith(':')) {
      responseText = responseText.substring(1).trimLeft();
    }
    return responseText;
  }

  // ---------------------------------------------------------------------------
  // Prompt builder
  // ---------------------------------------------------------------------------

  String _buildPrompt(List<ChatMessage> turns) {
    if (turns.isEmpty) return '';
    final sb = StringBuffer();
    for (final m in turns) {
      switch (m.role) {
        case MessageRole.user:
          sb.write('User: ${m.content}\n');
          break;
        case MessageRole.assistant:
          sb.write('Assistant: ${m.content}\n');
          break;
        case MessageRole.system:
          sb.write('[System: ${m.content}]\n');
          break;
      }
    }
    sb.write('Assistant:');
    return sb.toString();
  }

  /// Build an actionable hint for the "model requires more system memory than
  /// is available" failure. Picks the right recommendation tier based on how
  /// much RAM Ollama reported as available. Mirrors the helper in
  /// [LocalLlmService] so users on either Ollama code path get the same
  /// guidance.
  ///
  /// The OOM number Ollama reports is (weights + KV cache). KV cache scales
  /// with `num_ctx`, and several popular Modelfiles (phi3:mini, llama3.2)
  /// default to 128K context — which can cost 30-50 GiB of cache alone,
  /// even on a 2-3 GB model. We now cap `num_ctx` to 4096, so seeing this
  /// error after the fix usually means the weights themselves don't fit.
  String _lowMemoryHint(String serverMsg) {
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

    // If Ollama says a 2-3 GB model "requires 50 GiB", that's almost
    // certainly a giant context window being honoured from the Modelfile.
    // Warn the user up front before the generic recommendation list.
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
            'and llama3.2 default to 128K). The app now caps context at '
            '4096 tokens, so just retry. If the error comes back, the '
            'weights themselves are too big and you need a smaller model.'
        : '';

    return '$ctxNote\n→ Model too big for this machine.$availPart$reqPart '
        'Rule of thumb: pick a model whose size is less than your free RAM. '
        'Models that should fit: $fitsList '
        'Open Settings → 🦙 Ollama → Pull, and use one of those tags.';
  }

  /// Whether a catalog entry advertises native tool/function calling
  /// (Ollama exposes this in `/api/show` -> `capabilities`).
  static bool supportsToolCalling(OllamaCatalogModel m) {
    return m.capabilities.any((c) => c.toLowerCase() == 'tools');
  }
}

/// One row in the local Ollama catalog.
///
/// Built from `/api/tags` (size + details) merged with `/api/show`
/// (capabilities). Every entry here represents an *installed* model — Ollama
/// has no public registry endpoint, so the catalog is by definition the set
/// of pulled models.
class OllamaCatalogModel {
  final String name;
  final String digest;
  final int sizeBytes;
  final DateTime? modifiedAt;
  final String family;
  final String parameterSize;
  final String quantizationLevel;
  final String format;
  final List<String> capabilities;

  const OllamaCatalogModel({
    required this.name,
    required this.digest,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.family,
    required this.parameterSize,
    required this.quantizationLevel,
    required this.format,
    required this.capabilities,
  });

  factory OllamaCatalogModel.fromTagJson(Map<String, dynamic> j) {
    final details = (j['details'] is Map)
        ? Map<String, dynamic>.from(j['details'] as Map)
        : const <String, dynamic>{};
    int asInt(dynamic v) =>
        v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);
    DateTime? asDate(dynamic v) =>
        v is String ? DateTime.tryParse(v) : null;
    return OllamaCatalogModel(
      name: (j['name'] as String?) ?? '',
      digest: (j['digest'] as String?) ?? '',
      sizeBytes: asInt(j['size']),
      modifiedAt: asDate(j['modified_at']),
      family: (details['family'] as String?) ?? '',
      parameterSize: (details['parameter_size'] as String?) ?? '',
      quantizationLevel: (details['quantization_level'] as String?) ?? '',
      format: (details['format'] as String?) ?? '',
      capabilities: const [],
    );
  }

  OllamaCatalogModel withCapabilities(List<String> caps) => OllamaCatalogModel(
        name: name,
        digest: digest,
        sizeBytes: sizeBytes,
        modifiedAt: modifiedAt,
        family: family,
        parameterSize: parameterSize,
        quantizationLevel: quantizationLevel,
        format: format,
        capabilities: caps,
      );
}
