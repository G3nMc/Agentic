import 'package:dio/dio.dart';

import '../core/constants/api_constants.dart';
import '../data/models/message.dart';

class HuggingFaceException implements Exception {
  final String message;
  final int? statusCode;
  final Object? raw;

  HuggingFaceException(this.message, {this.statusCode, this.raw});

  @override
  String toString() {
    if (statusCode != null) {
      return "HuggingFaceException($statusCode): $message";
    }
    return "HuggingFaceException: $message";
  }
}

class HuggingFaceService {
  HuggingFaceService._() {
    _dio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.hfRouterBaseUrl,
        connectTimeout: ApiConstants.connectTimeout,
        receiveTimeout: ApiConstants.receiveTimeout,
        headers: {
          "Content-Type": "application/json",
        },
      ),
    );
  }

  static final HuggingFaceService instance = HuggingFaceService._();

  late final Dio _dio;

  // Sends the full conversation history to the HF router, exactly like HF.html:
  //   messages: [ {role, content}, ... ]
  // Returns the assistant reply content as a plain string.
  Future<String> sendChat({
    required String token,
    required String modelId,
    required List<ChatMessage> history,
  }) async {
    if (token.trim().isEmpty) {
      throw HuggingFaceException("Missing Hugging Face token.");
    }
    if (modelId.trim().isEmpty) {
      throw HuggingFaceException("Missing model id.");
    }
    if (history.isEmpty) {
      throw HuggingFaceException("Cannot send an empty conversation.");
    }

    final apiMessages = history.map((m) => m.toApiMap()).toList(growable: false);

    try {
      final response = await _dio.post(
        ApiConstants.chatCompletionsPath,
        options: Options(
          headers: {
            "Authorization": "Bearer $token",
          },
          responseType: ResponseType.json,
        ),
        data: {
          "model": modelId,
          "messages": apiMessages,
        },
      );

      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw HuggingFaceException(
          "Unexpected response payload type: ${data.runtimeType}",
          statusCode: response.statusCode,
          raw: data,
        );
      }

      // HF.html fallback: if no choices[0].message.content, dump the full JSON.
      final choices = data["choices"];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map<String, dynamic>) {
          final message = first["message"];
          if (message is Map<String, dynamic>) {
            final content = message["content"];
            if (content is String && content.isNotEmpty) {
              return content;
            }
          }
        }
      }

      // Fallback stringified payload, matching the HF.html behaviour.
      return data.toString();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      String details;
      if (body is Map && body["error"] != null) {
        details = body["error"].toString();
      } else if (body != null) {
        details = body.toString();
      } else {
        details = e.message ?? "network error";
      }
      throw HuggingFaceException(details, statusCode: status, raw: body);
    } catch (e) {
      throw HuggingFaceException(e.toString());
    }
  }
}
