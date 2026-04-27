import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../data/models/message.dart';

/// Client for the Groq Cloud API (OpenAI-compatible).
/// Docs: https://console.groq.com/docs/api-reference#chat-create
class GroqService {
  GroqService._();
  static final GroqService instance = GroqService._();

  final Dio _dio = Dio(BaseOptions(
    baseUrl: ApiConstants.groqBaseUrl,
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 5),
    headers: {'Content-Type': 'application/json'},
  ));

  Options _authOptions(String apiKey) => Options(
        headers: {'Authorization': 'Bearer $apiKey'},
        validateStatus: (_) => true,
      );

  /// Fetch available model IDs from the Groq /models endpoint.
  Future<List<String>> listModels(String apiKey) async {
    final cat = await listCatalog(apiKey);
    if (cat.isEmpty) return fallbackModels;
    return cat.map((m) => m.id).toList();
  }

  /// Fetch the full model catalog with all metadata Groq exposes.
  /// Returns an empty list when the key is missing or the request fails.
  Future<List<GroqModel>> listCatalog(String apiKey) async {
    if (apiKey.trim().isEmpty) return const [];
    try {
      final resp = await _dio.get('/models', options: _authOptions(apiKey));
      if (resp.statusCode != 200) return const [];
      final data = resp.data?['data'] as List? ?? [];
      return data
          .whereType<Map>()
          .map((m) => GroqModel.fromJson(Map<String, dynamic>.from(m)))
          .toList()
        ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  /// Send a chat request and return the assistant reply.
  Future<String> sendChat({
    required String apiKey,
    required String modelId,
    required List<ChatMessage> history,
    double temperature = 0.7,
    int? maxTokens,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('Groq API key is not set.');
    if (modelId.trim().isEmpty) throw Exception('No Groq model selected.');

    final messages = history.map((m) => m.toApiMap()).toList();

    final body = <String, dynamic>{
      'model': modelId,
      'messages': messages,
      'temperature': temperature,
    };
    if (maxTokens != null && maxTokens > 0) {
      body['max_completion_tokens'] = maxTokens;
    }

    final resp = await _dio.post(
      '/chat/completions',
      data: body,
      options: _authOptions(apiKey),
    );

    if (resp.statusCode != 200) {
      final err = (resp.data is Map ? resp.data['error'] : null);
      final msg = err is Map
          ? err['message'] ?? err.toString()
          : resp.data?.toString() ?? 'HTTP ${resp.statusCode}';
      throw Exception('Groq error ${resp.statusCode}: $msg');
    }

    final choices = resp.data?['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('Groq returned no choices: ${resp.data}');
    }
    final content = choices.first?['message']?['content'] as String?;
    if (content == null || content.isEmpty) {
      throw Exception('Groq returned empty content: ${resp.data}');
    }
    return stripThink(content);
  }

  /// Strip `<think>…</think>` reasoning blocks emitted by DeepSeek-R1, QwQ, etc.
  @visibleForTesting
  static String stripThink(String text) {
    return text
        .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true, caseSensitive: false), '')
        .trim();
  }

  /// Well-known models shown when /models is unreachable.
  static const List<String> fallbackModels = [
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
    'mixtral-8x7b-32768',
    'gemma2-9b-it',
    'deepseek-r1-distill-llama-70b',
    'qwen-qwq-32b',
  ];

  /// Models that support Groq's native tool/function-calling API.
  ///
  /// Reasoning models (DeepSeek-R1, QwQ, etc.) do NOT support the
  /// `tools` parameter and must not be offered for the Groq Orchestrator
  /// backend, which relies on tool calls to perform filesystem operations.
  ///
  /// The orchestrator falls back to a text-based < tool >…< /tool > protocol
  /// when a model rejects native tool calling, but reasoning models are
  /// generally unreliable at following structured tool instructions anyway.
  static const List<String> toolCapableModels = [
    'llama-3.3-70b-versatile',
    'llama-3.1-8b-instant',
    'mixtral-8x7b-32768',
    'gemma2-9b-it',
    'llama3-70b-8192',
    'llama3-8b-8192',
    'gemma-7b-it',
  ];

  /// Returns true if [modelId] is known to support native tool calling on Groq.
  /// Unknown / new models are assumed to support tools (Groq keeps adding them).
  static bool supportsToolCalling(String modelId) {
    // Reasoning models are the known non-starters.
    const noToolModels = {
      'deepseek-r1-distill-llama-70b',
      'deepseek-r1-distill-qwen-32b',
      'deepseek-r1-distill-qwen-14b',
      'qwen-qwq-32b',
    };
    if (noToolModels.contains(modelId)) return false;
    // Any model whose name hints at being a reasoning model.
    final lower = modelId.toLowerCase();
    if (lower.contains('deepseek-r1') || lower.contains('qwq')) return false;
    return true;
  }
}

/// One row from Groq's `/openai/v1/models` endpoint.
///
/// Groq returns OpenAI-compatible metadata only — no pricing — so this is the
/// full set of useful fields. Pricing lives on console.groq.com.
class GroqModel {
  final String id;
  final String ownedBy;
  final bool active;
  final int? contextWindow;
  final int? maxCompletionTokens;
  final int? created;

  const GroqModel({
    required this.id,
    required this.ownedBy,
    required this.active,
    required this.contextWindow,
    required this.maxCompletionTokens,
    required this.created,
  });

  factory GroqModel.fromJson(Map<String, dynamic> j) {
    int? asInt(dynamic v) =>
        v is num ? v.toInt() : (v == null ? null : int.tryParse('$v'));
    return GroqModel(
      id: (j['id'] as String?) ?? '',
      ownedBy: (j['owned_by'] as String?) ?? '',
      active: j['active'] is bool ? j['active'] as bool : true,
      contextWindow: asInt(j['context_window']),
      maxCompletionTokens: asInt(j['max_completion_tokens']),
      created: asInt(j['created']),
    );
  }
}
