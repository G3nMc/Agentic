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
  const WorkflowBreadcrumb({super.key});

  @override
  State<WorkflowBreadcrumb> createState() => _WorkflowBreadcrumbState();
}

class _WorkflowBreadcrumbState extends State<WorkflowBreadcrumb> {
  WorkflowAgents? _agents;
  String? _activeRole;
  StreamSubscription<List<Map<String, Object?>>>? _traceSub;
  Timer? _highlightResetTimer;

  @override
  void initState() {
    super.initState();
    _loadAgents();
    _traceSub =
        OrchestratorManager.instance.traceStream.listen(_onTrace);
  }

  @override
  void dispose() {
    _traceSub?.cancel();
    _highlightResetTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAgents() async {
    final agents = await WorkflowAgents.load();
    if (!mounted) return;
    setState(() => _agents = agents);
  }

  void _onTrace(List<Map<String, Object?>> trace) {
    if (trace.isEmpty) return;
    // The list is already in execution order — the *last* known role is the
    // most recent one to emit. We drive the highlight from that.
    final last = trace.last['agent']?.toString();
    if (last == null || last.isEmpty) return;
    setState(() => _activeRole = last);
    // The trace fires once per turn (Python emits the whole array on
    // __RESPONSE_END__). Reset the highlight after a short cooldown so the
    // user sees the flash but the breadcrumb settles back to neutral.
    _highlightResetTimer?.cancel();
    _highlightResetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
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
      case 'router':
        return 'Router';
      case 'shaper':
        return 'Shaper';
      case 'reasoner':
        return 'Reasoner';
      case 'executor':
        return 'Executor';
      case 'workflow':
        return 'Workflow';
    }
    return role;
  }
}
