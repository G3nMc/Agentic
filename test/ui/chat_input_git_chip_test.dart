import 'dart:io';

import 'package:agentic/data/database/app_database.dart';
import 'package:agentic/services/project_service.dart';
import 'package:agentic/ui/widgets/chat_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Git branch chip contract for [ChatInput].
///
/// The chip used to be rendered only when `_branches` was non-empty, so a
/// packaged build (whose process working directory is the install directory,
/// not a repository) hid the control with no explanation while an IDE-launched
/// debug run — where the CWD *is* the repository — painted it. The tests below
/// pin the corrected contract:
///
///  * no explicit project folder  -> no chip at all;
///  * explicit folder, no repo    -> chip visible, disabled, reason in tooltip;
///  * explicit folder, real repo  -> chip visible with the branch dropdown;
///  * folder selected after mount -> chip appears (notifier subscription).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Probed once at registration time so the repository test can be skipped on
  /// machines without a git executable instead of failing for the wrong reason.
  final String? gitExe = () {
    try {
      final result = Process.runSync('git', ['--version']);
      return result.exitCode == 0 ? 'git' : null;
    } catch (_) {
      return null;
    }
  }();

  late Directory tmp;

  /// Drive the tree while real async work (SQLite, `Process.run`) completes.
  ///
  /// `pumpAndSettle` cannot be used: the chip renders an indeterminate
  /// `CircularProgressIndicator` while the branch lookup is in flight, which
  /// schedules frames for ever.
  Future<void> pumpFrames(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> mountInput(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatInput(
            enabled: true,
            sending: false,
            onSend: (_) async {},
          ),
        ),
      ),
    );
    await pumpFrames(tester);
  }

  /// The chip always renders the `Git: ` label, so it doubles as the anchor for
  /// the tooltip that carries the failure reason.
  String? chipTooltip(WidgetTester tester) {
    final finder = find.ancestor(
      of: find.text('Git: '),
      matching: find.byType(Tooltip),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Tooltip>(finder.first).message;
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;

    // flutter_secure_storage has no platform implementation under test.
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

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agentic_git_chip_test_');
    AppDatabase.debugProjectDatabasePathOverride =
        p.join(tmp.path, 'project.db');
    AppDatabase.debugGlobalDatabasePathOverride = p.join(tmp.path, 'global.db');

    // ProjectService is a process-wide singleton: clear anything a previous
    // test left behind so `hasExplicitFolder` starts false.
    await ProjectService().init();
    for (final folder in ProjectService().projectFolders) {
      await ProjectService().removeProjectFolder(folder);
    }
  });

  tearDown(() {
    AppDatabase.debugProjectDatabasePathOverride = null;
    AppDatabase.debugGlobalDatabasePathOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // Best-effort cleanup; a locked file must not fail the suite.
    }
  });

  testWidgets('no project folder selected hides the git chip',
      (tester) async {
    await mountInput(tester);

    expect(
      ProjectService().hasExplicitFolder,
      isFalse,
      reason: 'the test must start without an explicit project folder',
    );
    expect(
      find.text('Git: '),
      findsNothing,
      reason: 'without a project there is nothing to show a branch of',
    );

    await unmount(tester);
  });

  testWidgets(
    'selecting a project folder after mount reveals the chip with a reason '
    'when the folder is not a git repository',
    (tester) async {
      final plain = Directory(p.join(tmp.path, 'plain'))..createSync();

      await mountInput(tester);
      expect(find.text('Git: '), findsNothing);

      // Selecting from Settings changes the active project without remounting
      // this widget: the notifier subscription is what must refresh the chip.
      await tester.runAsync(() => ProjectService().addProjectFolder(plain.path));
      await pumpFrames(tester);

      expect(
        find.text('Git: '),
        findsOneWidget,
        reason: 'an explicit project must always surface the git chip',
      );
      expect(
        find.text('\u2014'),
        findsOneWidget,
        reason: 'a disabled placeholder replaces the dropdown when no branch '
            'can be listed',
      );

      final message = chipTooltip(tester);
      expect(message, isNotNull);
      expect(
        message,
        isNot('Loading git branches…'),
        reason: 'the lookup must have completed',
      );
      expect(
        message!.toLowerCase(),
        contains('git'),
        reason: 'the failure reason must be surfaced instead of swallowed',
      );

      await unmount(tester);
    },
  );

  testWidgets(
    'a real git repository renders the branch dropdown',
    (tester) async {
      final repo = Directory(p.join(tmp.path, 'repo'))..createSync();

      await Process.run(gitExe!, ['-C', repo.path, 'init']);
      await Process.run(
        gitExe,
        ['-C', repo.path, 'checkout', '-b', 'agentic-test-branch'],
      );
      await Process.run(gitExe, [
        '-C',
        repo.path,
        '-c',
        'user.name=Agentic Test',
        '-c',
        'user.email=test@example.com',
        '-c',
        'commit.gpgsign=false',
        'commit',
        '--allow-empty',
        '-m',
        'init',
      ]);

      await tester.runAsync(() => ProjectService().addProjectFolder(repo.path));
      await mountInput(tester);

      expect(find.text('Git: '), findsOneWidget);
      expect(
        find.text('agentic-test-branch'),
        findsWidgets,
        reason: 'the checked-out branch must be listed and pre-selected',
      );
      expect(
        find.text('\u2014'),
        findsNothing,
        reason: 'the placeholder must not appear when branches exist',
      );
      expect(
        chipTooltip(tester),
        'Switch branch',
        reason: 'a usable chip advertises the action it performs',
      );

      await unmount(tester);
    },
    skip: gitExe == null,
  );

  testWidgets(
    'switching the project from Settings refreshes the chip after it has '
    'already rendered a branch list',
    (tester) async {
      final first = Directory(p.join(tmp.path, 'first'))..createSync();
      final second = Directory(p.join(tmp.path, 'second'))..createSync();

      await tester.runAsync(() => ProjectService().addProjectFolder(first.path));
      await mountInput(tester);
      expect(find.text('Git: '), findsOneWidget);

      await tester.runAsync(() => ProjectService().addProjectFolder(second.path));
      await pumpFrames(tester);

      expect(
        ProjectService().currentPath,
        ProjectService().projectFolders.firstWhere((f) => f.endsWith('second')),
        reason: 'the second folder must have become the active project',
      );
      expect(
        find.text('Git: '),
        findsOneWidget,
        reason: 'the chip must survive the switch instead of disappearing',
      );
      expect(
        chipTooltip(tester),
        isNot('Loading git branches…'),
        reason: 'the reload triggered by the notifier must finish',
      );

      await unmount(tester);
    },
  );
}