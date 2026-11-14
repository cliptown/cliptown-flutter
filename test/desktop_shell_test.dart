import 'dart:async';
import 'dart:io';

import 'package:cliptown_app/desktop/desktop_shell.dart';
import 'package:cliptown_app/desktop/desktop_shortcuts.dart';
import 'package:cliptown_app/desktop/launch_at_login.dart';
import 'package:cliptown_app/desktop/tray_icon.dart';
import 'package:cliptown_app/history/clip_formatting.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/state/app_state_machine.dart';
import 'package:flutter/widgets.dart' show StringCharacters, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

class _RecordingTrayPort implements TrayIconPort {
  final List<TrayIconVariant> calls = <TrayIconVariant>[];
  bool fail = false;

  @override
  Future<void> setIcon(TrayIconVariant variant) async {
    calls.add(variant);
    if (fail && variant == TrayIconVariant.highlight) {
      throw StateError('tray gone');
    }
  }
}

ClipItem _clip(
  String id,
  String text, {
  ClipKind kind = ClipKind.text,
  bool pinned = false,
}) {
  final at = DateTime.utc(2026, 11, 13);
  return ClipItem(
    id: id,
    kind: kind,
    title: id,
    text: text,
    createdAt: at,
    lastUsedAt: at,
    pinned: pinned,
  );
}

