import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/task_queue.dart';
import '../data/models/context_summary.dart';
import '../data/models/message.dart';
import '../data/repositories/context_summary_repository.dart';
import '../data/repositories/message_repository.dart';
import '../utils/circuit_breaker.dart';
import '../utils/logger.dart';
import '../utils/retry_handler.dart';
import 'llm_service.dart';

/// Canonical context-summary service.
///
/// Builds and persists a rolling per-conversation summary that the chat
/// processor can prepend (as a system message) to the model call. Sized so a
/// 128K cloud-model window isn't throttled by an 8K-Ollama-era constant —
/// every cap is derived from the model's actual context window.
///
/// The summarizer prompt is coding-aware: it preserves file paths,
/// identifiers, error messages, and decisions verbatim, mirroring the rules
/// in `bin/agent/core/workflow.py::_build_summarizer`.
class ContextSummaryService {
  ContextSummaryService._();

  static final ContextSummaryService instance = ContextSummaryService._();

  final ContextSummaryRepository _repository = ContextSummaryRepository.instance;
  final TaskQueue _taskQueue = TaskQueue(concurrency: 2);
  final RetryHandler _retryHandler = RetryHandler(maxRetries: 2);
  final CircuitBreaker _circuitBreaker = CircuitBreaker(
    maxFailures: 5,
    resetTimeout: const Duration(minutes: 5),
  );

  /// Default context-window assumption when the caller doesn't pass one.
  /// 128K tokens × 4 chars/token ≈ 512K chars — matches the user's
  /// observed cloud-model setup. Callers can override per request.
  static const int defaultContextChars = 512000;

  /// Compute a sane summary char cap from the active context window.
  /// Caps the summary at ~25% of the window — the history packer at
  /// 0.70 of context leaves ~30% for system prompt + tool catalog + reply,
  /// and the summary fits inside the history slice. Smaller summary +
  /// larger raw-history slice means more recent context arrives verbatim,
  /// which matters most for coding sessions.
  static int summaryCharLimit(int contextChars) {
    if (contextChars <= 0) contextChars = defaultContextChars;
    final cap = (contextChars * 0.25).toInt();
    // Floor: even on a tiny model, keep at least 4K chars so the summary
    // can carry forward something useful. Ceiling lifted to 200K chars
    // (~50K tokens) so 1M-token Gemini windows aren't artificially capped.
    return cap.clamp(4000, 200000);
  }

  /// Coding-aware summarizer prompt. Mirrors the rules used by the
  /// Python multi-agent compactor so cross-runtime behavior stays consistent.
  static const String _summarizerSystemPrompt = '''
You are a context-compaction agent. Read the conversation excerpt and produce a dense, faithful summary that preserves every fact a downstream coding agent would need.

RULES:
  - Keep file paths, function/class names, identifiers, and error messages VERBATIM.
  - Keep the user's standing requests and any decisions made.
  - Keep tool-result findings as concise notes ("read lib/foo.dart, 812 lines: defines class Bar with method baz()").
  - Replace large file contents with one-line notes; never paste the full file body.
  - Drop greetings, filler, repeated tool listings, retries.
  - Plain text only. No markdown headers, no code fences. Stay under the requested character cap.''';

  /// Produce a fresh summary from a conversation tail.
  ///
  /// [maxSummaryChars] caps the output. If the raw text is already shorter
  /// than the cap and there's no [previousSummary], returns it as-is —
  /// no LLM call.
  Future<ContextSummaryResult> summarizeContext({
    required String conversationId,
    required List<ChatMessage> messages,
    required LlmBackend backend,
    required String modelId,
    String? token,
    String? localServerUrl,
    String? ollamaBaseUrl,
    String? ollamaModelId,
    String? ollamaPythonBridgeUrl,
    int? maxSummaryChars,
    String? previousSummary,
  }) async {
    final cap = maxSummaryChars ?? summaryCharLimit(defaultContextChars);
    final raw = _renderConversation(messages);

    // Cheap path: short enough already and no prior summary to merge.
    if (previousSummary == null && raw.length <= cap) {
      return ContextSummaryResult(summaryText: raw, wasTruncated: false);
    }

    final userPrompt = _buildIncrementalPrompt(
      previousSummary: previousSummary,
      newExcerpt: raw,
      cap: cap,
    );

    try {
      final summary = await _circuitBreaker.call(() async {
        return _retryHandler.executeWithRetry(() async {
          Logger.logContextSummary(conversationId, 'summarizer LLM call');
          return LlmService.instance.sendChat(
            backend: backend,
            token: token ?? '',
            modelId: modelId,
            history: [
              ChatMessage(
                id: 'system-summary-prompt',
                conversationId: conversationId,
                role: MessageRole.system,
                content: _summarizerSystemPrompt,
                createdAt: DateTime.now().millisecondsSinceEpoch,
              ),
              ChatMessage(
                id: 'user-summary-request',
                conversationId: conversationId,
                role: MessageRole.user,
                content: userPrompt,
                createdAt: DateTime.now().millisecondsSinceEpoch,
              ),
            ],
            localServerUrl: localServerUrl,
            ollamaBaseUrl: ollamaBaseUrl,
            ollamaModelId: ollamaModelId,
            ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
          );
        });
      });

      final clipped = summary.length > cap
          ? '${summary.substring(0, cap)}\n[... truncated to fit summary cap ...]'
          : summary;
      return ContextSummaryResult(summaryText: clipped, wasTruncated: true);
    } catch (e, st) {
      Logger.error(
        'Context summarization failed for $conversationId',
        e is Exception ? e : Exception(e.toString()),
      );
      debugPrint('Stack trace: $st');
      // Fallback: keep the previous summary if we have one; else crude
      // tail truncation. Don't return empty — that wipes accumulated state.
      if (previousSummary != null && previousSummary.isNotEmpty) {
        return ContextSummaryResult(
          summaryText: previousSummary,
          wasTruncated: false,
        );
      }
      final tail = raw.length > cap ? raw.substring(raw.length - cap) : raw;
      return ContextSummaryResult(summaryText: tail, wasTruncated: true);
    }
  }

