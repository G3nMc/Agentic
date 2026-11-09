import 'dart:io';

import 'package:agentic/data/database/app_database.dart';
import 'package:agentic/data/models/conversation.dart';
import 'package:agentic/data/repositories/conversation_repository.dart';
import 'package:agentic/services/chat_turn_controller.dart';
import 'package:agentic/services/orchestrator_manager.dart';
import 'package:agentic/statemanagement/method_listener.dart';
import 'package:agentic/ui/screens/home_screen.dart';
import 'package:agentic/ui/widgets/chat_input.dart';
import 'package:agentic/ui/widgets/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Per-chat scope of the chat surface (multi-session, phases 3-4).
///
/// Two contracts are pinned here, both observable from the widget tree:
///
///  * Re-entering a chat whose answer is still being produced restores the Stop
///    affordance — `_sending` is rehydrated from `ChatTurnController.isBusyFor`,
///    not remembered by whichever `ChatView` instance dispatched the prompt.
///  * Stop acts on *one* conversation: pressing it in chat A aborts A's turn and
///    stops A's session only. B keeps running and keeps its own turn.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  /// Advance the tree while real async work (SQLite, file IO) completes.
  ///
  /// `pumpAndSettle` cannot be used: the sidebar renders an indeterminate
  /// progress indicator while it loads, which schedules frames for ever.
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
    databaseFactory = databaseFactoryFfiNoIsolate;

    // flutter_secure_storage has no platform implementation under test; a
    // MissingPluginException here would make ChatView try to launch Python.
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
    tmp = Directory.systemTemp.createTempSync('agentic_chat_scope_test_');
    AppDatabase.debugProjectDatabasePathOverride =
        p.join(tmp.path, 'project.db');
    AppDatabase.debugGlobalDatabasePathOverride = p.join(tmp.path, 'global.db');
    OrchestratorManager.instance.debugResetSession();
    OrchestratorManager.debugStopCalls.clear();
    OrchestratorManager.debugRestartReasons.clear();
  });

  tearDown(() async {
    await OrchestratorManager.instance.debugResetAll();
    AppDatabase.debugProjectDatabasePathOverride = null;
    AppDatabase.debugGlobalDatabasePathOverride = null;
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

  Future<void> openConversation(WidgetTester tester, String id) async {
    await MethodListener<HomeScreen>().callMethod(
      'openConversation',
      params: {'conversationId': id},
    );
    await pumpFrames(tester);
  }

  /// The [ChatInput] currently rendered by the active (single) [ChatView].
  ChatInput chatInput(WidgetTester tester) =>
      tester.widget<ChatInput>(find.byType(ChatInput));

  testWidgets('re-entering a busy chat restores the Stop affordance',
      (tester) async {
    await tester.runAsync(() => seedConversations(const ['conv-a', 'conv-b']));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await pumpFrames(tester);

    await openConversation(tester, 'conv-a');
    expect(find.byType(ChatView), findsOneWidget);
    expect(chatInput(tester).sending, isFalse);

    // conv-a starts producing an answer, then the user browses to conv-b.
    final turn = ChatTurnController.instance
        .begin(conversationId: 'conv-a', prompt: 'write the report');
    expect(turn, isNotNull);

    await openConversation(tester, 'conv-b');
    expect(chatInput(tester).sending, isFalse,
        reason: "conv-b has no turn of its own in flight");

    // Back to conv-a: the widget was rebuilt, but the turn is still owned by
    // the controller, so the input bar must show Stop again.
    await openConversation(tester, 'conv-a');
    expect(
      chatInput(tester).sending,
      isTrue,
      reason: 'a remount must rehydrate _sending from ChatTurnController',
    );

    ChatTurnController.instance.abort('conv-a', 'test cleanup');
  });

  testWidgets('Stop in chat A leaves chat B running', (tester) async {
    await tester.runAsync(() => seedConversations(const ['conv-a', 'conv-b']));

    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await pumpFrames(tester);

    await openConversation(tester, 'conv-a');

    // Both chats own a live session and an in-flight turn.
    final a = OrchestratorManager.instance.sessionFor('conv-a');
    final b = OrchestratorManager.instance.sessionFor('conv-b');
    a.debugSetSessionState(state: OrchestratorSessionState.busy);
    b.debugSetSessionState(state: OrchestratorSessionState.busy);
    final turnA = ChatTurnController.instance
        .begin(conversationId: 'conv-a', prompt: 'A prompt')!;
    final turnB = ChatTurnController.instance
        .begin(conversationId: 'conv-b', prompt: 'B prompt')!;
    await tester.pump();

    OrchestratorManager.debugStopCalls.clear();

    // Press Stop on the chat that is on screen.
    expect(chatInput(tester).sending, isTrue);
    chatInput(tester).onStop!();
    await pumpFrames(tester);

    // Only conv-a was touched.
    expect(turnA.cancelled, isTrue);
    expect(turnB.cancelled, isFalse);
    expect(ChatTurnController.instance.isBusyFor('conv-a'), isFalse);
    expect(ChatTurnController.instance.isBusyFor('conv-b'), isTrue);

    expect(
      OrchestratorManager.debugStopCalls,
      [OrchestratorStopSource.chatStopButton],
      reason: 'a Stop must reach exactly one session — the one it belongs to',
    );
    expect(b.isDisposed, isFalse);
    expect(b.isBusy, isTrue, reason: "chat B's turn keeps running");

    // The input bar of the chat that stopped is idle again.
    expect(chatInput(tester).sending, isFalse);

    // Switching to conv-b shows *its* Stop affordance, still live.
    await openConversation(tester, 'conv-b');
    expect(chatInput(tester).sending, isTrue);
    expect(ChatTurnController.instance.isBusyFor('conv-b'), isTrue);

    ChatTurnController.instance.abortAll('test cleanup');
  });
}