void main() {
  group('shortcuts', () {
    test('summon is a system-wide Option/Alt+C, not Cmd/Ctrl+Shift+V', () {
      final hotKey = desktopSummonHotKey();
      expect(hotKey.physicalKey, PhysicalKeyboardKey.keyC);
      expect(hotKey.modifiers, <HotKeyModifier>[HotKeyModifier.alt]);
      expect(hotKey.scope, HotKeyScope.system);
    });

    test('Option/Alt+O opens the tray and Option/Alt+X can be global', () {
      final tray = desktopTrayHotKey();
      expect(tray.physicalKey, PhysicalKeyboardKey.keyO);
      expect(tray.modifiers, <HotKeyModifier>[HotKeyModifier.alt]);
      expect(tray.scope, HotKeyScope.system);
      final dismiss = desktopDismissHotKey();
      expect(dismiss.physicalKey, PhysicalKeyboardKey.keyX);
      expect(dismiss.scope, HotKeyScope.system);
      expect(trayShortcutLabel(isMacOS: true), '⌥O');
      expect(trayShortcutLabel(isMacOS: false), 'Alt+O');
    });

    test('Option/Alt+X is held system-wide only while the window shows', () {
      final machine = AppStateMachine.localReady(
        AppRuntimeKind.desktop,
        captureRequested: true,
      );
      addTearDown(machine.dispose);
      machine.dispatch(AppEvent.foregroundRequested);
      expect(dismissHotKeyWanted(machine.state), isTrue);
      machine.dispatch(AppEvent.backgroundRequested);
      expect(dismissHotKeyWanted(machine.state), isFalse);
    });

    test('dismiss is an in-app Option/Alt+X', () {
      expect(dismissActivator.trigger, LogicalKeyboardKey.keyX);
      expect(dismissActivator.alt, isTrue);
      expect(dismissActivator.meta || dismissActivator.control, isFalse);
    });

    test('labels follow platform conventions', () {
      expect(summonShortcutLabel(isMacOS: true), '⌥C');
      expect(summonShortcutLabel(isMacOS: false), 'Alt+C');
      expect(dismissShortcutLabel(isMacOS: true), '⌥X');
      expect(dismissShortcutLabel(isMacOS: false), 'Alt+X');
    });
  });

  group('tray icons', () {
    test('every platform resolves a bundled asset that exists', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        for (final variant in TrayIconVariant.values) {
          final asset = trayIconAsset(variant, platform: platform);
          expect(File(asset.path).existsSync(), isTrue, reason: '$asset');
          expect(
            File('pubspec.yaml').readAsStringSync(),
            contains('- ${asset.path}'),
          );
        }
      }
    });

    test('macOS rests on a template icon and flashes in colour', () {
      expect(
        trayIconAsset(TrayIconVariant.normal, platform: TargetPlatform.macOS),
        const TrayIconAsset('assets/tray/tray_template.png', isTemplate: true),
      );
      expect(
        trayIconAsset(
          TrayIconVariant.highlight,
          platform: TargetPlatform.macOS,
        ).isTemplate,
        isFalse,
      );
      expect(
        trayIconAsset(
          TrayIconVariant.normal,
          platform: TargetPlatform.windows,
        ).path,
        endsWith('.ico'),
      );
    });

    test('flash pulses and ends on the normal icon', () async {
      final port = _RecordingTrayPort();
      final flasher = TrayIconFlasher(port, delay: (_) async {});
      await flasher.flash();
      expect(port.calls, <TrayIconVariant>[
        TrayIconVariant.highlight,
        TrayIconVariant.normal,
        TrayIconVariant.highlight,
        TrayIconVariant.normal,
      ]);
      expect(flasher.flashing, isFalse);
    });

    test('a newer flash supersedes an in-flight one', () async {
      final port = _RecordingTrayPort();
      final gate = Future<void>.value();
      final flasher = TrayIconFlasher(port, pulses: 1, delay: (_) => gate);
      final first = flasher.flash();
      final second = flasher.flash();
      await Future.wait(<Future<void>>[first, second]);
      expect(port.calls.last, TrayIconVariant.normal);
      expect(
        port.calls.where((call) => call == TrayIconVariant.normal),
        hasLength(1),
        reason: 'only the newest flash restores the icon',
      );
    });

    test('tray failures never escape and restore the normal icon', () async {
      final port = _RecordingTrayPort()..fail = true;
      final flasher = TrayIconFlasher(port, delay: (_) async {});
      await flasher.flash();
      expect(port.calls, <TrayIconVariant>[
        TrayIconVariant.highlight,
        TrayIconVariant.normal,
      ]);
    });
  });

  group('tray menu', () {
    test('labels are single-line, bounded, and mark pinned clips', () {
      expect(
        trayLabelForClip(_clip('a', '  hello\n\n  world  ')),
        'hello world',
      );
      final long = trayLabelForClip(_clip('b', 'x' * 200));
      expect(long.characters.length, 48);
      expect(long, endsWith('…'));
      expect(trayLabelForClip(_clip('c', 'pin', pinned: true)), '★ pin');
      expect(trayLabelForClip(_clip('d', '   ')), 'Text');
    });

    test('model keeps at most ten recent clips and compares by value', () {
      final clips = List<ClipItem>.generate(14, (i) => _clip('c$i', 'v$i'));
      final model = DesktopTrayMenuModel.fromClips(
        clips,
        captureOn: true,
        captureAvailable: true,
      );
      expect(model.recentClips, hasLength(trayRecentClipLimit));
      expect(model.recentClips.first.id, 'c0');
      expect(
        model,
        DesktopTrayMenuModel.fromClips(
          clips,
          captureOn: true,
          captureAvailable: true,
        ),
      );
      expect(
        model ==
            DesktopTrayMenuModel.fromClips(
              clips,
              captureOn: false,
              captureAvailable: true,
            ),
        isFalse,
      );
    });

    test('menu exposes open/hide/quit, recent clips and capture toggle', () {
      final menu = buildTrayMenu(
        DesktopTrayMenuModel.fromClips(
          <ClipItem>[_clip('one', 'first'), _clip('two', 'second')],
          captureOn: true,
          captureAvailable: true,
        ),
        isMacOS: true,
      );
      final items = menu.items!;
      final keys = items.map((item) => item.key).whereType<String>().toList();
      expect(keys, <String>[
        openClipTownMenuKey,
        hideClipTownMenuKey,
        quitClipTownMenuKey,
        '${recentClipMenuKeyPrefix}one',
        '${recentClipMenuKeyPrefix}two',
        toggleCaptureMenuKey,
      ]);
      // macOS: plain titles; the runner attaches native key equivalents by
      // matching exactly these three titles in this order.
      expect(items.take(3).map((item) => item.label), <String>[
        openClipTownMenuTitle,
        hideClipTownMenuTitle,
        quitClipTownMenuTitle,
      ]);
      expect(
        items.firstWhere((item) => item.key == toggleCaptureMenuKey).label,
        'Pause capture',
      );
      expect(recentClipIdForMenuKey('${recentClipMenuKeyPrefix}two'), 'two');
      expect(recentClipIdForMenuKey(quitClipTownMenuKey), isNull);
    });

    test('capture toggle is disabled when the vault cannot capture', () {
      final menu = buildTrayMenu(const DesktopTrayMenuModel(), isMacOS: false);
      final toggle = menu.items!.firstWhere(
        (item) => item.key == toggleCaptureMenuKey,
      );
      expect(toggle.disabled, isTrue);
      expect(toggle.label, 'Resume capture');
      expect(menu.items!.first.label, 'Open ClipTown   Alt+C');
      expect(menu.items![1].label, 'Hide ClipTown   Alt+X');
      expect(menu.items![2].label, 'Quit ClipTown');
    });
  });

  group('launch at login', () {
    test('linux autostart entry quotes and escapes the executable', () {
      final entry = linuxAutostartEntry(r'/opt/Clip "Town"/$bin`x`\100%');
      expect(
        entry,
        contains(r'Exec="/opt/Clip \"Town\"/\$bin\`x\`\\100%%" --hidden'),
      );
      expect(entry, startsWith('[Desktop Entry]\n'));
    });

    test('linux login item writes and removes the autostart file', () async {
      final dir = await Directory.systemTemp.createTemp('cliptown-autostart');
      addTearDown(() => dir.delete(recursive: true));
      final login = LinuxLaunchAtLogin(
        autostartDirectory: '${dir.path}/autostart',
        executable: '/usr/bin/cliptown',
      );
      expect(await login.isEnabled(), isFalse);
      await login.setEnabled(true);
      expect(await login.isEnabled(), isTrue);
      expect(
        File('${dir.path}/autostart/cliptown.desktop').readAsStringSync(),
        contains('Exec="/usr/bin/cliptown" --hidden'),
      );
      await login.setEnabled(false);
      expect(await login.isEnabled(), isFalse);
      await login.setEnabled(false);
    });

    test('windows login item uses the HKCU Run key', () async {
      final calls = <List<String>>[];
      final login = WindowsLaunchAtLogin(
        executable: r'C:\Program Files\ClipTown\cliptown_app.exe',
        run: (executable, arguments) async {
          calls.add(<String>[executable, ...arguments]);
          return ProcessResult(0, arguments.first == 'query' ? 1 : 0, '', '');
        },
      );
      expect(await login.isEnabled(), isFalse);
      await login.setEnabled(true);
      expect(calls.last, containsAllInOrder(<String>['reg', 'add']));
      expect(
        calls.last,
        contains(r'"C:\Program Files\ClipTown\cliptown_app.exe" --hidden'),
      );
      await login.setEnabled(false);
      expect(calls.last, containsAllInOrder(<String>['reg', 'delete']));
    });

    test('the hidden flag marks a login-item launch', () async {
      expect(await launchedAtLogin(<String>['--hidden']), isTrue);
    });
  });

  group('formatting', () {
    final now = DateTime.utc(2026, 11, 13, 12);

    test('relative time', () {
      expect(relativeTimeLabel(now, now), 'just now');
      expect(
        relativeTimeLabel(now.add(const Duration(hours: 1)), now),
        'just now',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(minutes: 5)), now),
        '5m ago',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(hours: 3)), now),
        '3h ago',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(days: 2)), now),
        '2d ago',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(days: 40)), now),
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')),
      );
    });

    test('size', () {
      expect(clipSizeLabel(text: 'a', byteLength: 1), '1 char');
      expect(clipSizeLabel(text: 'ab\ncd', byteLength: 5), '5 chars • 2 lines');
      expect(clipSizeLabel(byteLength: 512), '512 B');
      expect(clipSizeLabel(byteLength: 2048), '2.0 KB');
      expect(clipSizeLabel(byteLength: 3 * 1024 * 1024), '3.0 MB');
    });

    test('hex colours', () {
      expect(parseHexColor('#ff0000')!.toARGB32(), 0xffff0000);
      expect(parseHexColor('#0f08')!.toARGB32(), 0x8800ff00);
      expect(parseHexColor(' #ABCDEF ')!.toARGB32(), 0xffabcdef);
      expect(parseHexColor('red'), isNull);
      expect(parseHexColor(null), isNull);
    });
  });

  group('tray menu click toggle', () {
    test(
      'a click opens the menu; clicks while it is open do not stack',
      () async {
        var popUps = 0;
        final closeMenu = Completer<void>();
        final toggle = TrayMenuToggle(() {
          popUps += 1;
          return closeMenu.future;
        });

        final opening = toggle.toggle();
        expect(toggle.isOpen, isTrue);
        expect(await toggle.toggle(), isFalse, reason: 'second click closes');
        closeMenu.complete();
        expect(await opening, isTrue);
        expect(popUps, 1);
        expect(toggle.isOpen, isFalse);
      },
    );

    test('the click that closed the menu does not reopen it', () async {
      var now = DateTime.utc(2026, 11, 14);
      var popUps = 0;
      final toggle = TrayMenuToggle(() async => popUps += 1, clock: () => now);

      expect(await toggle.toggle(), isTrue);
      now = now.add(const Duration(milliseconds: 120));
      expect(
        await toggle.toggle(),
        isFalse,
        reason: 'same click, delivered late',
      );
      now = now.add(const Duration(milliseconds: 400));
      expect(await toggle.toggle(), isTrue, reason: 'a new, later click');
      expect(popUps, 2);
    });

    test('a failing native pop-up leaves the toggle usable', () async {
      var now = DateTime.utc(2026, 11, 14);
      final toggle = TrayMenuToggle(
        () async => throw StateError('tray gone'),
        clock: () => now,
      );
      expect(await toggle.toggle(), isTrue);
      expect(toggle.isOpen, isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(await toggle.toggle(), isTrue);
    });
  });
}
