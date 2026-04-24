import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../data/models/message.dart';

/// Thin wrapper around Ollama's `/api/generate` endpoint.
///
/// Unlike `/api/chat` (which takes a structured `messages` array), `/api/generate`
/// accepts a single raw `prompt` string and a separate `system` field.
/// Conversation history is formatted manually into the prompt text.
///
/// This backend is useful when:
///   • Your model server only exposes `/api/generate` (e.g. a custom port like
///     `localhost:12345`).
///   • You want the `think` parameter for native reasoning output.
///   • You prefer raw completion semantics over chat-formatted requests.
///
/// Streaming is used by default so the UI stays responsive and long-running
/// local models don't hit Dart-side timeouts.
class OllamaGenerateService {
  OllamaGenerateService._();

  static final OllamaGenerateService instance = OllamaGenerateService._();

  static const String defaultBaseUrl = 'http://localhost:11434';

  final Dio _dio = Dio();

  String _normalise(String base) {
    var b = base.trim();
    if (b.isEmpty) b = defaultBaseUrl;
    if (b.endsWith('/')) b = b.substring(0, b.length - 1);
    // Accept bare "hostname:port" or "localhost:12345" without scheme.
    if (!b.startsWith('http')) b = 'http://$b';
    return b;
  }

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

  Future<bool> isServerReachable({String? baseUrl, String? apiKey}) async {
    final url = _normalise(baseUrl ?? defaultBaseUrl);
    try {
      final resp = await _dio.get(
        '$url/api/tags',
        options: Options(
          headers: _headers(apiKey: apiKey),
          receiveTimeout: const Duration(seconds: 5),
          sendTimeout: const Duration(seconds: 5),
          validateStatus: (_) => true,
        ),
      );
      // Some minimal /api/generate servers don't implement /api/tags — a 404
      // still means the server is reachable.
      return resp.statusCode != null && resp.statusCode! < 500;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Chat via /api/generate  (streaming)
  // ---------------------------------------------------------------------------

  /// Send [history] to `/api/generate` and return the full assistant reply.
  ///
  /// The endpoint only takes a single `prompt` string, so we serialise the
  /// conversation history ourselves using a simple "User / Assistant" template
  /// that most instruct-tuned models already understand.
  ///
  /// [enableThinking] passes `"think": true` which makes supported reasoning
  /// models (e.g. deepseek-r1, qwq) return their chain-of-thought inside
  /// `<think>…</think>` tags in the response text — the Flutter UI will render
  /// these as a collapsible "Reasoning" block automatically.
  Future<String> sendChat({
    required String modelId,
    required List<ChatMessage> history,
    String? baseUrl,
    String? apiKey,
    double temperature = 0.7,
    int? numPredict,
    int numCtx = 4096,
    bool enableThinking = false,
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

    final body = <String, Object?>{
      'model': modelId,
      'prompt': prompt,
      'stream': true, // stream for live tokens & no timeout
      'options': <String, Object?>{
        'temperature': temperature,
        'num_ctx': numCtx,
        if (numPredict != null) 'num_predict': numPredict,
      },
    };
    if (systemText.isNotEmpty) body['system'] = systemText;
    if (enableThinking) body['think'] = true;

    try {
      final resp = await _dio.post<ResponseBody>(
        '$url/api/generate',
        data: jsonEncode(body),
        options: Options(
          responseType: ResponseType.stream,
          headers: _headers(apiKey: apiKey),
          // No receive timeout — local models can take many minutes.
          // The user can cancel via the stop button in the UI.
          receiveTimeout: Duration.zero,
          sendTimeout: const Duration(minutes: 1),
          validateStatus: (_) => true,
        ),
      );

      if (resp.statusCode != 200) {
        // Try to read the error body from the stream.
        String errBody = '';
        try {
          final chunks = <int>[];
          await resp.data!.stream.listen((c) => chunks.addAll(c)).asFuture();
          errBody = utf8.decode(chunks, allowMalformed: true);
        } catch (_) {}
        throw Exception(
          'Ollama /api/generate returned ${resp.statusCode}: $errBody',
        );
      }

      return await _readStream(resp.data!);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionError) {
        throw Exception(
          'Cannot reach Ollama generate endpoint at $url. '
          'Make sure the server is running on that address/port.',
        );
      }
      throw Exception('Ollama generate error: ${e.message}');
    }
  }

  // ---------------------------------------------------------------------------
  // Stream reader
  // ---------------------------------------------------------------------------

  /// Read Ollama's newline-delimited JSON stream and assemble the full reply.
  ///
  /// Each line is a JSON object with at minimum `{"response":"…","done":false}`.
  /// When `done` is true the stream ends. The `thinking` field (if present)
  /// carries chain-of-thought text that we wrap in `<think>…</think>` tags so
  /// the Flutter UI's `_ReasoningBlock` widget picks it up automatically.
  Future<String> _readStream(ResponseBody body) async {
    final buffer = StringBuffer(); // incomplete-line carry-over
    final response = StringBuffer(); // accumulated response text
    final thinking = StringBuffer(); // accumulated thinking text (if any)

    await for (final chunk in body.stream) {
      buffer.write(utf8.decode(chunk, allowMalformed: true));
      final raw = buffer.toString();
      final lines = raw.split('\n');

      // Last element may be an incomplete line — keep it for the next chunk.
      buffer.clear();
      buffer.write(lines.removeLast());

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final obj = jsonDecode(trimmed) as Map<String, dynamic>;
          // Accumulate thinking text (deepseek-r1, qwq, etc.)
          final thinkChunk = obj['thinking'] as String? ?? '';
          if (thinkChunk.isNotEmpty) thinking.write(thinkChunk);
          // Accumulate response text
          final chunk = obj['response'] as String? ?? '';
          if (chunk.isNotEmpty) response.write(chunk);
          // Error mid-stream
          if (obj['error'] is String) {
            throw Exception('Ollama generate error: ${obj['error']}');
          }
        } catch (e) {
          if (e is Exception && e.toString().contains('Ollama generate error')) {
            rethrow;
          }
          // Non-JSON line — ignore silently.
        }
      }
    }

    // Flush any trailing partial line.
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      try {
        final obj = jsonDecode(tail) as Map<String, dynamic>;
        final thinkChunk = obj['thinking'] as String? ?? '';
        if (thinkChunk.isNotEmpty) thinking.write(thinkChunk);
        final chunk = obj['response'] as String? ?? '';
        if (chunk.isNotEmpty) response.write(chunk);
      } catch (_) {}
    }

    // If the model returned a separate `thinking` field, wrap it so the UI
    // renders it as a collapsible reasoning block.
    final thinkText = thinking.toString().trim();
    final responseText = response.toString().trim();
    if (thinkText.isNotEmpty) {
      return '<think>$thinkText</think>\n\n$responseText';
    }
    return responseText;
  }

  // ---------------------------------------------------------------------------
  // Prompt builder
  // ---------------------------------------------------------------------------

  /// Format [turns] (user + assistant messages) into a single prompt string.
  ///
  /// Most instruct-tuned models respond correctly to the simple
  /// "User: … \nAssistant: …\nUser: …\nAssistant:" template even without
  /// explicit chat tokens, because their training data uses this format.
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
          // System messages inside the conversation are rare but possible.
          sb.write('[System: ${m.content}]\n');
          break;
      }
    }
    // Prompt the model to reply as the assistant.
    sb.write('Assistant:');
    return sb.toString();
  }
}