  /// Schedule an async summary update via the task queue. Does NOT block
  /// the foreground chat call — fire-and-forget.
  Future<void> updateContextSummaryAsync({
    required String conversationId,
    required List<ChatMessage> messages,
    required LlmBackend backend,
    required String modelId,
    String? token,
    String? localServerUrl,
    String? ollamaBaseUrl,
    String? ollamaModelId,
    String? ollamaPythonBridgeUrl,
    int? maxSummaryChars,
  }) {
    return _taskQueue.add<void>(() async {
      try {
        final existing = await _repository.getByConversationId(conversationId);
        final result = await summarizeContext(
          conversationId: conversationId,
          messages: messages,
          backend: backend,
          modelId: modelId,
          token: token,
          localServerUrl: localServerUrl,
          ollamaBaseUrl: ollamaBaseUrl,
          ollamaModelId: ollamaModelId,
          ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
          maxSummaryChars: maxSummaryChars,
          previousSummary: existing?.summaryText,
        );
        final currentMessages =
            await MessageRepository.instance.listByConversation(conversationId);
        if (!_messageSnapshotStillPrefix(messages, currentMessages)) {
          Logger.logContextSummary(
            conversationId,
            'discarded stale async summary; messages changed while summarizing',
          );
          return;
        }
        if (result.summaryText.isNotEmpty) {
          await _persist(conversationId, result.summaryText);
        }
        Logger.logContextSummary(
          conversationId,
          'async summary updated (${result.summaryText.length} chars)',
        );
      } catch (e, st) {
        Logger.error(
          'Async context summary update failed for $conversationId',
          e is Exception ? e : Exception(e.toString()),
        );
        debugPrint('Stack trace: $st');
      }
    });
  }

  Future<ContextSummary?> getContextSummary(String conversationId) {
    return _repository.getByConversationId(conversationId);
  }

  Future<void> deleteContextSummary(String conversationId) {
    return _repository.deleteByConversationId(conversationId);
  }

  Future<void> _persist(String conversationId, String summaryText) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _repository.getByConversationId(conversationId);
    final summary = existing == null
        ? ContextSummary(
            conversationId: conversationId,
            summaryText: summaryText,
            createdAt: now,
            updatedAt: now,
          )
        : existing.copyWith(summaryText: summaryText, updatedAt: now);
    await _repository.save(summary);
  }

  String _renderConversation(List<ChatMessage> messages) {
    final buffer = StringBuffer();
    for (final m in messages) {
      final role = m.role.toString().split('.').last;
      buffer.writeln('[$role] ${m.content}');
    }
    return buffer.toString();
  }

  bool _messageSnapshotStillPrefix(
    List<ChatMessage> expected,
    List<ChatMessage> actual,
  ) {
    if (actual.length < expected.length) return false;
    for (var i = 0; i < expected.length; i++) {
      if (expected[i].id != actual[i].id ||
          expected[i].createdAt != actual[i].createdAt ||
          expected[i].role != actual[i].role ||
          expected[i].content != actual[i].content) {
        return false;
      }
    }
    return true;
  }

  String _buildIncrementalPrompt({
    required String? previousSummary,
    required String newExcerpt,
    required int cap,
  }) {
    final buffer = StringBuffer();
    if (previousSummary != null && previousSummary.isNotEmpty) {
      buffer
        ..writeln(
            'Update the existing summary by merging in the new turns. Keep '
            'the rules from the system prompt — paths, identifiers, errors, '
            'decisions verbatim. Drop redundant detail. Output only the '
            'updated summary, under $cap characters.')
        ..writeln()
        ..writeln('--- EXISTING SUMMARY ---')
        ..writeln(previousSummary)
        ..writeln('--- END EXISTING SUMMARY ---')
        ..writeln()
        ..writeln('--- NEW TURNS ---')
        ..writeln(newExcerpt)
        ..writeln('--- END NEW TURNS ---');
    } else {
      buffer
        ..writeln(
            'Summarize the following conversation excerpt for re-injection '
            'into the next turn. Output under $cap characters. Plain text '
            'only.')
        ..writeln()
        ..writeln('--- EXCERPT ---')
        ..writeln(newExcerpt)
        ..writeln('--- END EXCERPT ---');
    }
    return buffer.toString();
  }
}

class ContextSummaryResult {
  final String summaryText;
  final bool wasTruncated;

  ContextSummaryResult({
    required this.summaryText,
    required this.wasTruncated,
  });
}
