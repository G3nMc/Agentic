import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/repositories/agent_role_settings_repository.dart';
import '../../services/orchestrator_manager.dart';

/// Multi-agent header replacement for the single-model `ModelSwitcher`.
///
/// Renders four small stacked tiles — Router → Shaper → Reasoner → Executor —
/// each showing the role name (top) and the configured model id (bottom).
/// Subscribes to [OrchestratorManager.traceStream] so the tile of whichever
/// agent fired most recently glows in the accent colour; the rest stay muted.
/// Resets to "no active agent" when a new turn starts (the trace stream
/// always emits a fresh array per turn, so tracking "the last agent in the
/// most recent array" is enough).
class WorkflowBreadcrumb extends StatefulWidget {
  /// When [sending] transitions from true → false the breadcrumb immediately
  /// clears any active highlight and cancels the pending queue, so the tiles
  /// stop flashing once the final response has been delivered.
  final bool sending;

  const WorkflowBreadcrumb({super.key, this.sending = false});

  @override
  State<WorkflowBreadcrumb> createState() => _WorkflowBreadcrumbState();
}

class _WorkflowBreadcrumbState extends State<WorkflowBreadcrumb> {
  WorkflowAgents? _agents;
  String? _activeRole;
  StreamSubscription<List<Map<String, Object?>>>? _traceSub;
  StreamSubscription<String>? _logSub;
  Timer? _highlightResetTimer;
  Timer? _queueTimer;
  DateTime? _lastTransitionAt;
  final List<String> _pendingRoles = [];

  // Minimum time each role's highlight stays visible before we allow a
  // transition to a different role. Without this, fast roles like Router and
  // Shaper finish in <100 ms and the user only ever sees Reasoner light up.
  static const Duration _minDwell = Duration(milliseconds: 700);

  // Parses lines like `[agent:router→model_id] ...` (request out) and
  // `[agent:router←model_id] ...` (response back) emitted by the Python
  // orchestrator. The arrow may be the Unicode glyph (→/←) or, on terminals
  // that mangle UTF-8, an ASCII fallback (->, <-, or just `]`). Drives the
  // live "currently working" highlight.
  static final RegExp _agentLineRe =
      RegExp(r'\[agent:([a-zA-Z_]+)(?:[→←]|->|<-|\])');

  @override
  void didUpdateWidget(WorkflowBreadcrumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the parent signals that sending has finished, immediately clear
    // any active highlight and cancel the pending queue so the tiles stop
    // flashing after the final response has been delivered.
    if (oldWidget.sending && !widget.sending) {
      _clearHighlight();
    }
  }

  /// Immediately resets the active highlight and cancels all pending timers.
  void _clearHighlight() {
    _highlightResetTimer?.cancel();
    _queueTimer?.cancel();
    _pendingRoles.clear();
    _lastTransitionAt = null;
    if (_activeRole != null && mounted) {
      setState(() => _activeRole = null);
    }
  }

  @override
  void initState() {
    super.initState();
    _loadAgents();
    _traceSub =
        OrchestratorManager.instance.traceStream.listen(_onTrace);
    _logSub = OrchestratorManager.instance.logStream.listen(_onLogLine);
    AgentRoleSettingsRepository.instance.groupsChangedNotifier.addListener(_onGroupsChanged);
    AgentRoleSettingsRepository.instance.activeGroupNotifier.addListener(_onGroupsChanged);
  }

  @override
  void dispose() {
    _traceSub?.cancel();
    _logSub?.cancel();
    _highlightResetTimer?.cancel();
    _queueTimer?.cancel();
    AgentRoleSettingsRepository.instance.groupsChangedNotifier.removeListener(_onGroupsChanged);
    AgentRoleSettingsRepository.instance.activeGroupNotifier.removeListener(_onGroupsChanged);
    super.dispose();
  }

  void _onGroupsChanged() {
    _loadAgents();
  }

  Future<void> _loadAgents() async {
    final agents = await WorkflowAgents.load();
    if (!mounted) return;
    setState(() => _agents = agents);
  }

