import 'dart:async';

import '../data/models/message.dart';
import '../data/repositories/message_repository.dart';
import '../utils/logger.dart';
import 'context_summary_service.dart';
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
  final ContextSummaryService _contextSummaryService =
      ContextSummaryService.instance;

  /// Fraction of the context window reserved for raw history (after the
  /// rolling summary takes its share). 0.70 leaves ~30% for system prompt,
  /// tool catalog, summary, and reply budget. Tuned for "use as much
  /// context as the model offers" — coding sessions specifically benefit
  /// from preserving full file bodies across many turns.
  static const double _historyBudgetFraction = 0.70;

  /// Update the summary asynchronously when the conversation tail exceeds
  /// this fraction of the context window. Below it: no summary needed,
  /// the raw history fits comfortably with room to spare.
  static const double _summaryTriggerFraction = 0.60;

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
    final ctxChars = contextChars ?? ContextSummaryService.defaultContextChars;
    final historyBudget = (ctxChars * _historyBudgetFraction).toInt();
    final summaryCap = ContextSummaryService.summaryCharLimit(ctxChars);
    final summaryTriggerChars = (ctxChars * _summaryTriggerFraction).toInt();

    final allMessages = await _messageRepository.listByConversation(
      conversationId,
    );

    // Existing summary (rolling, persisted between turns).
    final existingSummary = await _contextSummaryService.getContextSummary(
      conversationId,
    );

    // Pack newest-first until we hit the budget. Older messages get
    // represented by the rolling summary instead — this is the key fix:
    // the summary REPLACES old turns, it doesn't sit on top of them.
    final reservedForSummary =
        existingSummary != null ? existingSummary.summaryText.length : 0;
    final packBudget = (historyBudget - reservedForSummary).clamp(
      ctxChars ~/ 10, // floor: at least ~10% of ctx for raw history
      historyBudget,
    );

    final trimmed = _packNewestFirst(allMessages, packBudget);

    // Decide whether to fire an async summary update for next turn.
    // Trigger only when the conversation tail is meaningfully large —
    // no point summarizing a 3-turn chat that fits in context six times over.
    final totalChars = _estimateChars(allMessages);
    final shouldUpdate = totalChars > summaryTriggerChars ||
        existingSummary == null && allMessages.length >= 6;

    if (shouldUpdate) {
      // Fire and forget — does NOT block the foreground reply.
      // ignore: unawaited_futures
      _contextSummaryService.updateContextSummaryAsync(
        conversationId: conversationId,
        messages: allMessages,
        backend: backend,
        modelId: modelId,
        token: token,
        localServerUrl: localServerUrl,
        ollamaBaseUrl: ollamaBaseUrl,
        ollamaModelId: ollamaModelId,
        ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
        maxSummaryChars: summaryCap,
      );
      Logger.logChatProcessing(
        conversationId,
        'queued async summary update (history=${totalChars}c '
        'kept=${trimmed.length}/${allMessages.length})',
      );
    }

    return ProcessedChatRequest(
      historyToSend: trimmed,
      contextSummary: existingSummary?.summaryText,
      asyncSummaryQueued: shouldUpdate,
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
      contextSummary: prepared.contextSummary,
    );
  }

  /// Pack messages newest-first into [budgetChars]. Always keeps the most
  /// recent message (assumed to be the just-asked user question), then
  /// walks backwards adding messages while they fit.
  List<ChatMessage> _packNewestFirst(
      List<ChatMessage> messages, int budgetChars) {
    if (messages.isEmpty) return const [];
    final kept = <ChatMessage>[];
    var used = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final cost = m.content.length + 32; // +32 ≈ role/separator overhead
      // Always keep the last message even if oversized — chopping the
      // current user turn would defeat the whole point of sending it.
      if (kept.isEmpty) {
        kept.add(m);
        used += cost;
        continue;
      }
      if (used + cost > budgetChars) break;
      kept.add(m);
      used += cost;
    }
    return kept.reversed.toList(growable: false);
  }

  int _estimateChars(List<ChatMessage> messages) {
    var total = 0;
    for (final m in messages) {
      total += m.content.length;
    }
    return total;
  }
}

class ProcessedChatRequest {
  /// The trimmed history to pass to [LlmService.sendChat]. Newest-first
  /// budget-packed; older messages are represented by [contextSummary].
  final List<ChatMessage> historyToSend;

  /// Rolling summary covering everything that didn't fit in
  /// [historyToSend]. Pass to [LlmService.sendChat]'s `contextSummary:`
  /// parameter — it'll be injected as a system message.
  final String? contextSummary;

  /// True when an async update was queued; the next turn will see a
  /// fresher summary. Informational — doesn't affect the current call.
  final bool asyncSummaryQueued;

  ProcessedChatRequest({
    required this.historyToSend,
    required this.contextSummary,
    required this.asyncSummaryQueued,
  });
}
