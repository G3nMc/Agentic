import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/models/message.dart';

/// Client for the OpenRouter chat-completions API.
/// Docs: https://openrouter.ai/docs/api/reference/overview
class OpenRouterService {
  OpenRouterService._();
  static final OpenRouterService instance = OpenRouterService._();

  static const String _baseUrl = 'https://openrouter.ai/api/v1';
  static const String _appTitle = 'HF Chat Flutter';

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      headers: {'Content-Type': 'application/json'},
    ),
  );

  Options _authOptions(String apiKey) => Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'X-OpenRouter-Title': _appTitle,
        },
        validateStatus: (_) => true,
      );

  /// Fetch credit/usage info for the current API key.
  /// Docs: https://openrouter.ai/docs/api/reference/limits
  Future<OpenRouterKeyInfo?> fetchKeyInfo(String apiKey) async {
    if (apiKey.trim().isEmpty) return null;
    try {
      final resp = await _dio.get('/key', options: _authOptions(apiKey));
      if (resp.statusCode != 200) return null;
      final data = resp.data?['data'];
      if (data is! Map) return null;
      return OpenRouterKeyInfo.fromJson(Map<String, dynamic>.from(data));
    } catch (_) {
      return null;
    }
  }

  /// Fetch available model IDs from OpenRouter's `/models` endpoint.
  Future<List<String>> listModels(String apiKey) async {
    if (apiKey.trim().isEmpty) return fallbackModels;

    try {
      final resp = await _dio.get('/models', options: _authOptions(apiKey));
      if (resp.statusCode != 200) return fallbackModels;
      final data = resp.data?['data'] as List? ?? [];
      final ids = data
          .map((m) => m is Map ? m['id'] as String? : null)
          .whereType<String>()
          .toSet()
          .toList()
        ..sort();
      return ids.isEmpty ? fallbackModels : ids;
    } catch (_) {
      return fallbackModels;
    }
  }

  /// Send a chat-completions request and return the assistant reply.
  Future<String> sendChat({
    required String apiKey,
    required String modelId,
    required List<ChatMessage> history,
    double temperature = 0.7,
    int? maxTokens,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('OpenRouter API key is not set.');
    }
    if (modelId.trim().isEmpty) {
      throw Exception('No OpenRouter model selected.');
    }
    if (history.isEmpty) {
      throw Exception('Cannot send an empty conversation.');
    }

    final body = <String, dynamic>{
      'model': modelId,
      'messages': history.map((m) => m.toApiMap()).toList(),
      'temperature': temperature,
    };
    if (maxTokens != null && maxTokens > 0) {
      body['max_tokens'] = maxTokens;
    }

    final resp = await _dio.post(
      '/chat/completions',
      data: body,
      options: _authOptions(apiKey),
    );

    if (resp.statusCode != 200) {
      throw Exception(
        'OpenRouter error ${resp.statusCode}: ${_errorMessage(resp.data)}',
      );
    }

    final choices = resp.data?['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw Exception('OpenRouter returned no choices: ${resp.data}');
    }

    final first = choices.first;
    if (first is Map && first['error'] is Map) {
      final error = first['error'] as Map;
      throw Exception(
        'OpenRouter choice error: ${error['message'] ?? error.toString()}',
      );
    }

    final message =
        first is Map ? first['message'] as Map<String, dynamic>? : null;
    final content = message?['content'];
    if (content is String && content.trim().isNotEmpty) {
      return stripThink(content);
    }

    final text = first is Map ? first['text'] as String? : null;
    if (text != null && text.trim().isNotEmpty) {
      return stripThink(text);
    }

    throw Exception('OpenRouter returned empty content: ${resp.data}');
  }

  String _errorMessage(dynamic payload) {
    if (payload is Map) {
      final error = payload['error'];
      if (error is Map && error['message'] != null) {
        return error['message'].toString();
      }
      if (error != null) return error.toString();
    }
    return payload?.toString() ?? 'Unknown error';
  }

  /// Strip `<think>...</think>` blocks some reasoning models include.
  @visibleForTesting
  static String stripThink(String text) {
    return text
        .replaceAll(
          RegExp(
            r'<think>.*?</think>',
            dotAll: true,
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  /// Small fallback list used when `/models` is unreachable.
  static const List<String> fallbackModels = [
    'google/gemini-2.5-flash',
    'openai/gpt-5-mini',
    'anthropic/claude-sonnet-4.5',
  ];
}

/// Snapshot of `/api/v1/key` — credit + usage info for the current API key.
class OpenRouterKeyInfo {
  final String label;
  final double? limit;
  final double? limitRemaining;
  final String? limitReset;
  final double usage;
  final double usageDaily;
  final double usageWeekly;
  final double usageMonthly;
  final bool isFreeTier;

  const OpenRouterKeyInfo({
    required this.label,
    required this.limit,
    required this.limitRemaining,
    required this.limitReset,
    required this.usage,
    required this.usageDaily,
    required this.usageWeekly,
    required this.usageMonthly,
    required this.isFreeTier,
  });

  factory OpenRouterKeyInfo.fromJson(Map<String, dynamic> j) {
    double? asDouble(dynamic v) =>
        v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
    return OpenRouterKeyInfo(
      label: (j['label'] as String?) ?? '',
      limit: asDouble(j['limit']),
      limitRemaining: asDouble(j['limit_remaining']),
      limitReset: j['limit_reset'] as String?,
      usage: asDouble(j['usage']) ?? 0,
      usageDaily: asDouble(j['usage_daily']) ?? 0,
      usageWeekly: asDouble(j['usage_weekly']) ?? 0,
      usageMonthly: asDouble(j['usage_monthly']) ?? 0,
      isFreeTier: j['is_free_tier'] == true,
    );
  }
}
