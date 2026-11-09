import 'dart:convert';
import 'dart:io';

import 'package:agentic/data/database/app_database.dart';
import 'package:agentic/data/repositories/backend_settings_repository.dart';
import 'package:agentic/data/repositories/settings_repository.dart';
import 'package:agentic/services/llm_service.dart';
import 'package:agentic/services/orchestrator_manager.dart';
import 'package:agentic/services/project_service.dart';
import 'package:agentic/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// P2 exit criteria: every Settings affordance is a *configuration change*.
///
/// Changing a model, switching backend, or activating another project folder
/// must park a relaunch (`requestRestart`) and must never request a teardown
/// from the chat STOP source. The only affordance in this screen that may
/// terminate a live turn is the explicit STOP button in the Orchestrator panel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  /// Drive the tree while real async work (SQLite, file IO) completes.
  ///
  /// `pumpAndSettle` cannot be used: the panel renders indeterminate progress
  /// indicators while it loads, which schedule frames for ever.
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

    // flutter_secure_storage has no platform implementation under test. Stub
    // the channel so credential reads resolve to "unset" instead of throwing.
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
    tmp = Directory.systemTemp.createTempSync('agentic_settings_test_');
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

  /// Mount an embedded Settings panel and let it finish loading.
  Future<void> pumpSettings(WidgetTester tester, {int section = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(initialSection: section),
        ),
      ),
    );
    await pumpFrames(tester);
  }

  /// Assertions shared by every "configuration change" case.
  void expectParkedRestartNotKill() {
    expect(
      OrchestratorManager.debugRestartReasons,
      isNotEmpty,
      reason: 'a configuration change must request a relaunch',
    );
    expect(
      OrchestratorManager.debugStopCalls
          .where((s) => s == OrchestratorStopSource.chatStopButton),
      isEmpty,
      reason: 'a settings change must never stop the session from the chat path',
    );
    expect(
      OrchestratorManager.debugStopCalls,
      isEmpty,
      reason: 'no Settings configuration affordance may terminate the session',
    );
  }

  /// Invoke the single model dropdown's change handler directly.
  ///
  /// The menu animation is irrelevant to this contract: what matters is that
  /// the callback wired into the dropdown parks a relaunch instead of killing
  /// the session. Driving the callback keeps the test hermetic and immune to
  /// overlay hit-testing.
  Future<void> selectModel(
    WidgetTester tester, {
    required String model,
  }) async {
    final dropdown = find.byType(DropdownButton<String>);
    expect(dropdown, findsOneWidget);
    final widget = tester.widget<DropdownButton<String>>(dropdown);
    expect(widget.onChanged, isNotNull);
    widget.onChanged!(model);
    await pumpFrames(tester);
  }

  testWidgets('changing the Groq model parks a relaunch and never kills',
      (tester) async {
    final repo = BackendSettingsRepository.instance;
    await tester.runAsync(() async {
      await repo.setActiveBackend(LlmBackend.groqOrchestrator);
      await repo.setGroqModel('llama-3.3-70b-versatile');
    });

    await pumpSettings(tester);
    await selectModel(tester, model: 'llama-3.1-8b-instant');

    expect(
      OrchestratorManager.debugRestartReasons
          .any((r) => r.contains('Groq model changed')),
      isTrue,
    );
    expectParkedRestartNotKill();
    expect(await repo.getGroqModel(), 'llama-3.1-8b-instant');
  });

  testWidgets('changing the Gemini model parks a relaunch and never kills',
      (tester) async {
    final repo = BackendSettingsRepository.instance;
    await tester.runAsync(() async {
      await repo.setActiveBackend(LlmBackend.geminiOrchestrator);
      await repo.setGeminiModel('gemini-2.5-flash');
    });

    await pumpSettings(tester);
    await selectModel(tester, model: 'gemini-2.5-pro');

    expect(
      OrchestratorManager.debugRestartReasons
          .any((r) => r.contains('Gemini model changed')),
      isTrue,
    );
    expectParkedRestartNotKill();
    expect(await repo.getGeminiModel(), 'gemini-2.5-pro');
  });

  testWidgets('changing the OpenRouter model parks a relaunch and never kills',
      (tester) async {
    final repo = BackendSettingsRepository.instance;
    await tester.runAsync(() async {
      await repo.setActiveBackend(LlmBackend.openRouterOrchestrator);
      // No API key on purpose: the catalog fetch is skipped, and the persisted
      // model is still surfaced so the dropdown renders.
      await repo.setOpenRouterModel('openai/gpt-5-mini');
    });

    await pumpSettings(tester);
    await selectModel(tester, model: 'anthropic/claude-sonnet-4');

    expect(
      OrchestratorManager.debugRestartReasons
          .any((r) => r.contains('OpenRouter model changed')),
      isTrue,
    );
    expectParkedRestartNotKill();
    expect(await repo.getOpenRouterModel(), 'anthropic/claude-sonnet-4');
  });

  testWidgets('switching the active backend parks a relaunch and never kills',
      (tester) async {
    final repo = BackendSettingsRepository.instance;
    await tester.runAsync(() async {
      await repo.setActiveBackend(LlmBackend.groqOrchestrator);
    });

    await pumpSettings(tester);

    final dropdown = find.byType(DropdownButton<LlmBackend>);
    expect(dropdown, findsOneWidget);
    final widget = tester.widget<DropdownButton<LlmBackend>>(dropdown);
    expect(widget.onChanged, isNotNull);
    widget.onChanged!(LlmBackend.geminiOrchestrator);
    await pumpFrames(tester);

    expect(
      OrchestratorManager.debugRestartReasons
          .any((r) => r.contains('active backend changed')),
      isTrue,
    );
    expectParkedRestartNotKill();
    expect(await repo.getActiveBackend(), LlmBackend.geminiOrchestrator);
  });

  testWidgets('activating another project folder parks a relaunch and never '
      'kills', (tester) async {
    final projectA = Directory(p.join(tmp.path, 'projA'))..createSync();
    final projectB = Directory(p.join(tmp.path, 'projB'))..createSync();

    await tester.runAsync(() async {
      await SettingsRepository.instance.set(
        'project_folders',
        jsonEncode([projectA.path, projectB.path]),
      );
      await SettingsRepository.instance.set(
        'last_project_folder',
        projectA.path,
      );
      await ProjectService().init();
    });

    await pumpSettings(tester, section: 0);

    final activate = find.byTooltip('Activate this project');
    expect(
      activate,
      findsOneWidget,
      reason: 'the inactive project folder must offer an activate action',
    );
    await tester.ensureVisible(activate);
    await tester.pump();
    await tester.tap(activate);
    await pumpFrames(tester);

    expect(ProjectService().activeProjectKey, projectB.path);
    expect(
      OrchestratorManager.debugRestartReasons
          .any((r) => r.contains('project folder switched')),
      isTrue,
    );
    expectParkedRestartNotKill();
  });

  testWidgets(
    'pressing STOP in the Orchestrator panel is the single authorised kill',
    (tester) async {
      final repo = BackendSettingsRepository.instance;
      await tester.runAsync(() async {
        await repo.setActiveBackend(LlmBackend.groqOrchestrator);
      });

      // Pretend a session is live so the Stop button is enabled. Not busy, so
      // no confirmation dialog is raised.
      OrchestratorManager.instance.debugSetSessionState(
        state: OrchestratorSessionState.idle,
      );

      await pumpSettings(tester, section: 2);
      OrchestratorManager.debugStopCalls.clear();
      OrchestratorManager.debugRestartReasons.clear();

      final stop = find.widgetWithText(OutlinedButton, 'Stop');
      expect(stop, findsOneWidget);
      await tester.ensureVisible(stop);
      await tester.pump();
      await tester.tap(stop);
      await pumpFrames(tester);

      expect(
        OrchestratorManager.debugStopCalls,
        [OrchestratorStopSource.orchestratorSettingsButton],
        reason: 'exactly one teardown, attributed to the Settings STOP button',
      );
      expect(OrchestratorManager.instance.isRunning, isFalse);

      // Dispose the live-session card so its 1 s ticker is cancelled.
      await tester.pumpWidget(const SizedBox());
    },
  );
}