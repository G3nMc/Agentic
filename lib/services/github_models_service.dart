import 'package:dio/dio.dart';

import '../core/constants/api_constants.dart';

/// Client for the GitHub Models REST API.
///
/// - Catalog: `GET https://models.github.ai/catalog/models`
/// - Inference (chat): `POST https://models.github.ai/inference/chat/completions`
///   (OpenAI-compatible; called from the Python orchestrator, not from here).
///
/// Auth uses a fine-grained GitHub PAT with the `models:read` scope.
/// Docs: https://docs.github.com/en/rest/models/inference?apiVersion=2026-03-10
class GithubModelsService {
  GithubModelsService._();
  static final GithubModelsService instance = GithubModelsService._();

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: ApiConstants.githubModelsBaseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 2),
      headers: {'Content-Type': 'application/json'},
    ),
  );

  Options _authOptions(String apiKey) => Options(
        headers: {
          'Authorization': 'Bearer $apiKey',
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': ApiConstants.githubModelsApiVersion,
        },
        validateStatus: (_) => true,
      );

  /// Fetch the full model catalog with all metadata.
  Future<List<GithubModel>> listCatalog(String apiKey) async {
    if (apiKey.trim().isEmpty) return const [];
    try {
      final resp = await _dio.get(
        ApiConstants.githubModelsCatalogPath,
        options: _authOptions(apiKey),
      );
      if (resp.statusCode != 200) return const [];
      final data = resp.data;
      if (data is! List) return const [];
      return data
          .whereType<Map>()
          .map((m) => GithubModel.fromJson(Map<String, dynamic>.from(m)))
          .toList()
        ..sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    } catch (_) {
      return const [];
    }
  }

  /// Convenience: just the model IDs (used by the dropdown).
  Future<List<String>> listModels(String apiKey) async {
    final cat = await listCatalog(apiKey);
    if (cat.isEmpty) return fallbackModels;
    return cat.map((m) => m.id).toList();
  }

  /// Small fallback list used before the catalog has been fetched.
  static const List<String> fallbackModels = [
    'openai/gpt-4.1-mini',
    'openai/gpt-4o-mini',
    'openai/gpt-5-mini',
  ];

  /// Whether a model in the catalog supports tool/function calling.
  /// Used by the orchestrator path to filter the dropdown.
  static bool supportsToolCalling(GithubModel m) {
    return m.capabilities.any((c) => c.toLowerCase() == 'tool-calling');
  }
}

/// One row from `/catalog/models`.
class GithubModel {
  final String id;
  final String name;
  final String publisher;
  final String summary;
  final String rateLimitTier;
  final String registry;
  final String version;
  final String htmlUrl;
  final List<String> capabilities;
  final List<String> tags;
  final List<String> supportedInputModalities;
  final List<String> supportedOutputModalities;
  final int? maxInputTokens;
  final int? maxOutputTokens;

  const GithubModel({
    required this.id,
    required this.name,
    required this.publisher,
    required this.summary,
    required this.rateLimitTier,
    required this.registry,
    required this.version,
    required this.htmlUrl,
    required this.capabilities,
    required this.tags,
    required this.supportedInputModalities,
    required this.supportedOutputModalities,
    required this.maxInputTokens,
    required this.maxOutputTokens,
  });

  factory GithubModel.fromJson(Map<String, dynamic> j) {
    List<String> asStrList(dynamic v) =>
        v is List ? v.whereType<String>().toList() : const [];
    final limits = (j['limits'] is Map)
        ? Map<String, dynamic>.from(j['limits'] as Map)
        : const <String, dynamic>{};
    int? asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return GithubModel(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      publisher: (j['publisher'] as String?) ?? '',
      summary: (j['summary'] as String?) ?? '',
      rateLimitTier: (j['rate_limit_tier'] as String?) ?? '',
      registry: (j['registry'] as String?) ?? '',
      version: (j['version'] as String?) ?? '',
      htmlUrl: (j['html_url'] as String?) ?? '',
      capabilities: asStrList(j['capabilities']),
      tags: asStrList(j['tags']),
      supportedInputModalities: asStrList(j['supported_input_modalities']),
      supportedOutputModalities: asStrList(j['supported_output_modalities']),
      maxInputTokens: asInt(limits['max_input_tokens']),
      maxOutputTokens: asInt(limits['max_output_tokens']),
    );
  }
}
