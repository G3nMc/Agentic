import 'dart:io';

/// A resolved shell invocation that hands a path to the operating system's
/// default application (a text editor for plain-text logs, the file manager
/// for directories, and so on).
class SystemOpenCommand {
  const SystemOpenCommand(this.executable, this.arguments);

  /// Program to launch, e.g. `rundll32.exe`, `open`, `xdg-open`.
  final String executable;

  /// Arguments passed verbatim — the target path is always a single argument so
  /// paths containing spaces are never split.
  final List<String> arguments;

  @override
  String toString() => '$executable ${arguments.join(' ')}';
}

/// Raised when the OS default-application launcher cannot be resolved or
/// started. Callers surface this to the user instead of failing silently.
class SystemOpenException implements Exception {
  SystemOpenException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds the platform-specific command that opens [path] with the default
/// application registered for its file type.
///
/// The platform flags are injected rather than read from [Platform] so the
/// mapping can be unit-tested on any host OS.
SystemOpenCommand resolveSystemOpenCommand(
  String path, {
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) {
  if (isWindows) {
    // The shell's file-protocol handler: opens the path with whatever
    // application owns the extension (Notepad / the user's default editor for
    // `.log` and `.txt`).
    return SystemOpenCommand(
      'rundll32.exe',
      ['url.dll,FileProtocolHandler', path],
    );
  }
  if (isMacOS) {
    return SystemOpenCommand('open', [path]);
  }
  if (isLinux) {
    return SystemOpenCommand('xdg-open', [path]);
  }
  throw SystemOpenException(
    'Opening files with the system default application is not supported on '
    'this platform.',
  );
}

/// Opens [path] with the operating system's default application.
///
/// The launcher is detached, so the calling application does not wait for the
/// editor to close and no child-process handle is leaked. Throws
/// [SystemOpenException] when the launcher cannot be started, which lets the UI
/// tell the user why nothing happened.
Future<void> openWithDefaultApplication(String path) async {
  final command = resolveSystemOpenCommand(
    path,
    isWindows: Platform.isWindows,
    isMacOS: Platform.isMacOS,
    isLinux: Platform.isLinux,
  );
  try {
    await Process.start(
      command.executable,
      command.arguments,
      mode: ProcessStartMode.detached,
    );
  } on ProcessException catch (e) {
    throw SystemOpenException(
      'Could not launch ${command.executable}: ${e.message}',
    );
  }
}