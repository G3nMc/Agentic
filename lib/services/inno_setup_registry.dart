/// Emitters for the `[Registry]` section of the Inno Setup script generated
/// by the Developer panel installer builder.
///
/// The installed app is per-user (`PrivilegesRequired=lowest`, install root
/// `{localappdata}\Programs\Agentic`), so every entry here is written under
/// `HKCU` and never touches `HKLM`.
///
/// Extracted from `settings_screen.dart` so the generated lines can be
/// asserted by unit tests without building the whole settings screen.
class InnoSetupRegistry {
  const InnoSetupRegistry._();

  /// `RUNASADMIN` AppCompat layer for [exeName].
  ///
  /// Windows then always starts the app elevated (one UAC consent per launch)
  /// without a modified Flutter runner manifest, so the Python orchestrator
  /// and every child process it spawns (git, python, flutter) inherit an
  /// elevated token and can resolve the install path and the user's
  /// repositories.
  static String elevationEntry(String exeName) =>
      'Root: HKCU; Subkey: "Software\\Microsoft\\Windows NT\\CurrentVersion'
      '\\AppCompatFlags\\Layers"; ValueType: string; '
      'ValueName: "{app}\\$exeName"; ValueData: "RUNASADMIN"; '
      'Flags: uninsdeletevalue';

  /// Registers the full path of [exeName] under `App Paths`, so shells
  /// (cmd, PowerShell, Git Bash) and `CreateProcess` resolve the bare name
  /// `agentic.exe` to the installed binary.
  static String appPathEntry(String exeName) =>
      'Root: HKCU; Subkey: "Software\\Microsoft\\Windows\\CurrentVersion'
      '\\App Paths\\$exeName"; ValueType: string; ValueName: ""; '
      'ValueData: "{app}\\$exeName"; Flags: uninsdeletekey';

  /// Publishes the install folder under `App Paths\..\Path`, so tools that
  /// only know the executable name can also locate its working directory.
  static String appSearchPathVariable(String exeName) =>
      'Root: HKCU; Subkey: "Software\\Microsoft\\Windows\\CurrentVersion'
      '\\App Paths\\$exeName"; ValueType: string; ValueName: "Path"; '
      'ValueData: "{app}"; Flags: uninsdeletekey';

  /// Complete body of the `[Registry]` section, one entry per line.
  static List<String> section({required String exeName}) => <String>[
        elevationEntry(exeName),
        appPathEntry(exeName),
        appSearchPathVariable(exeName),
      ];
}