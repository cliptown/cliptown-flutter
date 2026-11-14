import 'dart:io';

import 'package:cliptown_app/desktop/launch_at_login.dart';
import 'package:cliptown_app/desktop/linux_desktop_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late String applications;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cliptown-xdg');
    applications = '${root.path}/applications';
  });
  tearDown(() => root.delete(recursive: true));

  File entry() => File('$applications/cliptown.desktop');

  test('entry makes ClipTown searchable with its icon', () async {
    final wrote = await registerLinuxDesktopEntry(
      executable: '/opt/ClipTown/cliptown_app',
      applicationsDirectory: applications,
      environment: const <String, String>{},
    );
    expect(wrote, isTrue);
    final text = entry().readAsStringSync();
    expect(text, contains('Name=ClipTown\n'));
    expect(text, contains('Exec="/opt/ClipTown/cliptown_app"\n'));
    expect(
      text,
      contains(
        'Icon=/opt/ClipTown/data/flutter_assets/assets/icon/app_icon_256.png\n',
      ),
    );
    expect(text, contains('Keywords=clipboard;'));
    expect(text, contains('StartupWMClass=cliptown_app\n'));
  });

  test(
    'only writes when missing or stale, and leaves no staging file',
    () async {
      Future<bool> register(String exe) => registerLinuxDesktopEntry(
        executable: exe,
        applicationsDirectory: applications,
        environment: const <String, String>{},
      );
      expect(await register('/opt/a/cliptown_app'), isTrue);
      expect(await register('/opt/a/cliptown_app'), isFalse);
      expect(await register('/home/u/moved/cliptown_app'), isTrue);
      expect(
        entry().readAsStringSync(),
        contains('/home/u/moved/cliptown_app'),
      );
      expect(
        Directory(applications).listSync().map((e) => e.uri.pathSegments.last),
        <String>['cliptown.desktop'],
      );
    },
  );

  test('sandboxed packages keep their own entry', () async {
    for (final env in <Map<String, String>>[
      <String, String>{'FLATPAK_ID': 'com.cliptown.ClipTown'},
      <String, String>{'SNAP': '/snap/cliptown/1'},
    ]) {
      expect(
        await registerLinuxDesktopEntry(
          executable: '/app/cliptown_app',
          applicationsDirectory: applications,
          environment: env,
        ),
        isFalse,
      );
    }
    expect(entry().existsSync(), isFalse);
  });

  test('a newline in the path cannot inject desktop-entry keys', () async {
    expect(
      await registerLinuxDesktopEntry(
        executable: '/opt/x\nExec=/tmp/evil/cliptown_app',
        applicationsDirectory: applications,
        environment: const <String, String>{},
      ),
      isFalse,
    );
    expect(entry().existsSync(), isFalse);
    expect(linuxAutostartEntry('/opt/x\nExec=/tmp/evil'), isNull);
    expect(desktopEntryExecQuote(''), isNull);
    expect(desktopEntryExecQuote(r'/a b/$x'), r'"/a b/\$x"');
  });

  test('applications directory follows XDG_DATA_HOME, then HOME', () {
    expect(
      linuxApplicationsDirectory(<String, String>{'XDG_DATA_HOME': '/d'}),
      '/d/applications',
    );
    expect(
      linuxApplicationsDirectory(<String, String>{'HOME': '/home/u'}),
      '/home/u/.local/share/applications',
    );
    expect(linuxApplicationsDirectory(const <String, String>{}), isNull);
  });
}
