class AgentCredentials {
  final String? hfToken;
  final String? localKey;
  final DateTime? updatedAt;

  AgentCredentials({
    this.hfToken,
    this.localKey,
    this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'hf_token': hfToken,
      'local_key': localKey,
      'updated_at': updatedAt?.millisecondsSinceEpoch,
    };
  }

  factory AgentCredentials.fromMap(Map<String, dynamic> map) {
    return AgentCredentials(
      hfToken: map['hf_token'] as String?,
      localKey: map['local_key'] as String?,
      updatedAt: map['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int)
          : null,
    );
  }

  AgentCredentials copyWith({
    String? hfToken,
    String? localKey,
    DateTime? updatedAt,
  }) {
    return AgentCredentials(
      hfToken: hfToken ?? this.hfToken,
      localKey: localKey ?? this.localKey,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
