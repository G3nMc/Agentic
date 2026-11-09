import 'package:flutter_test/flutter_test.dart';
import 'package:agentic/services/inno_setup_registry.dart';

void main() {
  group('InnoSetupRegistry.elevationEntry', () {
    test('writes RUNASADMIN under the HKCU AppCompatFlags Layers key', () {
      final entry = InnoSetupRegistry.elevationEntry('agentic.exe');

      expect(entry, startsWith('Root: HKCU; '));
      expect(
        entry,
        contains(
          'Subkey: "Software\\Microsoft\\Windows NT\\CurrentVersion'
          '\\AppCompatFlags\\Layers"',
        ),
      );
      expect(entry, contains('ValueName: "{app}\\agentic.exe"'));
      expect(entry, contains('ValueData: "RUNASADMIN"'));
      expect(entry, contains('Flags: uninsdeletevalue'));
      expect(entry, isNot(contains('HKLM')));
    });

    test('uses the supplied executable name in ValueName', () {
      final entry = InnoSetupRegistry.elevationEntry('other.exe');

      expect(entry, contains('ValueName: "{app}\\other.exe"'));
      expect(entry, isNot(contains('agentic.exe')));
    });
  });

  group('InnoSetupRegistry.appPathEntry', () {
    test('registers the executable path under App Paths', () {
      final entry = InnoSetupRegistry.appPathEntry('agentic.exe');

      expect(entry, startsWith('Root: HKCU; '));
      expect(
        entry,
        contains(
          'Subkey: "Software\\Microsoft\\Windows\\CurrentVersion'
          '\\App Paths\\agentic.exe"',
        ),
      );
      expect(entry, contains('ValueName: ""'));
      expect(entry, contains('ValueData: "{app}\\agentic.exe"'));
      expect(entry, contains('Flags: uninsdeletekey'));
      expect(entry, isNot(contains('HKLM')));
    });
  });

  group('InnoSetupRegistry.appSearchPathVariable', () {
    test('publishes the install folder under App Paths Path', () {
      final entry = InnoSetupRegistry.appSearchPathVariable('agentic.exe');

      expect(entry, startsWith('Root: HKCU; '));
      expect(
        entry,
        contains(
          'Subkey: "Software\\Microsoft\\Windows\\CurrentVersion'
          '\\App Paths\\agentic.exe"',
        ),
      );
      expect(entry, contains('ValueName: "Path"'));
      expect(entry, contains('ValueData: "{app}"'));
      expect(entry, contains('Flags: uninsdeletekey'));
    });
  });

  group('InnoSetupRegistry.section', () {
    test('returns the three entries in elevation order', () {
      final lines = InnoSetupRegistry.section(exeName: 'agentic.exe');

      expect(lines, hasLength(3));
      expect(lines[0], contains('RUNASADMIN'));
      expect(lines[1], contains('App Paths\\agentic.exe"; ValueType: string; '
          'ValueName: ""'));
      expect(lines[2], contains('App Paths\\agentic.exe"'));
      expect(lines[2], contains('ValueName: "Path"'));
    });

    test('every line is a single-line HKCU registry entry', () {
      final lines = InnoSetupRegistry.section(exeName: 'agentic.exe');

      for (final line in lines) {
        expect(line, startsWith('Root: HKCU; '));
        expect(line, isNot(contains('\n')));
        expect(line, isNot(contains('HKLM')));
      }
    });

    test('threads the executable name through the section', () {
      final lines = InnoSetupRegistry.section(exeName: 'custom.exe');

      expect(lines[0], contains('ValueName: "{app}\\custom.exe"'));
      expect(lines[1], contains('App Paths\\custom.exe"'));
      expect(lines.join('\n'), isNot(contains('agentic.exe')));
    });
  });
}