class Conversation {
  final String id;
  final String title;
  final String? modelId;
  final String? backend;
  final int createdAt;
  final int updatedAt;
  final String? groupId;
  final String? projectPath;

  Conversation({
    required this.id,
    required this.title,
    this.modelId,
    this.backend,
    required this.createdAt,
    required this.updatedAt,
    this.groupId,
    this.projectPath,
  });

  factory Conversation.fromMap(Map<String, Object?> map) {
    return Conversation(
      id: map["id"] as String,
      title: map["title"] as String,
      modelId: map["model_id"] as String?,
      backend: map["backend"] as String?,
      createdAt: (map["created_at"] as int?) ?? 0,
      updatedAt: (map["updated_at"] as int?) ?? 0,
      groupId: map["group_id"] as String?,
      projectPath: map["project_path"] as String?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      "id": id,
      "title": title,
      "model_id": modelId,
      "backend": backend,
      "created_at": createdAt,
      "updated_at": updatedAt,
      "group_id": groupId,
      "project_path": projectPath,
    };
  }

  Conversation copyWith({
    String? id,
    String? title,
    String? modelId,
    String? backend,
    int? createdAt,
    int? updatedAt,
    String? groupId,
    String? projectPath,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      modelId: modelId ?? this.modelId,
      backend: backend ?? this.backend,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      groupId: groupId ?? this.groupId,
      projectPath: projectPath ?? this.projectPath,
    );
  }
}