  void _onLogLine(String line) {
    // ANY orchestrator log line means the subprocess is still working — keep
    // the current role's highlight alive even if the role itself isn't
    // re-emitting `[agent:…]` lines (the reasoner can spend 30+ seconds
    // streaming tokens without any [agent:] markers in between).
    if (_activeRole != null || _pendingRoles.isNotEmpty) {
      _bumpIdleResetTimer();
    }

    final match = _agentLineRe.firstMatch(line);
    if (match == null) return;
    final role = match.group(1);
    if (role == null || role.isEmpty) return;
    if (!AgentRoleSettingsRepository.roles.contains(role)) return;
    _enqueueRole(role);
  }

  void _onTrace(List<Map<String, Object?>> trace) {
    if (trace.isEmpty) return;
    // Drain whatever's still queued so the visible roles match the recorded
    // execution order, then schedule the idle clear.
    for (final entry in trace) {
      final role = entry['agent']?.toString();
      if (role == null || role.isEmpty) continue;
      if (!AgentRoleSettingsRepository.roles.contains(role)) continue;
      if (_pendingRoles.isEmpty
          ? _activeRole != role
          : _pendingRoles.last != role) {
        _pendingRoles.add(role);
      }
    }
    _processQueue();
  }

  /// Queue a role for highlighting. The queue is drained one role at a time,
  /// each visible for at least [_minDwell], so the user can actually see fast
  /// agents (Router, Shaper, Executor) flash by — not just the long-running
  /// Reasoner.
  void _enqueueRole(String role) {
    // Skip duplicate consecutive roles (e.g. the matching ←/-> log line for
    // a role we just enqueued from its →/-> line, or the same agent looping).
    final lastSeen =
        _pendingRoles.isNotEmpty ? _pendingRoles.last : _activeRole;
    if (lastSeen == role) {
      _bumpIdleResetTimer();
      return;
    }
    _pendingRoles.add(role);
    _processQueue();
  }

  void _processQueue() {
    if (!mounted) return;
    if (_queueTimer?.isActive ?? false) return; // dwell still running
    if (_pendingRoles.isEmpty) {
      _bumpIdleResetTimer();
      return;
    }

    final now = DateTime.now();
    final waited =
        _lastTransitionAt == null ? _minDwell : now.difference(_lastTransitionAt!);
    if (waited < _minDwell) {
      _queueTimer = Timer(_minDwell - waited, _processQueue);
      return;
    }

    final next = _pendingRoles.removeAt(0);
    _lastTransitionAt = DateTime.now();
    setState(() => _activeRole = next);

    _queueTimer = Timer(_minDwell, _processQueue);
    _bumpIdleResetTimer();
  }

  /// Drops the highlight if no new agent activity arrives within ~5 seconds.
  /// Replaces both the old `_onLogLine` and `_onTrace` reset timers.
  void _bumpIdleResetTimer() {
    _highlightResetTimer?.cancel();
    _highlightResetTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      if (_pendingRoles.isNotEmpty) return;
      setState(() => _activeRole = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final agents = _agents;
    if (agents == null) {
      return const SizedBox(
        height: 40,
        width: 40,
        child: Padding(
          padding: EdgeInsets.all(10),
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }
    final tiles = <Widget>[];
    final roles = AgentRoleSettingsRepository.roles;
    for (var i = 0; i < roles.length; i++) {
      final role = roles[i];
      tiles.add(_tile(role, agents.get(role).model));
      if (i != roles.length - 1) {
        tiles.add(const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Icon(Icons.chevron_right, size: 14, color: AppTheme.textMuted),
        ));
      }
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: tiles),
    );
  }

  Widget _tile(String role, String model) {
    final active = _activeRole == role;
    final borderColor = active ? AppTheme.accent : AppTheme.border;
    final titleColor = active ? AppTheme.accent : AppTheme.textSecondary;
    final modelColor = active ? AppTheme.textPrimary : AppTheme.textMuted;
    final bg = active
        ? AppTheme.accent.withValues(alpha: 0.10)
        : AppTheme.bgPrimary;
    return Tooltip(
      message: '${_titleForRole(role)}\n$model',
      child: Container(
        constraints: const BoxConstraints(minWidth: 92, maxWidth: 140),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: borderColor, width: active ? 1.4 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _titleForRole(role).toUpperCase(),
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: titleColor,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              model.isEmpty ? '(unset)' : model,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: modelColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _titleForRole(String role) {
    switch (role) {
      case 'reasoner':
        return 'Reasoner';
      case 'summarizer':
        return 'Summarizer';
      case 'workflow':
        return 'Workflow';
    }
    return role;
  }
}
