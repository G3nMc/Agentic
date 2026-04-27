import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../data/models/message.dart';

/// Client for the OpenRouter chat-completions API.
/// Docs: https://openrouter.ai/docs/api/reference/overview
class OpenRouterService {
  OpenRouterService._();
  static final OpenRouterService instance = OpenRouterService._();

  static const String _appTitle = 'HF Chat Flutter';

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: ApiConstants.openRouterBaseUrl,
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

  /// Fetch the full model catalog from OpenRouter's `/models` endpoint.
  ///
  /// Each entry includes pricing, context window, modalities and the list of
  /// `supported_parameters` (used to detect tool-calling support).
  /// Docs: https://openrouter.ai/docs/api/reference/list-available-models
  Future<List<OpenRouterModel>> listCatalog(String apiKey) async {
    if (apiKey.trim().isEmpty) return const [];
    try {
      final resp = await _dio.get('/models', options: _authOptions(apiKey));
      if (resp.statusCode != 200) return const [];
      final data = resp.data?['data'];
      if (data is! List) return const [];
      return data
          .whereType<Map>()
          .map((m) => OpenRouterModel.fromJson(Map<String, dynamic>.from(m)))
          .where((m) => m.id.isNotEmpty)
          .toList()
        ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  /// Convenience: just the model IDs (used by simple dropdowns).
  /// Returns an empty list when the catalog can't be fetched — callers
  /// should treat that as "no models available" rather than substituting
  /// hardcoded defaults.
  Future<List<String>> listModels(String apiKey) async {
    final cat = await listCatalog(apiKey);
    return cat.map((m) => m.id).toList();
  }

  /// Whether a catalog entry advertises native tool/function calling.
  /// OpenRouter exposes this via `supported_parameters` containing `tools`.
  static bool supportsToolCalling(OpenRouterModel m) {
    return m.supportedParameters.any((p) => p.toLowerCase() == 'tools');
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

}

/// One row from `/models` — rich metadata for a single OpenRouter model.
class OpenRouterModel {
  final String id;
  final String name;
  final String description;
  final int? contextLength;
  final int? maxCompletionTokens;
  final double? promptPricePerToken;
  final double? completionPricePerToken;
  final List<String> inputModalities;
  final List<String> outputModalities;
  final List<String> supportedParameters;
  final bool isModerated;

  const OpenRouterModel({
    required this.id,
    required this.name,
    required this.description,
    required this.contextLength,
    required this.maxCompletionTokens,
    required this.promptPricePerToken,
    required this.completionPricePerToken,
    required this.inputModalities,
    required this.outputModalities,
    required this.supportedParameters,
    required this.isModerated,
  });

  factory OpenRouterModel.fromJson(Map<String, dynamic> j) {
    List<String> asStrList(dynamic v) =>
        v is List ? v.whereType<String>().toList() : const [];
    int? asInt(dynamic v) =>
        v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    double? asDouble(dynamic v) => v == null
        ? null
        : (v is num ? v.toDouble() : double.tryParse('$v'));

    final arch = (j['architecture'] is Map)
        ? Map<String, dynamic>.from(j['architecture'] as Map)
        : const <String, dynamic>{};
    final pricing = (j['pricing'] is Map)
        ? Map<String, dynamic>.from(j['pricing'] as Map)
        : const <String, dynamic>{};
    final topProvider = (j['top_provider'] is Map)
        ? Map<String, dynamic>.from(j['top_provider'] as Map)
        : const <String, dynamic>{};

    return OpenRouterModel(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      description: (j['description'] as String?) ?? '',
      contextLength:
          asInt(j['context_length']) ?? asInt(topProvider['context_length']),
      maxCompletionTokens: asInt(topProvider['max_completion_tokens']),
      promptPricePerToken: asDouble(pricing['prompt']),
      completionPricePerToken: asDouble(pricing['completion']),
      inputModalities: asStrList(arch['input_modalities']),
      outputModalities: asStrList(arch['output_modalities']),
      supportedParameters: asStrList(j['supported_parameters']),
      isModerated: topProvider['is_moderated'] == true,
    );
  }

  /// Marketplace / details URL on openrouter.ai (best-effort, derived from id).
  String get htmlUrl =>
      id.isEmpty ? '' : 'https://openrouter.ai/${Uri.encodeFull(id)}';
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
