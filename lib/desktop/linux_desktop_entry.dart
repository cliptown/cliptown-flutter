import 'dart:io';

import 'launch_at_login.dart' show desktopEntryExecQuote;

const String _desktopFileName = 'cliptown.desktop';

/// Bundled icon, relative to the directory that holds the executable.
const List<String> _bundledIconPath = <String>[
  'data',
  'flutter_assets',
  'assets',
  'icon',
  'app_icon_256.png',
];

/// XDG application entry so desktop launchers (GNOME Activities, KDE,
/// app menus) can find ClipTown by name, show its icon, and match its window.
/// Null when a path cannot be written safely into a desktop entry.
String? linuxApplicationEntry({
  required String executable,
  required String iconPath,
}) {
  final exec = desktopEntryExecQuote(executable);
  if (exec == null || RegExp(r'[\x00-\x1f\x7f]').hasMatch(iconPath)) {
    return null;
  }
  return '[Desktop Entry]\n'
      'Type=Application\n'
      'Name=ClipTown\n'
      'GenericName=Clipboard history\n'
      'Comment=Encrypted, searchable clipboard history\n'
      'Exec=$exec\n'
      'Icon=$iconPath\n'
      'Terminal=false\n'
      'Categories=Utility;\n'
      'Keywords=clipboard;history;paste;copy;snippets;\n'
      'StartupWMClass=cliptown_app\n';
}

/// Registers ClipTown with the desktop launcher on Linux.
///
/// The Linux bundle has no installer, so the app keeps its own entry current:
/// written only when missing or different (e.g. the bundle moved), atomically,
/// and never inside Flatpak/Snap sandboxes, which ship their own entry.
/// Returns whether a file was written.
Future<bool> registerLinuxDesktopEntry({
  required String executable,
  required String applicationsDirectory,
  required Map<String, String> environment,
}) async {
  if (environment.containsKey('FLATPAK_ID') ||
      environment.containsKey('SNAP')) {
    return false;
  }
  final bundleDirectory = File(executable).parent.path;
  final iconPath = <String>[bundleDirectory, ..._bundledIconPath].join('/');
  final contents = linuxApplicationEntry(
    executable: executable,
    iconPath: iconPath,
  );
  if (contents == null) return false;
  final entry = File('$applicationsDirectory/$_desktopFileName');
  try {
    if (await entry.readAsString() == contents) return false;
  } on FileSystemException {
    // Missing: write it below.
  }
  await Directory(applicationsDirectory).create(recursive: true);
  final staging = File('${entry.path}.tmp');
  await staging.writeAsString(contents, flush: true);
  await staging.rename(entry.path);
  return true;
}

/// `$XDG_DATA_HOME/applications`, defaulting to `~/.local/share/applications`.
String? linuxApplicationsDirectory(Map<String, String> environment) {
  final dataHome = environment['XDG_DATA_HOME'];
  if (dataHome != null && dataHome.isNotEmpty) return '$dataHome/applications';
  final home = environment['HOME'];
  if (home == null || home.isEmpty) return null;
  return '$home/.local/share/applications';
}

/// Best-effort registration at startup; never blocks or fails the app.
Future<void> registerLinuxDesktopEntryForCurrentProcess() async {
  if (!Platform.isLinux) return;
  final environment = Platform.environment;
  final directory = linuxApplicationsDirectory(environment);
  if (directory == null) return;
  try {
    await registerLinuxDesktopEntry(
      executable: Platform.resolvedExecutable,
      applicationsDirectory: directory,
      environment: environment,
    );
  } on Object {
    // A read-only home or odd XDG layout only costs launcher discoverability.
  }
}
