class LocalServerConfig {
  final String modelId;
  final String pythonCode;
  final String host;
  final int port;
  final bool isEnabled;
  final int createdAt;

  LocalServerConfig({
    required this.modelId,
    required this.pythonCode,
    this.host = "localhost",
    this.port = 5000,
    this.isEnabled = true,
    required this.createdAt,
  });

  factory LocalServerConfig.fromMap(Map<String, Object?> map) {
    return LocalServerConfig(
      modelId: map["model_id"] as String,
      pythonCode: map["python_code"] as String,
      host: (map["host"] as String?) ?? "localhost",
      port: (map["port"] as int?) ?? 5000,
      isEnabled: ((map["is_enabled"] as int?) ?? 1) == 1,
      createdAt: (map["created_at"] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      "model_id": modelId,
      "python_code": pythonCode,
      "host": host,
      "port": port,
      "is_enabled": isEnabled ? 1 : 0,
      "created_at": createdAt,
    };
  }

  LocalServerConfig copyWith({
    String? modelId,
    String? pythonCode,
    String? host,
    int? port,
    bool? isEnabled,
    int? createdAt,
  }) {
    return LocalServerConfig(
      modelId: modelId ?? this.modelId,
      pythonCode: pythonCode ?? this.pythonCode,
      host: host ?? this.host,
      port: port ?? this.port,
      isEnabled: isEnabled ?? this.isEnabled,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  String getServerUrl() => "http://$host:$port";
}
