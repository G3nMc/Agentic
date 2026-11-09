import 'package:agentic/core/theme/app_theme.dart';
import 'package:agentic/services/orchestrator_manager.dart';
import 'package:agentic/ui/widgets/session_activity_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sidebar session indicators (multi-session, phase 5).
///
/// Each conversation tile paints two independent signals:
///
///   leading spinner  -> shown only while that chat's session is `working`
///   trailing dot     -> amber while `working`, green once `answered`, absent
///                       when `idle`
///
/// Both are driven by [SessionActivityBuilder], which subscribes to the live
/// session of one conversation. A third state matters for MaM: while the User
/// model reviews the Assistant's reply the chat must stay amber, so the dot
/// must not flicker to green between the two model calls.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final manager = OrchestratorManager.instance;

  setUp(() async {
    await manager.debugResetAll();
  });

  tearDown(() async {
    await manager.debugResetAll();
  });

  /// Mount a single chat's indicator pair and return the widgets under test.
  Future<void> pumpIndicator(
    WidgetTester tester, {
    required String conversationId,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionActivityBuilder(
            conversationId: conversationId,
            builder: (context, activity) => Row(
              children: [
                SessionWorkingSpinner(
                  working: activity == SessionActivity.working,
                ),
                SessionStatusDot(activity: activity),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    // A transition first reaches the session's stream; the builder then
    // setStates, and the 180 ms fade runs. Two pumps cover both hops.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// The colour currently painted by the status dot, or null when hidden.
  Color? dotColor(WidgetTester tester) {
    final containers = tester.widgetList<AnimatedContainer>(
      find.descendant(
        of: find.byType(SessionStatusDot),
        matching: find.byType(AnimatedContainer),
      ),
    );
    if (containers.isEmpty) return null;
    final decoration = containers.first.decoration as BoxDecoration?;
    return decoration?.color;
  }

  /// True when the leading spinner is actually rendering its indicator.
  bool spinnerVisible(WidgetTester tester) =>
      find
          .descendant(
            of: find.byType(SessionWorkingSpinner),
            matching: find.byType(CircularProgressIndicator),
          )
          .evaluate()
          .isNotEmpty;

  testWidgets('idle chat shows neither spinner nor dot', (tester) async {
    manager.sessionFor('conv-idle');
    await pumpIndicator(tester, conversationId: 'conv-idle');
    await settle(tester);

    expect(spinnerVisible(tester), isFalse);
    expect(dotColor(tester), isNull);
  });

  testWidgets('a working chat shows the spinner and an amber dot',
      (tester) async {
    final session = manager.sessionFor('conv-working');
    session.debugSetSessionState(state: OrchestratorSessionState.busy);

    await pumpIndicator(tester, conversationId: 'conv-working');
    await settle(tester);

    expect(spinnerVisible(tester), isTrue);
    expect(dotColor(tester), AppTheme.sessionWorking);
  });

  testWidgets('an answered chat shows a green dot and no spinner',
      (tester) async {
    final session = manager.sessionFor('conv-answered');
    // Answered is the state observed after a busy turn delivered its reply.
    session.debugSetSessionState(state: OrchestratorSessionState.idle);
    session.debugMarkAnswered();

    await pumpIndicator(tester, conversationId: 'conv-answered');
    await settle(tester);

    expect(spinnerVisible(tester), isFalse);
    expect(dotColor(tester), AppTheme.sessionAnswered);
  });

  testWidgets('the dot follows a live transition without remounting',
      (tester) async {
    final session = manager.sessionFor('conv-live');
    await pumpIndicator(tester, conversationId: 'conv-live');
    expect(dotColor(tester), isNull);

    session.debugSetSessionState(state: OrchestratorSessionState.busy);
    await settle(tester);
    expect(dotColor(tester), AppTheme.sessionWorking);
    expect(spinnerVisible(tester), isTrue);

    session.debugSetSessionState(state: OrchestratorSessionState.idle);
    session.debugMarkAnswered();
    await settle(tester);
    expect(dotColor(tester), AppTheme.sessionAnswered);
    expect(spinnerVisible(tester), isFalse);
  });

  testWidgets('MaM keeps the chat amber while the User model reviews',
      (tester) async {
    final session = manager.sessionFor('conv-mam');
    // The Assistant delivered its round: the process is idle between calls.
    session.debugSetSessionState(state: OrchestratorSessionState.idle);
    // ...but the User model is now writing the follow-up prompt.
    session.debugSetAutoInputEvaluating(true);

    await pumpIndicator(tester, conversationId: 'conv-mam');
    await settle(tester);

    expect(dotColor(tester), AppTheme.sessionWorking);
    expect(spinnerVisible(tester), isTrue);

    // The exchange ends: the final answer lands and the flag clears.
    session.debugSetAutoInputEvaluating(false);
    session.debugMarkAnswered();
    await settle(tester);

    expect(dotColor(tester), AppTheme.sessionAnswered);
  });

  testWidgets('each chat renders its own activity', (tester) async {
    final busy = manager.sessionFor('conv-a');
    manager.sessionFor('conv-b');
    busy.debugSetSessionState(state: OrchestratorSessionState.busy);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final id in const ['conv-a', 'conv-b'])
                SessionActivityBuilder(
                  conversationId: id,
                  builder: (context, activity) => SessionStatusDot(
                    key: ValueKey(id),
                    activity: activity,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await settle(tester);

    Color? colorOf(String id) {
      final finder = find.descendant(
        of: find.byKey(ValueKey(id)),
        matching: find.byType(AnimatedContainer),
      );
      // An idle chat renders an empty SizedBox instead of a dot.
      if (finder.evaluate().isEmpty) return null;
      final container = tester.widget<AnimatedContainer>(finder);
      return (container.decoration as BoxDecoration?)?.color;
    }

    expect(colorOf('conv-a'), AppTheme.sessionWorking);
    expect(colorOf('conv-b'), isNull);
  });

  testWidgets('a tile mounted before the session exists promotes itself',
      (tester) async {
    // The conversation list renders every chat, but a session is created
    // lazily on the first send. A tile that mounted first must pick up the
    // live activity once the session appears through `sessionAdded`.
    await pumpIndicator(tester, conversationId: 'conv-later');
    await settle(tester);
    expect(dotColor(tester), isNull);

    final session = manager.sessionFor('conv-later');
    session.debugSetSessionState(state: OrchestratorSessionState.busy);
    await settle(tester);

    expect(dotColor(tester), AppTheme.sessionWorking);
  });

  testWidgets('the spinner is a small square inside a stretched Row',
      (tester) async {
    // A Row with `crossAxisAlignment: stretch` hands its children a tight
    // height. Without a square box the indicator would be stretched into an
    // oval, which is exactly what the sidebar used to render.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 80,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SessionWorkingSpinner(working: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final spinner = tester.getSize(find.byType(CircularProgressIndicator));
    expect(spinner.width, spinner.height, reason: 'spinner must stay circular');
    expect(spinner.width, SessionWorkingSpinner.spinnerSize);
    expect(spinner.width, lessThanOrEqualTo(16));
  });

  testWidgets('the status dot is square, never a squashed oval',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 60,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SessionStatusDot(activity: SessionActivity.working),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    final dot = tester.getSize(
      find.descendant(
        of: find.byType(SessionStatusDot),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(dot.width, dot.height, reason: 'dot must stay circular');
    expect(dot.width, lessThanOrEqualTo(10));
  });
}