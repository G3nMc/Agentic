import 'dart:io';

import 'package:agentic/data/database/app_database.dart';
import 'package:agentic/data/models/conversation.dart';
import 'package:agentic/data/repositories/conversation_repository.dart';
import 'package:agentic/services/orchestrator_manager.dart';
import 'package:agentic/statemanagement/method_listener.dart';
import 'package:agentic/ui/screens/home_screen.dart';
import 'package:agentic/ui/widgets/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// P3 exit criteria: the app shell keeps the chat mounted while the user
/// browses Settings, and navigation never requests an orchestrator teardown.
///
/// Settings is a *tab* inside the shell's `IndexedStack`, not a pushed route,
/// so the `ChatView` element survives the round trip. That is the structural
/// guarantee behind "a running turn is never killed by navigation".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  /// Advance the tree while letting real async work (SQLite, file IO) finish.
  ///
  /// `pumpAndSettle` cannot be used here: the sidebar renders an indeterminate
  /// `CircularProgressIndicator` while it loads, which schedules frames for
  /// ever and makes the settle loop time out. Alternating `runAsync` with an
  /// explicit pump drains the pending futures and then draws the result.
  Future<void> pumpFrames(WidgetTester tester, {int frames = 8}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  setUpAll(() {
    sqfliteFfiInit();
    // No-isolate factory: the schema work completes on this isolate's event
    // loop, so the widget harness can drive it without spawning a background
    // worker that a fake-async test could never await.
    databaseFactory = databaseFactoryFfiNoIsolate;

    // flutter_secure_storage talks over a MethodChannel that does not exist in
    // a widget test. Stub it so `SettingsRepository.getHfToken()` resolves to
    // "no token" instead of throwing MissingPluginException — which is also
    // what keeps ChatView from ever trying to launch the subprocess.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        switch (call.method) {
          case 'read':
            return null;
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return false;
          default:
            return null;
        }
      },
    );
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('agentic_nav_test_');
    AppDatabase.debugProjectDatabasePathOverride =
        p.join(tmp.path, 'project.db');
    AppDatabase.debugGlobalDatabasePathOverride = p.join(tmp.path, 'global.db');
    OrchestratorManager.instance.debugResetSession();
    OrchestratorManager.debugStopCalls.clear();
    OrchestratorManager.debugRestartReasons.clear();
  });

  tearDown(() {
    AppDatabase.debugProjectDatabasePathOverride = null;
    AppDatabase.debugGlobalDatabasePathOverride = null;
    OrchestratorManager.instance.debugResetSession();
    OrchestratorManager.debugStopCalls.clear();
    OrchestratorManager.debugRestartReasons.clear();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup; a locked file must not fail the suite.
    }
  });

  Future<void> seedConversations(List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      await ConversationRepository.instance.insert(
        Conversation(
          id: id,
          title: id,
          modelId: '',
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  testWidgets(
    'opening Settings and returning keeps the ChatView state and never stops '
    'the orchestrator',
    (tester) async {
      const conversationId = 'nav-test-conversation';

      await tester.runAsync(() => seedConversations(const [conversationId]));

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await pumpFrames(tester);

      await MethodListener<HomeScreen>().callMethod(
        'openConversation',
        params: {'conversationId': conversationId},
      );
      await pumpFrames(tester);

      expect(find.byType(ChatView), findsOneWidget);
      final chatStateBefore = tester.state<State<ChatView>>(
        find.byType(ChatView),
      );

      // Everything up to here is setup; the assertions below are about what
      // the navigation itself does.
      OrchestratorManager.debugStopCalls.clear();
      OrchestratorManager.debugRestartReasons.clear();

      await MethodListener<HomeScreen>().callMethod(
        'openSettings',
        params: {'section': 0},
      );
      await pumpFrames(tester);

      await MethodListener<HomeScreen>().callMethod('closeSettings');
      await pumpFrames(tester);

      final chatStateAfter = tester.state<State<ChatView>>(
        find.byType(ChatView),
      );

      expect(
        identical(chatStateBefore, chatStateAfter),
        isTrue,
        reason: 'Settings is a tab: the chat must stay mounted while it is open',
      );
      expect(find.byType(ChatView), findsOneWidget);
      expect(
        OrchestratorManager.debugStopCalls,
        isEmpty,
        reason: 'in-app navigation must never request an orchestrator teardown',
      );
    },
  );

  testWidgets('opening a different conversation does not tear the session down',
      (tester) async {
    await tester.runAsync(() => seedConversations(const ['conv-a', 'conv-b']));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await pumpFrames(tester);

    await MethodListener<HomeScreen>().callMethod(
      'openConversation',
      params: {'conversationId': 'conv-a'},
    );
    await pumpFrames(tester);

    final chatStateBefore =
        tester.state<State<ChatView>>(find.byType(ChatView));

    // A turn is in flight in conv-a's own session. Switching to conv-b is pure
    // navigation: it must neither stop nor relaunch anything, because conv-a's
    // answer still has to land in conv-a.
    final busySession = OrchestratorManager.instance.sessionFor('conv-a');
    busySession.debugSetSessionState(
      state: OrchestratorSessionState.busy,
    );
    OrchestratorManager.debugStopCalls.clear();
    OrchestratorManager.debugRestartReasons.clear();

    await MethodListener<HomeScreen>().callMethod(
      'openConversation',
      params: {'conversationId': 'conv-b'},
    );
    await pumpFrames(tester);

    final chatStateAfter =
        tester.state<State<ChatView>>(find.byType(ChatView));

    expect(identical(chatStateBefore, chatStateAfter), isTrue);
    expect(
      OrchestratorManager.debugRestartReasons,
      isEmpty,
      reason: 'a conversation switch must not park a relaunch: every chat '
          'owns its own session now',
    );
    expect(
      OrchestratorManager.debugStopCalls,
      isEmpty,
      reason: 'a mid-turn switch must not request a teardown',
    );
    expect(
      busySession.isBusy,
      isTrue,
      reason: "conv-a's session must still be busy after switching away",
    );
    busySession.debugResetSession();
  });
}