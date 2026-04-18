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
                "role": m.role == MessageRole.user ? "user" : "assistant",
                "content": m.content,
              })
          .toList();

      // Support both OpenAI-compatible and custom endpoints
      final response = await _dio.post(
        "$serverUrl/v1/chat/completions",
        options: Options(
          headers: {"Content-Type": "application/json"},
          receiveTimeout: const Duration(minutes: 30),
          sendTimeout: const Duration(minutes: 30),
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
        final content = response.data["choices"]?[0]?["message"]?["content"] as String?;
        if (content != null) return content;
      }

      throw Exception("Invalid response from local server: ${response.data}");
    } on DioException catch (e) {
      throw Exception("Local LLM error: ${e.message}");
    }
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
