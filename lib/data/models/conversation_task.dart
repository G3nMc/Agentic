import 'dart:convert';

/// One unit of work in a TASK COMPLIANCE conversation.
///
/// Mirrors the dataclass in ``bin/agent/loop/task_protocol.py`` so the
/// XML envelopes the orchestrator emits on stdout can be deserialised
/// without extra mapping logic.
class ConversationTask {
  /// Sequence ID assigned by the model inside ``<tasks>`` (1, 2, 3, ...).
  final int taskId;
  final String conversationId;
  final String name;
  final String description;
  final String successCriteria;
  final List<int> dependsOn;
  final TaskStatus status;
  final String note;
  final int? startedAt;
  final int? completedAt;
  final int iterationsUsed;
  final int createdAt;
  final int updatedAt;

  const ConversationTask({
    required this.taskId,
    required this.conversationId,
    required this.name,
    this.description = '',
    this.successCriteria = '',
    this.dependsOn = const <int>[],
    this.status = TaskStatus.pending,
    this.note = '',
    this.startedAt,
    this.completedAt,
    this.iterationsUsed = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ConversationTask.fromMap(Map<String, Object?> map) {
    final dependsRaw = map['depends_on'] as String?;
    List<int> deps = const <int>[];
    if (dependsRaw != null && dependsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(dependsRaw);
        if (decoded is List) {
          deps = decoded.whereType<int>().toList(growable: false);
        }
      } catch (_) {
        // Tolerate corrupt rows: just drop the dependency info.
      }
    }
    return ConversationTask(
      taskId: (map['task_id'] as int?) ?? 0,
      conversationId: map['conversation_id'] as String,
      name: (map['name'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      successCriteria: (map['success_criteria'] as String?) ?? '',
      dependsOn: deps,
      status: TaskStatusX.parse(map['status'] as String?),
      note: (map['note'] as String?) ?? '',
      startedAt: map['started_at'] as int?,
      completedAt: map['completed_at'] as int?,
      iterationsUsed: (map['iterations_used'] as int?) ?? 0,
      createdAt: (map['created_at'] as int?) ?? 0,
      updatedAt: (map['updated_at'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'task_id': taskId,
      'conversation_id': conversationId,
      'name': name,
      'description': description,
      'success_criteria': successCriteria,
      'depends_on': jsonEncode(dependsOn),
      'status': status.value,
      'note': note,
      'started_at': startedAt,
      'completed_at': completedAt,
      'iterations_used': iterationsUsed,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  ConversationTask copyWith({
    TaskStatus? status,
    String? note,
    int? startedAt,
    int? completedAt,
    int? iterationsUsed,
    int? updatedAt,
  }) {
    return ConversationTask(
      taskId: taskId,
      conversationId: conversationId,
      name: name,
      description: description,
      successCriteria: successCriteria,
      dependsOn: dependsOn,
      status: status ?? this.status,
      note: note ?? this.note,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
      iterationsUsed: iterationsUsed ?? this.iterationsUsed,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Mirror of ``common.loop.task_protocol.TaskStatus``.
enum TaskStatus {
  pending,
  inProgress,
  done,
  partial,
  blocked,
  failed,
  skipped,
}

extension TaskStatusX on TaskStatus {
  String get value {
    switch (this) {
      case TaskStatus.pending:
        return 'pending';
      case TaskStatus.inProgress:
        return 'in_progress';
      case TaskStatus.done:
        return 'done';
      case TaskStatus.partial:
        return 'partial';
      case TaskStatus.blocked:
        return 'blocked';
      case TaskStatus.failed:
        return 'failed';
      case TaskStatus.skipped:
        return 'skipped';
    }
  }

  bool get isTerminal {
    return this == TaskStatus.done ||
        this == TaskStatus.failed ||
        this == TaskStatus.skipped;
  }

  static TaskStatus parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'pending':
        return TaskStatus.pending;
      case 'in_progress':
        return TaskStatus.inProgress;
      case 'done':
        return TaskStatus.done;
      case 'partial':
        return TaskStatus.partial;
      case 'blocked':
        return TaskStatus.blocked;
      case 'failed':
        return TaskStatus.failed;
      case 'skipped':
        return TaskStatus.skipped;
      default:
        return TaskStatus.pending;
    }
  }
}

/// Mirror of ``agent.loop.task_protocol.TaskAction``. Only used when
/// the dropdown is in TASK COMPLIANCE (non-auto) mode and the user
/// clicks one of the action buttons in the checklist panel.
enum TaskAction { proceed, retry, skip, abort, replan }

extension TaskActionX on TaskAction {
  String get value {
    switch (this) {
      case TaskAction.proceed:
        return 'proceed';
      case TaskAction.retry:
        return 'retry';
      case TaskAction.skip:
        return 'skip';
      case TaskAction.abort:
        return 'abort';
      case TaskAction.replan:
        return 'replan';
    }
  }

  /// Render the wire format the orchestrator expects as the next user
  /// prompt: ``<task_action><id>N</id><action>proceed</action></task_action>``.
  String toEnvelope(int taskId) {
    return '<task_action><id>$taskId</id><action>$value</action></task_action>';
  }
}
