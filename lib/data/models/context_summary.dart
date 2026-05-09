class ContextSummary {
  final String conversationId;
  final String summaryText;
  final int createdAt;
  final int updatedAt;

  ContextSummary({
    required this.conversationId,
    required this.summaryText,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ContextSummary.fromMap(Map<String, Object?> map) {
    return ContextSummary(
      conversationId: map['conversation_id'] as String,
      summaryText: map['summary_text'] as String,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'conversation_id': conversationId,
      'summary_text': summaryText,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  ContextSummary copyWith({
    String? conversationId,
    String? summaryText,
    int? createdAt,
    int? updatedAt,
  }) {
    return ContextSummary(
      conversationId: conversationId ?? this.conversationId,
      summaryText: summaryText ?? this.summaryText,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
