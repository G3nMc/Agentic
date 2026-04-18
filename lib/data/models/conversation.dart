class Conversation {
  final String id;
  final String title;
  final String? modelId;
  final int createdAt;
  final int updatedAt;

  Conversation({
    required this.id,
    required this.title,
    this.modelId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Conversation.fromMap(Map<String, Object?> map) {
    return Conversation(
      id: map["id"] as String,
      title: map["title"] as String,
      modelId: map["model_id"] as String?,
      createdAt: (map["created_at"] as int?) ?? 0,
      updatedAt: (map["updated_at"] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      "id": id,
      "title": title,
      "model_id": modelId,
      "created_at": createdAt,
      "updated_at": updatedAt,
    };
  }

  Conversation copyWith({
    String? id,
    String? title,
    String? modelId,
    int? createdAt,
    int? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      modelId: modelId ?? this.modelId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
