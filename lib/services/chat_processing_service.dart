import 'dart:async';

import '../data/models/message.dart';
import '../data/repositories/message_repository.dart';
import 'llm_service.dart';

/// Canonical chat processor.
///
/// Builds the request the chat-view widget will hand to [LlmService.sendChat].
/// The summary REPLACES older history (it isn't appended), and the kept
/// history is packed newest-first by char budget rather than a fixed message
/// count. Triggers an async summary update only when the conversation has
/// crossed a context-pressure threshold — small chats stay zero-overhead.
class ChatProcessingService {
  ChatProcessingService._();

  static final ChatProcessingService instance = ChatProcessingService._();

  final MessageRepository _messageRepository = MessageRepository.instance;

  /// Build the request to send. The caller is responsible for invoking
  /// [LlmService.sendChat] with the returned `historyToSend` and
  /// `contextSummary`.
  Future<ProcessedChatRequest> prepareRequest({
    required String conversationId,
    required String userMessage,
    required LlmBackend backend,
    required String modelId,
    String? token,
    String? localServerUrl,
    String? ollamaBaseUrl,
    String? ollamaModelId,
    String? ollamaPythonBridgeUrl,
    int? contextChars,
  }) async {
    final allMessages = await _messageRepository.listByConversation(
      conversationId,
    );

    return ProcessedChatRequest(
      historyToSend: allMessages,
    );
  }

  /// Convenience wrapper that prepares the request and forwards it to
  /// [LlmService.sendChat]. Returns the assistant's reply.
  Future<String> sendWithContext({
    required String conversationId,
    required String userMessage,
    required LlmBackend backend,
    required String modelId,
    String? token,
    String? localServerUrl,
    String? ollamaBaseUrl,
    String? ollamaModelId,
    String? ollamaPythonBridgeUrl,
    int? contextChars,
  }) async {
    final prepared = await prepareRequest(
      conversationId: conversationId,
      userMessage: userMessage,
      backend: backend,
      modelId: modelId,
      token: token,
      localServerUrl: localServerUrl,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaModelId: ollamaModelId,
      ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
      contextChars: contextChars,
    );
    return LlmService.instance.sendChat(
      backend: backend,
      token: token ?? '',
      modelId: modelId,
      history: prepared.historyToSend,
      conversationId: conversationId,
      localServerUrl: localServerUrl,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaModelId: ollamaModelId,
      ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
    );
  }
}

class ProcessedChatRequest {
  /// The full history to pass to [LlmService.sendChat].
  final List<ChatMessage> historyToSend;

  ProcessedChatRequest({
    required this.historyToSend,
  });
}
