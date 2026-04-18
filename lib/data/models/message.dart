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

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    return ChatMessage(
      id: map["id"] as String,
      conversationId: map["conversation_id"] as String,
      role: MessageRole.fromString((map["role"] as String?) ?? "user"),
      content: (map["content"] as String?) ?? "",
      createdAt: (map["created_at"] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      "id": id,
      "conversation_id": conversationId,
      "role": role.apiValue,
      "content": content,
      "created_at": createdAt,
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
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
