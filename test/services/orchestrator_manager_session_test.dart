import 'package:agentic/services/orchestrator_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stop-authority and deferred-restart contract for [OrchestratorManager].
///
/// These are pure state-machine rules: they depend on the session state, the
/// launch fingerprint and the presence of an in-flight turn. No subprocess is
/// spawned — the manager is driven through the `@visibleForTesting` seams so the
/// suite stays fast and hermetic.
void main() {
  final manager = OrchestratorManager.instance;

  setUp(() {
    manager.debugResetSession();
  });

  tearDown(() {
    manager.debugResetSession();
  });

  group('stop authority', () {
    test(
      'an unauthorised stop while busy does not tear the session down and '
      'parks a restart instead',
      () async {
        manager.debugSetSessionState(
          state: OrchestratorSessionState.busy,
          argsFingerprint: 'groq|llama|0.2|1024|false|/proj',
        );
        final pending = manager.debugArmTurn();

        await manager.stop(
          source: OrchestratorStopSource.modelSwitch,
          reason: 'model dropdown changed',
        );

        // The turn is untouched: the awaiting future is still registered.
        expect(manager.debugHasActiveTurn, isTrue);
        expect(pending.isCompleted, isFalse);
        // The session is still alive, and the change is queued for later.
        expect(manager.isRunning, isTrue);
        expect(manager.isBusy, isTrue);
        expect(manager.hasPendingRestart, isTrue);
      },
    );

    test(
      'an authorised stop resolves the awaiting future with '
      'OrchestratorAborted and emits stopped',
      () async {
        manager.debugSetSessionState(state: OrchestratorSessionState.busy);
        final pending = manager.debugArmTurn();

        // The handler must be attached BEFORE the teardown: the awaiting
        // future is completed with an error, and a future with no listener at
        // that instant is reported as an unhandled async error. In production
        // `_sendPromptInternal` always awaits it, so this ordering mirrors the
        // real call site rather than weakening the assertion.
        final aborted = expectLater(
          pending.future,
          throwsA(isA<OrchestratorAborted>()),
        );

        final states = <OrchestratorSessionState>[];
        final sub = manager.sessionStateStream.listen(states.add);
        addTearDown(sub.cancel);

        await manager.stop(
          source: OrchestratorStopSource.chatStopButton,
          reason: 'user pressed STOP',
        );
        await aborted;
        // Let the broadcast stream deliver the transition.
        await Future<void>.delayed(Duration.zero);

        expect(pending.isCompleted, isTrue);
        expect(manager.debugHasActiveTurn, isFalse);
        expect(manager.isRunning, isFalse);
        expect(manager.isBusy, isFalse);
        expect(manager.hasPendingRestart, isFalse);
        expect(states.last, OrchestratorSessionState.stopped);
      },
    );

    test('the abort carries the source and reason', () async {
      manager.debugSetSessionState(state: OrchestratorSessionState.busy);
      final pending = manager.debugArmTurn();

      OrchestratorAborted? captured;
      // Attach the handler before the teardown — see the note above.
      final handled = pending.future.then<void>(
        (_) => fail('expected the awaiting future to be aborted'),
        onError: (Object error) {
          captured = error as OrchestratorAborted;
        },
      );

      await manager.stop(
        source: OrchestratorStopSource.chatStopButton,
        reason: 'user stopped generation',
      );
      await handled;

      expect(captured, isNotNull);
      expect(captured!.source, OrchestratorStopSource.chatStopButton.name);
      expect(captured!.reason, 'user stopped generation');
    });

    test('only STOP, shutdown and crash recovery may terminate a turn', () {
      expect(OrchestratorStopSource.chatStopButton.mayTerminateSession, isTrue);
      expect(
        OrchestratorStopSource.orchestratorSettingsButton.mayTerminateSession,
        isTrue,
      );
      expect(
        OrchestratorStopSource.appShutdown.mayTerminateSession,
        isTrue,
      );
      expect(
        OrchestratorStopSource.internalFailure.mayTerminateSession,
        isTrue,
      );

      expect(OrchestratorStopSource.modelSwitch.mayTerminateSession, isFalse);
      expect(OrchestratorStopSource.backendSwitch.mayTerminateSession, isFalse);
      expect(OrchestratorStopSource.projectSwitch.mayTerminateSession, isFalse);
      expect(
        OrchestratorStopSource.conversationSwitch.mayTerminateSession,
        isFalse,
      );
      expect(OrchestratorStopSource.unspecified.mayTerminateSession, isFalse);
    });

    test('a stop while idle tears down immediately', () async {
      manager.debugSetSessionState(state: OrchestratorSessionState.idle);

      await manager.stop(
        source: OrchestratorStopSource.backendSwitch,
        reason: 'backend changed',
      );

      expect(manager.isRunning, isFalse);
      expect(manager.hasPendingRestart, isFalse);
    });
  });

  group('requestRestart', () {
    test('an identical fingerprint is a no-op and parks nothing', () async {
      const fingerprint = 'groq|llama-3.3|0.2|1024|false|/proj';
      manager.debugSetSessionState(
        state: OrchestratorSessionState.busy,
        argsFingerprint: fingerprint,
      );

      manager.requestRestart(
        reason: 'same configuration reselected',
        source: OrchestratorStopSource.modelSwitch,
        argsFingerprint: fingerprint,
      );

      expect(manager.hasPendingRestart, isFalse);
      expect(manager.isRunning, isTrue);
      expect(manager.isBusy, isTrue);
    });

    test('a different fingerprint while busy parks the relaunch', () {
      manager.debugSetSessionState(
        state: OrchestratorSessionState.busy,
        argsFingerprint: 'groq|llama-3.3|0.2|1024|false|/proj',
      );

      manager.requestRestart(
        reason: 'different model',
        source: OrchestratorStopSource.modelSwitch,
        argsFingerprint: 'groq|llama-3.1|0.2|1024|false|/proj',
      );

      expect(manager.hasPendingRestart, isTrue);
      // Parking is not a teardown: the live turn keeps running.
      expect(manager.isBusy, isTrue);
    });

    test('while idle a restart request is simply noted', () {
      manager.debugSetSessionState(state: OrchestratorSessionState.idle);

      manager.requestRestart(
        reason: 'different model',
        source: OrchestratorStopSource.modelSwitch,
        argsFingerprint: 'groq|other|0.2|1024|false|/proj',
      );

      // Nothing is parked: the next launch picks the configuration up anyway.
      expect(manager.hasPendingRestart, isFalse);
      expect(manager.isRunning, isTrue);
    });
  });

  group('fingerprintFor', () {
    test('is stable for identical arguments', () {
      final a = OrchestratorManager.fingerprintFor(
        backend: OrchestratorBackend.groq,
        modelId: 'llama-3.3',
        temperature: 0.2,
        maxTokens: 1024,
        basePath: '/proj',
      );
      final b = OrchestratorManager.fingerprintFor(
        backend: OrchestratorBackend.groq,
        modelId: 'llama-3.3',
        temperature: 0.2,
        maxTokens: 1024,
        basePath: '/proj',
      );

      expect(a, b);
    });

    test('changes when any launch-relevant argument changes', () {
      final base = OrchestratorManager.fingerprintFor(
        backend: OrchestratorBackend.groq,
        modelId: 'llama-3.3',
        temperature: 0.2,
        maxTokens: 1024,
        basePath: '/proj',
      );

      expect(
        OrchestratorManager.fingerprintFor(
          backend: OrchestratorBackend.gemini,
          modelId: 'llama-3.3',
          temperature: 0.2,
          maxTokens: 1024,
          basePath: '/proj',
        ),
        isNot(base),
      );
      expect(
        OrchestratorManager.fingerprintFor(
          backend: OrchestratorBackend.groq,
          modelId: 'llama-3.1',
          temperature: 0.2,
          maxTokens: 1024,
          basePath: '/proj',
        ),
        isNot(base),
      );
      expect(
        OrchestratorManager.fingerprintFor(
          backend: OrchestratorBackend.groq,
          modelId: 'llama-3.3',
          temperature: 0.7,
          maxTokens: 1024,
          basePath: '/proj',
        ),
        isNot(base),
      );
      expect(
        OrchestratorManager.fingerprintFor(
          backend: OrchestratorBackend.groq,
          modelId: 'llama-3.3',
          temperature: 0.2,
          maxTokens: 2048,
          basePath: '/proj',
        ),
        isNot(base),
      );
      expect(
        OrchestratorManager.fingerprintFor(
          backend: OrchestratorBackend.groq,
          modelId: 'llama-3.3',
          temperature: 0.2,
          maxTokens: 1024,
          multiAgent: true,
          basePath: '/proj',
        ),
        isNot(base),
      );
      expect(
        OrchestratorManager.fingerprintFor(
          backend: OrchestratorBackend.groq,
          modelId: 'llama-3.3',
          temperature: 0.2,
          maxTokens: 1024,
          basePath: '/other',
        ),
        isNot(base),
      );
    });

    test('matchesFingerprint is false when no session is running', () {
      final fingerprint = OrchestratorManager.fingerprintFor(
        backend: OrchestratorBackend.groq,
        modelId: 'llama-3.3',
        basePath: '/proj',
      );

      manager.debugSetSessionState(
        state: OrchestratorSessionState.idle,
        argsFingerprint: fingerprint,
      );
      expect(manager.matchesFingerprint(fingerprint), isTrue);

      manager.debugSetSessionState(state: OrchestratorSessionState.stopped);
      expect(manager.matchesFingerprint(fingerprint), isFalse);
    });
  });
}