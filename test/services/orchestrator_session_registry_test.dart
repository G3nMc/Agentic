import 'package:agentic/services/orchestrator_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// Multi-session contract for the [OrchestratorManager] facade.
///
/// The facade indexes one [OrchestratorSession] per conversation GUID. These
/// tests pin identity, lazy creation, disposal and activity derivation without
/// ever spawning a Python subprocess.
void main() {
  final manager = OrchestratorManager.instance;

  tearDown(() async {
    await manager.debugResetAll();
  });

  group('session identity', () {
    test('two conversations get two distinct sessions', () {
      final a = manager.sessionFor('conv-a');
      final b = manager.sessionFor('conv-b');

      expect(identical(a, b), isFalse);
      expect(a.conversationId, 'conv-a');
      expect(b.conversationId, 'conv-b');
      // Sessions are also reachable by key, which is what the sidebar and the
      // chat headers use.
      expect(identical(manager.peek('conv-a'), a), isTrue);
      expect(manager.sessions, hasLength(2));
    });

    test('acquiring the same conversation twice returns the same instance', () {
      final first = manager.sessionFor('conv-a');
      final second = manager.sessionFor('conv-a');

      expect(identical(first, second), isTrue);
      expect(manager.sessions, hasLength(1));
    });

    test('peek never creates a session', () {
      expect(manager.peek('conv-a'), isNull);
      expect(manager.sessions, isEmpty);
    });

    test('an empty conversation id falls back to the app session', () {
      final session = manager.sessionFor(null);
      expect(session.conversationId, OrchestratorManager.fallbackSessionKey);
      expect(manager.peek(null), isNull);
    });

    test('a conversation id is the log file name', () {
      final session = manager.sessionFor('0f8a-guid');
      expect(session.conversationId, '0f8a-guid');
      // currentSessionKey is the historical alias of the same value.
      expect(session.currentSessionKey, '0f8a-guid');
    });
  });

  group('disposal', () {
    test('disposing one session leaves the others alive', () async {
      final a = manager.sessionFor('conv-a');
      manager.sessionFor('conv-b');

      await manager.disposeSession('conv-a');

      expect(a.isDisposed, isTrue);
      expect(manager.peek('conv-a'), isNull);
      expect(manager.peek('conv-b'), isNotNull);
      expect(manager.sessions, hasLength(1));
    });

    test('a disposed conversation is rebuilt on the next acquire', () async {
      final first = manager.sessionFor('conv-a');
      await manager.disposeSession('conv-a');

      final second = manager.sessionFor('conv-a');

      expect(identical(first, second), isFalse);
      expect(second.isDisposed, isFalse);
    });

    test('disposeAll closes every session', () async {
      final a = manager.sessionFor('conv-a');
      final b = manager.sessionFor('conv-b');

      await manager.disposeAll();

      expect(a.isDisposed, isTrue);
      expect(b.isDisposed, isTrue);
      expect(manager.sessions, isEmpty);
    });

    test('dispose is idempotent', () async {
      final session = manager.sessionFor('conv-a');
      await session.dispose();
      await session.dispose();
      expect(session.isDisposed, isTrue);
    });
  });

  group('activity', () {
    test('a fresh session is idle', () {
      final session = manager.sessionFor('conv-a');
      expect(session.activity, SessionActivity.idle);
    });

    test('a busy session reports working', () {
      final session = manager.sessionFor('conv-a');
      session.debugSetSessionState(state: OrchestratorSessionState.busy);
      expect(session.activity, SessionActivity.working);
    });

    test('a live but unstarted session reports idle', () {
      final session = manager.sessionFor('conv-a');
      session.debugSetSessionState(state: OrchestratorSessionState.idle);
      // An idle-but-live process has not delivered an answer yet.
      expect(session.activity, SessionActivity.idle);
    });

    test('stopping the session returns it to idle', () {
      final session = manager.sessionFor('conv-a');
      session.debugSetSessionState(state: OrchestratorSessionState.busy);
      session.debugSetSessionState(state: OrchestratorSessionState.stopped);
      expect(session.activity, SessionActivity.idle);
    });

    test('activity transitions are published to the stream', () async {
      final session = manager.sessionFor('conv-a');
      final seen = <SessionActivity>[];
      final sub = session.activityStream.listen(seen.add);
      addTearDown(sub.cancel);

      session.debugSetSessionState(state: OrchestratorSessionState.busy);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [SessionActivity.working]);
    });

    test('sessionAdded fires once per session', () async {
      final added = <String>[];
      final sub =
          manager.sessionAdded.listen((s) => added.add(s.conversationId));
      addTearDown(sub.cancel);

      manager.sessionFor('conv-a');
      manager.sessionFor('conv-a');
      manager.sessionFor('conv-b');
      await Future<void>.delayed(Duration.zero);

      expect(added, ['conv-a', 'conv-b']);
    });
  });

  group('concurrency cap', () {
    test('the live-session count stays near the cap for idle sessions', () {
      for (var i = 0; i < kMaxConcurrentSessions + 2; i++) {
        final session = manager.sessionFor('conv-$i');
        // Never busy, so every extra session beyond the cap is evictable.
        session.debugSetSessionState(state: OrchestratorSessionState.idle);
      }
      expect(
        manager.sessions.length,
        lessThanOrEqualTo(kMaxConcurrentSessions + 1),
      );
    });

    test('a busy session is never evicted to make room', () {
      final busy = manager.sessionFor('conv-busy');
      busy.debugSetSessionState(state: OrchestratorSessionState.busy);

      for (var i = 0; i < kMaxConcurrentSessions + 2; i++) {
        final session = manager.sessionFor('conv-$i');
        session.debugSetSessionState(state: OrchestratorSessionState.idle);
      }

      expect(busy.isDisposed, isFalse);
      expect(manager.peek('conv-busy'), isNotNull);
    });
  });

  group('restart fan-out', () {
    test('requestRestartAll reaches every live session', () {
      manager.sessionFor('conv-a');
      manager.sessionFor('conv-b');
      OrchestratorManager.debugRestartReasons.clear();

      manager.requestRestartAll(
        reason: 'backend changed',
        source: OrchestratorStopSource.backendSwitch,
      );

      // One record per live session.
      expect(
        OrchestratorManager.debugRestartReasons
            .where((r) => r == 'backend changed'),
        hasLength(2),
      );
    });

    test('requestRestartFor touches only the named session', () {
      final a = manager.sessionFor('conv-a');
      final b = manager.sessionFor('conv-b');
      a.debugSetSessionState(state: OrchestratorSessionState.busy);
      b.debugSetSessionState(state: OrchestratorSessionState.busy);

      manager.requestRestartFor(
        'conv-a',
        reason: 'model changed',
        source: OrchestratorStopSource.modelSwitch,
      );

      expect(a.hasPendingRestart, isTrue);
      expect(b.hasPendingRestart, isFalse);
    });
  });

  group('navigation safety', () {
    test('setCurrentSession never disposes or restarts anything', () {
      final a = manager.sessionFor('conv-a');
      a.debugSetSessionState(state: OrchestratorSessionState.busy);

      manager.setCurrentSession('conv-b');

      expect(a.isDisposed, isFalse);
      expect(a.hasPendingRestart, isFalse);
      expect(a.isBusy, isTrue);
      expect(manager.currentSessionKey, 'conv-b');
    });
  });
}