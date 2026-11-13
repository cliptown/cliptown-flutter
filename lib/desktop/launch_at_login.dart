import 'dart:io';

import 'package:flutter/services.dart';

/// Command-line flag the login item passes so ClipTown starts quietly in the
/// tray instead of opening its window over the user's desktop.
const String startHiddenArgument = '--hidden';

const String _windowsRunKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
const String _windowsRunValue = 'ClipTown';
const String _linuxAutostartFileName = 'cliptown.desktop';

/// Opening ClipTown automatically when the user logs in.
abstract interface class LaunchAtLogin {
  Future<bool> isEnabled();

  Future<void> setEnabled(bool enabled);
}

/// Returns the platform login-item implementation, or null where none exists.
LaunchAtLogin? platformLaunchAtLogin() {
  if (Platform.isMacOS) return const MacOSLaunchAtLogin();
  if (Platform.isWindows) {
    return WindowsLaunchAtLogin(executable: Platform.resolvedExecutable);
  }
  if (Platform.isLinux) {
    final xdgConfig = Platform.environment['XDG_CONFIG_HOME'];
    final home = Platform.environment['HOME'];
    final configHome = xdgConfig != null && xdgConfig.isNotEmpty
        ? xdgConfig
        : home != null && home.isNotEmpty
        ? '$home/.config'
        : null;
    if (configHome == null) return null;
    return LinuxLaunchAtLogin(
      autostartDirectory: '$configHome/autostart',
      executable: Platform.resolvedExecutable,
    );
  }
  return null;
}

/// Whether this process was started by the login item (and so should stay
/// hidden in the tray).
Future<bool> launchedAtLogin(List<String> arguments) async {
  if (arguments.contains(startHiddenArgument)) return true;
  if (!Platform.isMacOS) return false;
  try {
    return await MacOSLaunchAtLogin._channel.invokeMethod<bool>(
          'launchedAtLogin',
        ) ??
        false;
  } on Object {
    return false;
  }
}

/// macOS 13+ `SMAppService.mainApp`, implemented in `MainFlutterWindow.swift`.
/// Works inside the App Sandbox and appears in System Settings → Login Items.
class MacOSLaunchAtLogin implements LaunchAtLogin {
  const MacOSLaunchAtLogin();

  static const MethodChannel _channel = MethodChannel(
    'cliptown/launch_at_login',
  );

  @override
  Future<bool> isEnabled() async =>
      await _channel.invokeMethod<bool>('isEnabled') ?? false;

  @override
  Future<void> setEnabled(bool enabled) => _channel.invokeMethod<void>(
    'setEnabled',
    <String, Object>{'enabled': enabled},
  );
}

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// `HKCU\...\Run` value pointing at the installed executable.
class WindowsLaunchAtLogin implements LaunchAtLogin {
  WindowsLaunchAtLogin({required this.executable, ProcessRunner? run})
    : _run = run ?? Process.run;

  final String executable;
  final ProcessRunner _run;

  String get runCommand => windowsRunCommand(executable);

  /// Enabled only when the Run value launches *this* executable; a value left
  /// behind by a moved or older install reads as off and is rewritten.
  @override
  Future<bool> isEnabled() async {
    final result = await _run('reg', <String>[
      'query',
      _windowsRunKey,
      '/v',
      _windowsRunValue,
    ]);
    return result.exitCode == 0 &&
        '${result.stdout}'.toLowerCase().contains(runCommand.toLowerCase());
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    final result = await _run(
      'reg',
      enabled
          ? <String>[
              'add',
              _windowsRunKey,
              '/v',
              _windowsRunValue,
              '/t',
              'REG_SZ',
              '/d',
              runCommand,
              '/f',
            ]
          : <String>['delete', _windowsRunKey, '/v', _windowsRunValue, '/f'],
    );
    // Deleting an absent value is already the requested state.
    if (result.exitCode != 0 && enabled) {
      throw ProcessException(
        'reg',
        const <String>[],
        'login item update failed',
      );
    }
  }
}

String windowsRunCommand(String executable) =>
    '"$executable" $startHiddenArgument';

/// XDG autostart entry (`~/.config/autostart/cliptown.desktop`).
class LinuxLaunchAtLogin implements LaunchAtLogin {
  const LinuxLaunchAtLogin({
    required this.autostartDirectory,
    required this.executable,
  });

  final String autostartDirectory;
  final String executable;

  File get _entry => File('$autostartDirectory/$_linuxAutostartFileName');

  /// Enabled only when the entry launches *this* executable.
  @override
  Future<bool> isEnabled() async {
    try {
      return await _entry.readAsString() == linuxAutostartEntry(executable);
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<void> setEnabled(bool enabled) async {
    if (!enabled) {
      if (await _entry.exists()) await _entry.delete();
      return;
    }
    await Directory(autostartDirectory).create(recursive: true);
    // Write-then-rename so a crash never leaves a truncated autostart entry.
    final staging = File('${_entry.path}.tmp');
    await staging.writeAsString(linuxAutostartEntry(executable), flush: true);
    await staging.rename(_entry.path);
  }
}

/// Desktop Entry `Exec` quoting: the path is double-quoted and the reserved
/// characters `"`, `` ` ``, `$` and `\` are backslash-escaped; `%` is doubled
/// because it introduces field codes. Control characters (a newline would
/// start a new key, e.g. a second `Exec=`) are rejected outright.
String desktopEntryExecQuote(String path) {
  if (path.isEmpty || RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
    throw ArgumentError.value(path, 'path', 'unsafe for a desktop entry');
  }
  final escaped = path
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$')
      .replaceAll('%', '%%');
  return '"$escaped"';
}

String linuxAutostartEntry(String executable) {
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=ClipTown\n'
      'Comment=Encrypted clipboard history\n'
      'Exec=${desktopEntryExecQuote(executable)} $startHiddenArgument\n'
      'Terminal=false\n'
      'X-GNOME-Autostart-enabled=true\n';
}
