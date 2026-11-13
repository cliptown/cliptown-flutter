import 'dart:io';
import 'dart:math';

import 'package:cliptown_app/clipboard/clipboard_controller.dart';
import 'package:cliptown_app/clipboard/clipboard_service.dart';
import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/desktop/desktop_shell.dart';
import 'package:cliptown_app/desktop/launch_at_login.dart';
import 'package:cliptown_app/history/clip_content_preview.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

ClipItem _text(String id, String text, {DateTime? at, bool pinned = false}) {
  final when = at ?? demoFixtureBase;
  return ClipItem(
    id: id,
    kind: inferTextKind(text, hasHtml: false),
    title: id,
    text: text,
    createdAt: when,
    lastUsedAt: when,
    pinned: pinned,
  );
}

void main() {
  group('tray labels', () {
    test('strip control and bidi-override characters', () {
      final label = trayLabelForClip(
        _text('a', 'invoice\u202Efdp.exe\u0007\u2066x\u2069\u200F'),
      );
      expect(label, 'invoicefdp.exex');
      expect(
        label.runes.any((r) => r < 0x20 || (r >= 0x202A && r <= 0x202E)),
        isFalse,
      );
    });

    test('mask clips that look like secrets', () {
      const key = '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----';
      expect(trayLabelForClip(_text('k', key)), sensitiveTrayLabel);
      expect(
        trayLabelForClip(_text('k', key, pinned: true)),
        '★ $sensitiveTrayLabel',
      );
    });

    test('escape & only for Windows native menus', () {
      final model = DesktopTrayMenuModel.fromClips(
        <ClipItem>[_text('amp', 'Tom & Jerry')],
        captureOn: true,
        captureAvailable: true,
      );
      String label({required bool isWindows}) =>
          buildTrayMenu(model, isMacOS: false, isWindows: isWindows).items!
              .firstWhere((item) => item.key == '${recentClipMenuKeyPrefix}amp')
              .label!;
      expect(label(isWindows: true), 'Tom && Jerry');
      expect(label(isWindows: false), 'Tom & Jerry');
    });
  });

  group('preview truncation', () {
    test('never splits a surrogate pair', () {
      final text = '${'a' * (maxPreviewCharacters - 1)}😀tail';
      final cut = safePreviewCut(text, maxPreviewCharacters);
      expect(cut, maxPreviewCharacters - 1);
      final kept = text.substring(0, cut);
      final last = kept.codeUnitAt(kept.length - 1);
      expect(last >= 0xD800 && last <= 0xDBFF, isFalse);
      expect(safePreviewCut('short', 10), 5);
      expect(safePreviewCut('b' * 30, 20), 20);
    });
  });

  group('user-facing failures', () {
    test('only fixed messages are shown', () {
      expect(
        userFacingFailure(const ClipInputException('Titles must be short')),
        'Titles must be short',
      );
      expect(
        userFacingFailure(
          const FormatException('Unexpected character', '{"secret": hunter2'),
        ),
        'The operation failed without exposing clipboard data.',
      );
      expect(
        userFacingFailure(StateError('clip text: hunter2')),
        isNot(contains('hunter2')),
      );
      expect(
        userFacingFailure(PlatformException(code: 'requires_approval')),
        contains('Login Items'),
      );
    });
  });

  group('launch at login', () {
    test('windows: a Run value for another path reads as off', () async {
      var stored = r'"D:\old\cliptown_app.exe" --hidden';
      final login = WindowsLaunchAtLogin(
        executable: r'C:\Apps\ClipTown\cliptown_app.exe',
        run: (executable, arguments) async {
          if (arguments.first == 'add') {
            stored = arguments[arguments.indexOf('/d') + 1];
          }
          return ProcessResult(
            0,
            0,
            '    ClipTown    REG_SZ    $stored\r\n',
            '',
          );
        },
      );
      expect(await login.isEnabled(), isFalse);
      await login.setEnabled(true);
      expect(await login.isEnabled(), isTrue);
    });

    test('windows: a failed write is reported', () async {
      final login = WindowsLaunchAtLogin(
        executable: r'C:\x.exe',
        run: (_, _) async => ProcessResult(0, 1, '', 'Access is denied.'),
      );
      await expectLater(
        login.setEnabled(true),
        throwsA(isA<ProcessException>()),
      );
      await login.setEnabled(false);
    });

    test('linux: stale entries read as off and writes are atomic', () async {
      final dir = await Directory.systemTemp.createTemp('cliptown-autostart');
      addTearDown(() => dir.delete(recursive: true));
      final autostart = Directory('${dir.path}/autostart')..createSync();
      File(
        '${autostart.path}/cliptown.desktop',
      ).writeAsStringSync(linuxAutostartEntry('/old/cliptown_app'));
      final login = LinuxLaunchAtLogin(
        autostartDirectory: autostart.path,
        executable: '/opt/cliptown/cliptown_app',
      );
      expect(await login.isEnabled(), isFalse);
      await login.setEnabled(true);
      expect(await login.isEnabled(), isTrue);
      expect(
        autostart.listSync().map((entry) => entry.uri.pathSegments.last),
        <String>['cliptown.desktop'],
        reason: 'no staging file left behind',
      );
    });
  });

  group('store', () {
    test('mostRecent matches a full sort without copying history', () async {
      final random = Random(7);
      final items = List<ClipItem>.generate(
        300,
        (i) => _text(
          'c$i',
          'value $i',
          at: demoFixtureBase.subtract(Duration(minutes: random.nextInt(600))),
        ),
      );
      final store = ClipStore(
        repository: MemoryClipRepository(seed: items),
        clock: demoClock,
      );
      await store.initialize();
      final expected = store.clips.toList()
        ..sort((a, b) => b.sortTimestamp.compareTo(a.sortTimestamp));
      expect(
        store.mostRecent(10).map((clip) => clip.sortTimestamp),
        expected.take(10).map((clip) => clip.sortTimestamp),
      );
      expect(store.mostRecent(0), isEmpty);
      expect(store.findById('c42')?.text, 'value 42');
      expect(store.findById('missing'), isNull);
    });

    test('restore undoes a delete but never duplicates content', () async {
      final store = await createDemoStore();
      final clip = store.itemById('security-notes');
      await store.delete(clip.id);
      await store.restore(clip);
      expect(store.findById(clip.id)?.text, clip.text);

      await store.delete(clip.id);
      await store.addText(clip.text!);
      final before = store.clips.length;
      await store.restore(clip);
      expect(store.clips.length, before, reason: 'content was recaptured');
    });

    test(
      'editing into an existing clip is rejected with a safe message',
      () async {
        final store = await createDemoStore();
        await expectLater(
          store.editText(
            'security-notes',
            store.itemById('deploy-command').text!,
          ),
          throwsA(
            isA<ClipInputException>().having(
              (e) => e.message,
              'message',
              'An identical clip is already in your history',
            ),
          ),
        );
      },
    );

    test('validation errors are user-safe ClipInputExceptions', () async {
      final store = await createDemoStore();
      await expectLater(
        store.rename('deploy-command', ''),
        throwsA(isA<ClipInputException>()),
      );
      await expectLater(
        store.setTags('deploy-command', <String>{'x' * 81}),
        throwsA(isA<ClipInputException>()),
      );
      await expectLater(
        store.setHistoryLimit(0),
        throwsA(isA<ClipInputException>()),
      );
    });
  });

  group('save clipboard status', () {
    test('a pause/resume forgets what was observed before', () async {
      final store = ClipStore(repository: MemoryClipRepository());
      await store.initialize();
      final clipboard = MemoryClipClipboardService();
      final controller = ClipboardController(
        store: store,
        service: clipboard,
        automaticCaptureSupported: true,
      );
      addTearDown(controller.dispose);
      await controller.initialize();

      await clipboard.emit(ClipboardSnapshot.text(text: 'first'));
      expect(
        controller.saveStatus.availability,
        ClipboardSaveAvailability.alreadySaved,
      );

      await controller.setCaptureEnabled(false);
      expect(
        controller.saveStatus.availability,
        ClipboardSaveAvailability.paused,
      );
      await controller.setCaptureEnabled(true);
      expect(
        controller.saveStatus.availability,
        ClipboardSaveAvailability.available,
        reason: 'the clipboard may have changed while paused',
      );
    });
  });
}
