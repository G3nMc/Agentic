import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/models/conversation_task.dart';
import '../../data/repositories/task_repository.dart';
import '../../services/orchestrator_manager.dart';

/// Collapsible checklist that displays the structured task list for a
/// TASK COMPLIANCE conversation.
///
/// Subscribes to [OrchestratorManager.taskStream] for live updates and
/// seeds itself from [TaskRepository] on mount so re-opening a chat
/// re-shows whatever progress was made previously.
///
/// When [taskMode] is ``task_compliance`` (i.e. NOT auto), action
/// buttons appear next to the currently-active task so the user can
/// drive the workflow manually. In ``task_compliance_auto`` the panel
/// is read-only -- the orchestrator auto-proceeds.
class TaskChecklistPanel extends StatefulWidget {
  const TaskChecklistPanel({
    super.key,
    required this.conversationId,
    required this.taskMode,
    required this.onAction,
  });

  /// Conversation whose tasks this panel renders.
  final String conversationId;

  /// One of ``open`` / ``task_compliance`` / ``task_compliance_auto``.
  final String taskMode;

  /// Called when the user clicks an action button. The host (ChatView)
  /// is responsible for turning this into a ``<task_action>`` envelope
  /// and sending it to the orchestrator.
  final void Function(int taskId, TaskAction action) onAction;

  @override
  State<TaskChecklistPanel> createState() => _TaskChecklistPanelState();
}

class _TaskChecklistPanelState extends State<TaskChecklistPanel> {
  static const double _collapsedHeight = 60.0;
  static const double _expandedHeight = 280.0;

