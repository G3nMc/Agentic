enum MessageRole {
  user,
  assistant,
  system;

  String get apiValue {
    switch (this) {
      case MessageRole.user:
        return "user";
      case MessageRole.assistant:
        return "assistant";
      case MessageRole.system:
        return "system";
    }
  }

  static MessageRole fromString(String value) {
    switch (value) {
      case "user":
        return MessageRole.user;
      case "assistant":
        return MessageRole.assistant;
      case "system":
        return MessageRole.system;
      default:
        return MessageRole.user;
    }
  }
}

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final int createdAt;
  /// Which workflow agent produced this message. Null for plain
  /// single-agent-mode replies. One of: `router`, `shaper`, `reasoner`,
  /// `executor`, `workflow`. Persisted in the same row so re-opening a
  /// chat keeps the badges visible.
  final String? agent;
  /// Time in milliseconds it took for the assistant to generate this
  /// response. Null for user messages or legacy data.
  final int? responseTimeMs;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.agent,
    this.responseTimeMs,
  });

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    return ChatMessage(
      id: map["id"] as String,
      conversationId: map["conversation_id"] as String,
      role: MessageRole.fromString((map["role"] as String?) ?? "user"),
      content: (map["content"] as String?) ?? "",
      createdAt: (map["created_at"] as int?) ?? 0,
      agent: map["agent"] as String?,
      responseTimeMs: map["response_time_ms"] as int?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      "id": id,
      "conversation_id": conversationId,
      "role": role.apiValue,
      "content": content,
      "created_at": createdAt,
      if (agent != null) "agent": agent,
      if (responseTimeMs != null) "response_time_ms": responseTimeMs,
    };
  }

  // Format used when sending the conversation history to the HF router.
  Map<String, Object?> toApiMap() {
    return {
      "role": role.apiValue,
      "content": content,
    };
  }

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    MessageRole? role,
    String? content,
    int? createdAt,
    String? agent,
    int? responseTimeMs,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      agent: agent ?? this.agent,
      responseTimeMs: responseTimeMs ?? this.responseTimeMs,
    );
  }
}
