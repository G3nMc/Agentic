/// Terminal / intermediate state of one chat turn.
///
/// A turn is the whole `prompt -> orchestrator -> reply -> persist`
/// transaction. [running] is only ever observed for a turn that is still in
/// flight, or for one whose process died before it could be closed — the
/// start-up reaper rewrites those to [aborted] so the UI can flag them.
enum ConversationTurnStatus {
  running,
  completed,
  failed,
  aborted;

  static ConversationTurnStatus parse(String? value) {
    switch (value) {
      case 'completed':
        return ConversationTurnStatus.completed;
      case 'failed':
        return ConversationTurnStatus.failed;
      case 'aborted':
        return ConversationTurnStatus.aborted;
      default:
        return ConversationTurnStatus.running;
    }
  }
}

/// One persisted chat turn (`conversation_turns` row).
class ConversationTurn {
  const ConversationTurn({
    required this.id,
    required this.conversationId,
    required this.status,
    required this.prompt,
    required this.startedAt,
    this.endedAt,
    this.error,
    this.backend,
    this.modelId,
  });

  final String id;
  final String conversationId;
  final ConversationTurnStatus status;
  final String prompt;
  final int startedAt;
  final int? endedAt;
  final String? error;
  final String? backend;
  final String? modelId;

  /// True when the turn started but never produced a delivered answer.
  bool get isInterrupted =>
      status == ConversationTurnStatus.aborted ||
      status == ConversationTurnStatus.failed;

  factory ConversationTurn.fromMap(Map<String, Object?> map) {
    return ConversationTurn(
      id: (map['id'] as String?) ?? '',
      conversationId: (map['conversation_id'] as String?) ?? '',
      status: ConversationTurnStatus.parse(map['status'] as String?),
      prompt: (map['prompt'] as String?) ?? '',
      startedAt: (map['started_at'] as int?) ?? 0,
      endedAt: map['ended_at'] as int?,
      error: map['error'] as String?,
      backend: map['backend'] as String?,
      modelId: map['model_id'] as String?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'status': status.name,
      'prompt': prompt,
      'started_at': startedAt,
      'ended_at': endedAt,
      'error': error,
      'backend': backend,
      'model_id': modelId,
    };
  }
}