import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/orchestrator_manager.dart';

/// Leading slot of a sidebar conversation tile.
///
/// While the chat's orchestrator session is working it shows a small circular
/// spinner inside a fixed-width slot, so the title never shifts when the
/// spinner appears or disappears.
class SessionWorkingSpinner extends StatelessWidget {
  const SessionWorkingSpinner({super.key, required this.working});

  final bool working;

  /// Width of the leading slot (spinner + breathing gap). Fixed so the title
  /// stays left-aligned whether or not the spinner is rendered.
  static const double slotWidth = 20;

  /// Diameter of the spinner itself.
  ///
  /// It is always laid out inside a square box, so an ancestor [Row] with
  /// stretched cross-axis alignment (or a tight height constraint) can never
  /// squash it into an oval.
  static const double spinnerSize = 14;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: working ? slotWidth : 0,
      height: spinnerSize,
      child: AnimatedOpacity(
        opacity: working ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: working
            ? const Center(
                // Center relaxes the incoming constraints, then the square box
                // pins both axes to the same value.
                child: SizedBox.square(
                  dimension: spinnerSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AppTheme.sessionWorking,
                    ),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// Trailing status dot of a sidebar conversation tile.
///
/// - [SessionActivity.working]  -> amber dot, tooltip "Working…"
/// - [SessionActivity.answered] -> green dot, tooltip "Answered"
/// - [SessionActivity.idle]     -> no dot at all
///
/// The colour change and the appearance/disappearance are animated so the
/// transition reads as fluid instead of snapping.
class SessionStatusDot extends StatelessWidget {
  const SessionStatusDot({super.key, required this.activity});

  final SessionActivity activity;

  static const double _dotSize = 8;

  Color? get _color => switch (activity) {
        SessionActivity.working => AppTheme.sessionWorking,
        SessionActivity.answered => AppTheme.sessionAnswered,
        SessionActivity.idle => null,
      };

  String get _tooltip => switch (activity) {
        SessionActivity.working => 'Working…',
        SessionActivity.answered => 'Answered',
        SessionActivity.idle => '',
      };

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) =>
          FadeTransition(opacity: animation, child: child),
      child: color == null
          ? const SizedBox(key: ValueKey('none'), width: _dotSize + 4)
          : Tooltip(
              key: ValueKey(activity),
              message: _tooltip,
              waitDuration: const Duration(milliseconds: 400),
              // `Center` keeps tight/loose ancestor constraints from pulling the
              // dot out of square; the container then owns an exact 8x8 box.
              child: Center(
                widthFactor: 1,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    width: _dotSize,
                    height: _dotSize,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withAlpha(70),
                          blurRadius: 5,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// Subscribes to one conversation's session activity.
///
/// Sessions are created lazily on the first send (or an explicit Start), so a
/// tile can mount before its chat ever ran: the initial value comes from
/// [OrchestratorManager.peek] and the widget promotes itself to a live
/// subscription as soon as the session appears through
/// [OrchestratorManager.sessionAdded]. Only mounted tiles subscribe, so a long
/// conversation list never creates hundreds of idle listeners.
class SessionActivityBuilder extends StatefulWidget {
  const SessionActivityBuilder({
    super.key,
    required this.conversationId,
    required this.builder,
  });

  final String? conversationId;
  final Widget Function(BuildContext context, SessionActivity activity) builder;

  @override
  State<SessionActivityBuilder> createState() => _SessionActivityBuilderState();
}

class _SessionActivityBuilderState extends State<SessionActivityBuilder> {
  StreamSubscription<SessionActivity>? _activitySub;
  StreamSubscription<OrchestratorSession>? _addedSub;
  SessionActivity _activity = SessionActivity.idle;

  @override
  void initState() {
    super.initState();
    _bind();
    _addedSub = OrchestratorManager.instance.sessionAdded.listen((session) {
      if (session.conversationId == widget.conversationId) _bind();
    });
  }

  @override
  void didUpdateWidget(SessionActivityBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId) _bind();
  }

  /// (Re)subscribe to the activity stream of the current conversation.
  void _bind() {
    _activitySub?.cancel();
    _activitySub = null;
    final session = OrchestratorManager.instance.peek(widget.conversationId);
    final initial = session?.activity ?? SessionActivity.idle;
    if (mounted && initial != _activity) {
      setState(() => _activity = initial);
    } else {
      _activity = initial;
    }
    _activitySub = session?.activityStream.listen((next) {
      if (!mounted) return;
      setState(() => _activity = next);
    });
  }

  @override
  void dispose() {
    _activitySub?.cancel();
    _addedSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _activity);
  }
}