  List<ConversationTask> _tasks = const [];
  StreamSubscription<OrchestratorTaskEvent>? _sub;
  bool _expanded = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _hydrateFromDb();
    _sub = OrchestratorManager.instance.taskStream.listen(_onEvent);
  }

  @override
  void didUpdateWidget(covariant TaskChecklistPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) {
      _hydrateFromDb();
    }
  }

  Future<void> _hydrateFromDb() async {
    setState(() => _loading = true);
    final rows = await TaskRepository.instance.listByConversation(widget.conversationId);
    if (!mounted) return;
    setState(() {
      _tasks = rows;
      _loading = false;
    });
  }

  void _onEvent(OrchestratorTaskEvent event) {
    if (event.conversationId != widget.conversationId) return;
    if (event is OrchestratorTasksProposed) {
      setState(() => _tasks = event.tasks);
      return;
    }
    if (event is OrchestratorTaskStatusChanged) {
      final updated = <ConversationTask>[];
      for (final t in _tasks) {
        if (t.taskId == event.taskId) {
          updated.add(t.copyWith(status: event.status, note: event.note));
        } else {
          updated.add(t);
        }
      }
      setState(() => _tasks = updated);
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _isManualMode => widget.taskMode == 'task_compliance';

  /// Index of the task that should get the action bar attached. Picks
  /// the first non-terminal task; if none, the first task overall.
  int? get _activeTaskIndex {
    for (var i = 0; i < _tasks.length; i++) {
      if (!_tasks[i].status.isTerminal) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.taskMode == 'open') return const SizedBox.shrink();
    if (_loading) {
      return const SizedBox(
        height: _collapsedHeight,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_tasks.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final done = _tasks.where((t) => t.status == TaskStatus.done).length;
    final total = _tasks.length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      height: _expanded ? _expandedHeight : _collapsedHeight,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        border: Border(top: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(theme, done, total),
          if (_expanded) _buildList(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, int done, int total) {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              _expanded ? Icons.expand_more : Icons.chevron_right,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Icon(Icons.checklist, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Task plan  ($done / $total done)',
                style: theme.textTheme.titleSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (!_isManualMode)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'AUTO',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    final activeIdx = _activeTaskIndex;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _tasks.length,
      itemBuilder: (context, i) {
        final t = _tasks[i];
        final isActive = i == activeIdx;
        return _buildTaskRow(theme, t, isActive: isActive);
      },
    );
  }

  Widget _buildTaskRow(ThemeData theme, ConversationTask t, {required bool isActive}) {
    final (icon, color) = _statusVisuals(t.status, theme);
    // Show action buttons for ANY actionable task in manual mode, not just the active one
    final showActions = _isManualMode && _shouldShowActions(t) && !t.status.isTerminal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '#${t.taskId}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                          decoration: t.status == TaskStatus.skipped ? TextDecoration.lineThrough : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (t.description.isNotEmpty)
                  Text(
                    t.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (t.note.isNotEmpty)
                  Text(
                    t.note,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: color,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (showActions)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: _buildActionBar(theme, t),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _shouldShowActions(ConversationTask t) {
    // Show action buttons for every status except ``skipped`` (the
    // user already chose to drop that task). The specific button set
    // varies by status -- pending shows "Start", in_progress shows
    // "Abort", and the rest show the full Proceed/Retry/Skip/Replan/
    // Abort set. Without this the panel was locked at plan-emit time
    // (all tasks pending = no buttons) and the user had no way to
    // kick the first task off when the model stalled.
    return t.status != TaskStatus.skipped;
  }

  Widget _buildActionBar(ThemeData theme, ConversationTask t) {
    // Status-aware action set:
    //   pending      -> Start (kicks off task #N), Skip, Abort
    //   in_progress  -> Abort  (the model is currently working; only
    //                   sensible manual override is to stop it)
    //   done / partial / blocked / failed
    //                -> full set (Proceed/Retry/Skip/Replan/Abort) so
    //                   the user decides what to do next.
    final children = <Widget>[];
    switch (t.status) {
      case TaskStatus.pending:
        children.addAll([
          _actionButton(theme, 'Start', Icons.play_arrow, TaskAction.proceed, t.taskId, primary: true),
          _actionButton(theme, 'Skip', Icons.skip_next, TaskAction.skip, t.taskId),
          _actionButton(theme, 'Abort', Icons.stop, TaskAction.abort, t.taskId, danger: true),
        ]);
        break;
      case TaskStatus.inProgress:
        children.addAll([
          _actionButton(theme, 'Abort', Icons.stop, TaskAction.abort, t.taskId, danger: true),
        ]);
        break;
      case TaskStatus.done:
      case TaskStatus.partial:
      case TaskStatus.blocked:
      case TaskStatus.failed:
        children.addAll([
          _actionButton(theme, 'Proceed', Icons.arrow_forward, TaskAction.proceed, t.taskId, primary: true),
          _actionButton(theme, 'Retry', Icons.refresh, TaskAction.retry, t.taskId),
          _actionButton(theme, 'Skip', Icons.skip_next, TaskAction.skip, t.taskId),
          _actionButton(theme, 'Replan', Icons.auto_fix_high, TaskAction.replan, t.taskId),
          _actionButton(theme, 'Abort', Icons.stop, TaskAction.abort, t.taskId, danger: true),
        ]);
        break;
      case TaskStatus.skipped:
        // Terminal -- no actions (filtered out by _shouldShowActions).
        break;
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: children,
    );
  }

  Widget _actionButton(
    ThemeData theme,
    String label,
    IconData icon,
    TaskAction action,
    int taskId, {
    bool danger = false,
    bool primary = false,
  }) {
    final fg = danger ? theme.colorScheme.error : theme.colorScheme.primary;
    // Primary button (the recommended next step, e.g. Start / Proceed)
    // is rendered filled so the user can spot the default action at a
    // glance. Secondary buttons stay outlined.
    if (primary) {
      return FilledButton.icon(
        onPressed: () => widget.onAction(taskId, action),
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: fg,
          foregroundColor: theme.colorScheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: () => widget.onAction(taskId, action),
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: fg,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        side: BorderSide(color: fg.withValues(alpha: 0.4)),
      ),
    );
  }

  (IconData, Color) _statusVisuals(TaskStatus s, ThemeData theme) {
    switch (s) {
      case TaskStatus.pending:
        return (Icons.radio_button_unchecked, theme.colorScheme.onSurfaceVariant);
      case TaskStatus.inProgress:
        return (Icons.timelapse, theme.colorScheme.primary);
      case TaskStatus.done:
        return (Icons.check_circle, Colors.green);
      case TaskStatus.partial:
        return (Icons.donut_large, Colors.orange);
      case TaskStatus.blocked:
        return (Icons.pause_circle, Colors.amber);
      case TaskStatus.failed:
        return (Icons.cancel, theme.colorScheme.error);
      case TaskStatus.skipped:
        return (Icons.skip_next, theme.colorScheme.onSurfaceVariant);
    }
  }
}
