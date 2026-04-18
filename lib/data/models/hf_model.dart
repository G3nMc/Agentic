class HfModel {
  final String id;
  final String name;
  final bool isFavorite;
  final int createdAt;

  HfModel({
    required this.id,
    required this.name,
    this.isFavorite = false,
    required this.createdAt,
  });

  factory HfModel.fromMap(Map<String, Object?> map) {
    return HfModel(
      id: map["id"] as String,
      name: map["name"] as String,
      isFavorite: ((map["is_favorite"] as int?) ?? 0) == 1,
      createdAt: (map["created_at"] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      "id": id,
      "name": name,
      "is_favorite": isFavorite ? 1 : 0,
      "created_at": createdAt,
    };
  }

  HfModel copyWith({
    String? id,
    String? name,
    bool? isFavorite,
    int? createdAt,
  }) {
    return HfModel(
      id: id ?? this.id,
      name: name ?? this.name,
      isFavorite: isFavorite ?? this.isFavorite,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
