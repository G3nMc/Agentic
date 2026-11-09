import 'package:agentic/core/utils/system_open.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveSystemOpenCommand', () {
    test('uses the Windows file-protocol handler on Windows', () {
      final cmd = resolveSystemOpenCommand(
        r'C:\Users\me\orchestrator_log.txt',
        isWindows: true,
        isMacOS: false,
        isLinux: false,
      );

      expect(cmd.executable, 'rundll32.exe');
      expect(cmd.arguments, ['url.dll,FileProtocolHandler', r'C:\Users\me\orchestrator_log.txt']);
    });

    test('uses open on macOS', () {
      final cmd = resolveSystemOpenCommand(
        '/Users/me/orchestrator_log.txt',
        isWindows: false,
        isMacOS: true,
        isLinux: false,
      );

      expect(cmd.executable, 'open');
      expect(cmd.arguments, ['/Users/me/orchestrator_log.txt']);
    });

    test('uses xdg-open on Linux', () {
      final cmd = resolveSystemOpenCommand(
        '/home/me/orchestrator log.txt',
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      );

      expect(cmd.executable, 'xdg-open');
      expect(cmd.arguments, ['/home/me/orchestrator log.txt']);
    });

    test('keeps paths with spaces as a single argument', () {
      final cmd = resolveSystemOpenCommand(
        '/tmp/my logs/agent log.txt',
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      );

      expect(cmd.arguments.length, 1);
      expect(cmd.arguments.single, '/tmp/my logs/agent log.txt');
    });

    test('throws on unsupported platforms', () {
      expect(
        () => resolveSystemOpenCommand(
          '/tmp/log.txt',
          isWindows: false,
          isMacOS: false,
          isLinux: false,
        ),
        throwsA(isA<SystemOpenException>()),
      );
    });
  });

  group('SystemOpenCommand', () {
    test('renders a human readable representation', () {
      const cmd = SystemOpenCommand('open', ['/tmp/log.txt']);
      expect(cmd.toString(), 'open /tmp/log.txt');
    });
  });
}