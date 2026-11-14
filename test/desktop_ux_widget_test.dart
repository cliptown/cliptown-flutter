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
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

class _FakeShell implements DesktopShell {
  final ValueNotifier<int> _summons = ValueNotifier<int>(0);
  int dismissals = 0;
  DesktopTrayMenuModel? lastMenu;
  DesktopTrayHandlers? handlers;

  @override
  ValueListenable<int> get summonCount => _summons;

  void summon() => _summons.value += 1;

  @override
  Future<void> dismiss() async => dismissals += 1;

  @override
  void setTrayHandlers(DesktopTrayHandlers handlers) =>
      this.handlers = handlers;

  @override
  void updateTrayMenu(DesktopTrayMenuModel model) => lastMenu = model;

  @override
  LaunchAtLogin? launchAtLogin;
}

class _FakeLaunchAtLogin implements LaunchAtLogin {
  _FakeLaunchAtLogin({this.failWith});

  final Object? failWith;
  bool enabled = false;
  final List<bool> requests = <bool>[];

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    requests.add(value);
    if (failWith case final error?) throw error;
    enabled = value;
  }
}

class _Harness {
  _Harness(this.store, this.clipboard, this.controller, this.shell);

  final ClipStore store;
  final MemoryClipClipboardService clipboard;
  final ClipboardController controller;
  final _FakeShell shell;
}

Future<_Harness> _pump(
  WidgetTester tester, {
  ClipStore? store,
  bool automaticCapture = false,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final resolvedStore = store ?? await createDemoStore();
  final clipboard = MemoryClipClipboardService();
  final controller = ClipboardController(
    store: resolvedStore,
    service: clipboard,
    automaticCaptureSupported: automaticCapture,
  );
  addTearDown(controller.dispose);
  final shell = _FakeShell();
  await tester.pumpWidget(
    ClipTownApp(
      store: resolvedStore,
      clipboardController: controller,
      desktopShell: shell,
      desktopBackgroundEnabled: true,
      desktopHotKeyEnabled: true,
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(resolvedStore, clipboard, controller, shell);
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  LogicalKeyboardKey? modifier,
}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('status line advertises Alt+C / Alt+X instead of Shift+V', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      find.text(
        'Tray active • Alt+C opens • Alt+O tray • Alt+X hides • capture on',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Shift+V'), findsNothing);
  });

  OutlinedButton saveButton(WidgetTester tester) =>
      tester.widget<OutlinedButton>(
        find
                .descendant(
                  of: find.byKey(const Key('capture-now')),
                  matching: find.byType(OutlinedButton),
                )
                .evaluate()
                .isEmpty
            ? find.byKey(const Key('capture-now'))
            : find.descendant(
                of: find.byKey(const Key('capture-now')),
                matching: find.byType(OutlinedButton),
              ),
      );

  String saveTooltip(WidgetTester tester) => tester
      .widget<Tooltip>(find.byKey(const Key('capture-now-tooltip')))
      .message!;

  testWidgets('save button stays visible and greys out once the clipboard is '
      'saved', (tester) async {
    final h = await _pump(tester, automaticCapture: true);
    expect(h.controller.monitoring, isTrue);
    expect(find.byKey(const Key('capture-now')), findsOneWidget);
    expect(saveButton(tester).onPressed, isNotNull);
    expect(saveTooltip(tester), contains('saved automatically'));

    await h.clipboard.emit(ClipboardSnapshot.text(text: 'fresh copy'));
    await tester.pumpAndSettle();
    expect(saveButton(tester).onPressed, isNull, reason: 'already saved');
    expect(saveTooltip(tester), startsWith('Already saved'));

    final savedId = h.store.clips
        .firstWhere((clip) => clip.text == 'fresh copy')
        .id;
    await h.store.delete(savedId);
    await tester.pumpAndSettle();
    expect(
      saveButton(tester).onPressed,
      isNotNull,
      reason: 'the saved clip was deleted, so saving again adds it back',
    );
  });

  testWidgets('save button explains policy rejections and paused capture', (
    tester,
  ) async {
    final h = await _pump(tester, automaticCapture: true);
    await h.clipboard.emit(
      ClipboardSnapshot.text(
        text: '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
      ),
    );
    await tester.pumpAndSettle();
    expect(saveButton(tester).onPressed, isNull);
    expect(saveTooltip(tester), contains('looks like a password'));

    await tester.tap(find.byKey(const Key('capture-toggle')));
    await tester.pumpAndSettle();
    expect(saveButton(tester).onPressed, isNull);
    expect(saveTooltip(tester), startsWith('Capture is paused'));
  });

  testWidgets('holding Alt/Option makes tooltips appear immediately', (
    tester,
  ) async {
    await _pump(tester);
    Duration? wait() => TooltipTheme.of(
      tester.element(find.byKey(const Key('clip-search'))),
    ).waitDuration;

    expect(wait(), const Duration(milliseconds: 700));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(wait(), Duration.zero);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(wait(), const Duration(milliseconds: 700));
  });

  testWidgets('every control on a clip row explains itself', (tester) async {
    await _pump(tester);
    for (final message in <String>[
      'Detected content type. Filter by type above.',
      'Size of this clip',
      'Press Ctrl+1 to copy this clip and hide ClipTown',
    ]) {
      expect(find.byTooltip(message), findsWidgets, reason: message);
    }
    expect(find.byTooltip(RegExp(r'^Last copied ')), findsWidgets);
  });

  testWidgets('capture switch and save button sit in their own bar above '
      'search, apart from the filters', (tester) async {
    await _pump(tester);
    final bar = find.byKey(const Key('capture-bar'));
    final searchTop = tester.getRect(find.byKey(const Key('clip-search'))).top;
    for (final key in <String>['capture-now', 'capture-toggle']) {
      final control = find.byKey(Key(key));
      expect(find.descendant(of: bar, matching: control), findsOneWidget);
      expect(tester.getRect(control).bottom, lessThan(searchTop), reason: key);
    }
    expect(
      tester.getRect(find.byKey(const Key('pinned-only'))).top,
      greaterThan(searchTop),
      reason: 'filters stay below search',
    );
  });

  testWidgets('arrow keys select and Return copies, then hides to tray', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.enter);

    expect(h.clipboard.lastWritten?.id, 'design-reference');
    expect(h.shell.dismissals, 1);
  });

  testWidgets('Ctrl+number copies that row directly', (tester) async {
    final h = await _pump(tester);
    await _press(
      tester,
      LogicalKeyboardKey.digit3,
      modifier: LogicalKeyboardKey.controlLeft,
    );
    expect(h.clipboard.lastWritten?.id, 'security-notes');
    expect(h.shell.dismissals, 1);
  });

  testWidgets('Escape clears the search first, then hides', (tester) async {
    final h = await _pump(tester);
    await tester.enterText(find.byKey(const Key('clip-search')), 'kubectl');
    await tester.pumpAndSettle();
    expect(h.store.query, 'kubectl');

    await _press(tester, LogicalKeyboardKey.escape);
    expect(h.store.query, isEmpty);
    expect(h.shell.dismissals, 0);

    await _press(tester, LogicalKeyboardKey.escape);
    expect(h.shell.dismissals, 1);
  });

  testWidgets('Alt+X hides ClipTown to the tray', (tester) async {
    final h = await _pump(tester);
    await _press(
      tester,
      LogicalKeyboardKey.keyX,
      modifier: LogicalKeyboardKey.altLeft,
    );
    expect(h.shell.dismissals, 1);
  });

  testWidgets('summoning focuses search and resets the selection', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    h.shell.summon();
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('clip-search')),
    );
    expect(field.focusNode!.hasFocus, isTrue);

    await _press(tester, LogicalKeyboardKey.enter);
    expect(h.clipboard.lastWritten?.id, 'deploy-command');
  });

  testWidgets('tray menu mirrors recent clips and drives copy and capture', (
    tester,
  ) async {
    final h = await _pump(tester);
    final menu = h.shell.lastMenu!;
    expect(menu.recentClips.map((entry) => entry.id), <String>[
      'deploy-command',
      'design-reference',
      'security-notes',
    ]);
    expect(menu.captureOn, isTrue);

    h.shell.handlers!.onRecentClipSelected('security-notes');
    await tester.pumpAndSettle();
    expect(h.clipboard.lastWritten?.id, 'security-notes');
    expect(h.shell.lastMenu!.recentClips.first.id, 'security-notes');

    h.shell.handlers!.onToggleCapture();
    await tester.pumpAndSettle();
    expect(h.shell.lastMenu!.captureOn, isFalse);
  });

  testWidgets('short clips render as plain text without scroll affordance', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byKey(const Key('clip-preview-collapsed')), findsNothing);
    expect(find.byType(ClipContentPreview), findsNWidgets(3));
  });

  testWidgets('text clips can be edited and colour clips show a swatch', (
    tester,
  ) async {
    final store = ClipStore(
      repository: MemoryClipRepository(
        seed: <ClipItem>[
          ClipItem(
            id: 'brand',
            kind: ClipKind.color,
            title: '#ff2e97',
            text: '#ff2e97',
            createdAt: demoFixtureBase,
            lastUsedAt: demoFixtureBase,
          ),
        ],
      ),
      clock: demoClock,
    );
    await store.initialize();
    await _pump(tester, store: store);
    expect(find.byKey(const Key('color-swatch-brand')), findsOneWidget);

    await tester.tap(find.byKey(const Key('actions-brand')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit text'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('edit-clip-text')), 'hello');
    await tester.tap(find.byKey(const Key('save-edited-clip')));
    await tester.pumpAndSettle();

    final edited = store.itemById('brand');
    expect(edited.text, 'hello');
    expect(edited.kind, ClipKind.text);
    expect(edited.title, 'hello');
    expect(find.byKey(const Key('color-swatch-brand')), findsNothing);
  });

  testWidgets('Return activates a focused button instead of copying', (
    tester,
  ) async {
    final h = await _pump(tester);
    final pinIcon = find.descendant(
      of: find.byKey(const Key('pin-design-reference')),
      matching: find.byType(Icon),
    );
    Focus.of(tester.element(pinIcon)).requestFocus();
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.enter);
    expect(h.store.itemById('design-reference').pinned, isTrue);
    expect(h.clipboard.lastWritten, isNull);
    expect(h.shell.dismissals, 0);
  });

  testWidgets('Alt+Backspace edits search text; on empty search it deletes '
      'with undo', (tester) async {
    final h = await _pump(tester);
    final search = find.byKey(const Key('clip-search'));
    await tester.tap(search);
    await tester.enterText(search, 'deploy');
    await tester.pumpAndSettle();
    final before = h.store.clips.length;

    await _press(
      tester,
      LogicalKeyboardKey.backspace,
      modifier: LogicalKeyboardKey.altLeft,
    );
    expect(h.store.clips.length, before, reason: 'word delete, not clip');

    await tester.enterText(search, '');
    await tester.pumpAndSettle();
    await _press(
      tester,
      LogicalKeyboardKey.backspace,
      modifier: LogicalKeyboardKey.altLeft,
    );
    expect(h.store.clips.length, before - 1);
    expect(h.store.findById('deploy-command'), isNull);
    expect(find.byKey(const Key('clip-deleted-snackbar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('undo-delete')));
    await tester.pumpAndSettle();
    expect(h.store.findById('deploy-command'), isNotNull);
    expect(h.store.clips.length, before);
  });

  testWidgets('menu delete is undoable too', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const Key('actions-security-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(h.store.findById('security-notes'), isNull);
    await tester.tap(find.byKey(const Key('undo-delete')));
    await tester.pumpAndSettle();
    expect(h.store.findById('security-notes'), isNotNull);
  });

  testWidgets('validation failures show their reason, not a generic error', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('actions-security-notes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit text'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('edit-clip-text')),
      'kubectl rollout status deployment/cliptown-api',
    );
    await tester.tap(find.byKey(const Key('save-edited-clip')));
    await tester.pumpAndSettle();
    expect(
      find.text('An identical clip is already in your history'),
      findsOneWidget,
    );
  });

  testWidgets('tray never receives the text of a likely secret', (
    tester,
  ) async {
    final store = ClipStore(
      repository: MemoryClipRepository(
        seed: <ClipItem>[
          ClipItem(
            id: 'secret',
            kind: ClipKind.text,
            title: 'secret',
            text: '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----',
            createdAt: demoFixtureBase,
            lastUsedAt: demoFixtureBase,
          ),
        ],
      ),
      clock: demoClock,
    );
    await store.initialize();
    final h = await _pump(tester, store: store);
    final labels = h.shell.lastMenu!.recentClips.map((e) => e.label);
    expect(labels, <String>[sensitiveTrayLabel]);
    expect(labels.join(), isNot(contains('PRIVATE KEY')));
  });

  testWidgets('status line says when the summon shortcut is unavailable', (
    tester,
  ) async {
    final store = await createDemoStore();
    await tester.pumpWidget(
      ClipTownApp(store: store, desktopBackgroundEnabled: true),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Alt+C shortcut unavailable'), findsOneWidget);
  });

  Future<void> toggleOpenAtLogin(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('privacy-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-at-login-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-at-login-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('settings turn on open-at-login through the shell', (
    tester,
  ) async {
    final h = await _pump(tester);
    final login = _FakeLaunchAtLogin();
    h.shell.launchAtLogin = login;
    await toggleOpenAtLogin(tester);
    expect(login.requests, <bool>[true]);
    expect(login.enabled, isTrue);
    expect(find.byKey(const Key('operation-failed-snackbar')), findsNothing);
  });

  testWidgets('macOS approval requirement is explained, not a generic error', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.shell.launchAtLogin = _FakeLaunchAtLogin(
      failWith: PlatformException(code: 'requires_approval'),
    );
    await toggleOpenAtLogin(tester);
    expect(find.textContaining('Login Items'), findsOneWidget);
  });

  testWidgets('settings hide open-at-login where it is unsupported', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('privacy-settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('open-at-login-toggle')), findsNothing);
  });

  testWidgets('app bar shows the ClipTown logo beside the name', (
    tester,
  ) async {
    await _pump(tester);
    final logo = find.byKey(const Key('app-logo'));
    expect(logo, findsOneWidget);
    expect(
      find.ancestor(of: logo, matching: find.byType(AppBar)),
      findsOneWidget,
    );
    expect(
      tester.getCenter(logo).dx,
      lessThan(tester.getCenter(find.text('ClipTown')).dx),
      reason: 'logo sits to the left of the name',
    );
    expect(tester.widget<Image>(logo).semanticLabel, 'ClipTown logo');
  });

  Finder rowCard(String id) => find.ancestor(
    of: find.byKey(Key('clip-$id')),
    matching: find.byType(Card),
  );

  testWidgets('clicking a row makes it 15% taller; clicking elsewhere shrinks '
      'it back', (tester) async {
    await _pump(tester);
    final before = tester.getSize(rowCard('security-notes')).height;

    await tester.tap(find.text('Security notes'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(rowCard('security-notes')).height,
      closeTo(before * 1.15, 1),
    );

    await tester.tap(find.byKey(const Key('clip-search')));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(rowCard('security-notes')).height,
      closeTo(before, 0.5),
    );
  });

  testWidgets('clicking another row moves the expansion to it', (tester) async {
    await _pump(tester);
    final deployBefore = tester.getSize(rowCard('deploy-command')).height;
    final notesBefore = tester.getSize(rowCard('security-notes')).height;

    await tester.tap(find.text('Deploy command'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Security notes'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(rowCard('deploy-command')).height,
      closeTo(deployBefore, 0.5),
    );
    expect(
      tester.getSize(rowCard('security-notes')).height,
      closeTo(notesBefore * 1.15, 1),
    );
  });

  testWidgets('Escape shrinks an expanded row before anything else', (
    tester,
  ) async {
    final h = await _pump(tester);
    final before = tester.getSize(rowCard('security-notes')).height;
    await tester.tap(find.text('Security notes'));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.escape);
    expect(
      tester.getSize(rowCard('security-notes')).height,
      closeTo(before, 0.5),
    );
    expect(h.shell.dismissals, 0);
  });

  testWidgets(
    'a long clip scrolls inside its expanded row; the scrollbar shows '
    'only while hovered',
    (tester) async {
      final store = ClipStore(
        repository: MemoryClipRepository(
          seed: <ClipItem>[
            ClipItem(
              id: 'long',
              kind: ClipKind.text,
              title: 'Long note',
              text: List<String>.generate(40, (i) => 'line $i').join('\n'),
              createdAt: demoFixtureBase,
              lastUsedAt: demoFixtureBase,
            ),
          ],
        ),
        clock: demoClock,
      );
      await store.initialize();
      await _pump(tester, store: store);
      expect(find.byKey(const Key('clip-preview-collapsed')), findsOneWidget);
      final collapsedRow = tester.getSize(rowCard('long')).height;

      await tester.tap(find.text('Long note'));
      await tester.pumpAndSettle();
      final expanded = find.byKey(const Key('clip-preview-expanded'));
      expect(expanded, findsOneWidget);
      expect(
        tester.getSize(rowCard('long')).height,
        closeTo(collapsedRow * 1.25, 1),
      );
      bool thumbShown() => tester
          .widget<Scrollbar>(find.byKey(const Key('clip-preview-scrollbar')))
          .thumbVisibility!;
      expect(thumbShown(), isFalse, reason: 'not hovered yet');
      // The scroll area spans the row, so the scrollbar is at the right edge
      // even though every line ("line N") is short.
      expect(
        tester.getRect(expanded).right,
        closeTo(tester.getRect(find.byKey(const Key('clip-long'))).right, 0.5),
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: tester.getCenter(expanded));
      await tester.pumpAndSettle();
      expect(thumbShown(), isTrue);

      await tester.drag(expanded, const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: expanded, matching: find.byType(Scrollable)),
      );
      expect(scrollable.position.pixels, greaterThan(0));

      await mouse.moveTo(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(thumbShown(), isFalse, reason: 'hidden once the cursor leaves');
      expect(expanded, findsOneWidget, reason: 'still expanded until a click');

      await tester.tap(find.byKey(const Key('clip-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('clip-preview-collapsed')), findsOneWidget);
      expect(
        tester.getSize(rowCard('long')).height,
        closeTo(collapsedRow, 0.5),
      );
    },
  );

  testWidgets('search stays pinned: refocusing it never scrolls the list back '
      'to the top', (tester) async {
    final store = ClipStore(
      repository: MemoryClipRepository(
        seed: List<ClipItem>.generate(
          20,
          (i) => ClipItem(
            id: 'c$i',
            kind: ClipKind.text,
            title: 'Clip $i',
            text: 'value $i',
            createdAt: demoFixtureBase.subtract(Duration(minutes: i)),
            lastUsedAt: demoFixtureBase.subtract(Duration(minutes: i)),
          ),
        ),
      ),
      clock: demoClock,
    );
    await store.initialize();
    await _pump(tester, store: store);
    final list = find.byKey(const Key('clip-history-scroll'));
    await tester.drag(list, const Offset(0, -700));
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    final scrolled = position.pixels;
    expect(scrolled, greaterThan(0));

    final search = find.byKey(const Key('clip-search'));
    expect(search, findsOneWidget, reason: 'still mounted while scrolled');
    final node = tester.widget<TextField>(search).focusNode!;
    node.unfocus();
    await tester.pump();
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(position.pixels, scrolled);

    // Click a row that is fully inside the visible list area.
    final listRect = tester.getRect(list);
    final row = find
        .byWidgetPredicate(
          (widget) =>
              widget is Text && (widget.data?.startsWith('Clip ') ?? false),
        )
        .evaluate()
        .map((element) => find.text((element.widget as Text).data!))
        .firstWhere((finder) {
          final rect = tester.getRect(finder);
          return rect.top > listRect.top + 20 &&
              rect.bottom < listRect.bottom - 20;
        });
    final rowTop = tester.getTopLeft(row).dy;
    await tester.tap(row, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(position.pixels, scrolled);
    expect(tester.getTopLeft(row).dy, rowTop);
  });

  testWidgets('status messages are 4-second toasts with a close button', (
    tester,
  ) async {
    final h = await _pump(tester);
    await h.store.addText('kubectl rollout status deployment/cliptown-api');
    await tester.pump();
    await tester.pump();
    final toast = find.byKey(const Key('status-toast'));
    expect(toast, findsOneWidget);
    expect(
      find.descendant(
        of: toast,
        matching: find.text('Existing item moved to the top'),
      ),
      findsOneWidget,
    );
    expect(tester.widget<SnackBar>(toast).showCloseIcon, isTrue);
    expect(tester.widget<SnackBar>(toast).duration, const Duration(seconds: 4));
    expect(h.store.statusMessage, isNull, reason: 'moved out of the banner');
    expect(
      find.descendant(
        of: find.byKey(const Key('capture-status-message')),
        matching: find.text('Existing item moved to the top'),
      ),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 400)); // entrance animation
    await tester.tap(
      find.descendant(of: toast, matching: find.byIcon(Icons.close)),
    );
    await tester.pumpAndSettle();
    expect(toast, findsNothing);

    await h.store.addText('another');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('status-toast')), findsOneWidget);
    // The 4 s countdown starts once the toast has finished sliding in.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(seconds: 3));
    expect(find.byKey(const Key('status-toast')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('status-toast')), findsNothing);
  });

  testWidgets('pinned clips are marked in pink', (tester) async {
    await _pump(tester);
    final chip = find.byKey(const Key('pinned-chip'));
    expect(chip, findsOneWidget, reason: 'deploy-command is pinned');
    final pinIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('pin-deploy-command')),
        matching: find.byType(Icon),
      ),
    );
    expect(pinIcon.icon, Icons.push_pin);
    expect(pinIcon.color, pinnedAccent);
    final unpinned = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const Key('pin-security-notes')),
        matching: find.byType(Icon),
      ),
    );
    expect(unpinned.color, isNot(pinnedAccent));
  });

  testWidgets('New clip offers clipboard, image and files, and works while '
      'capture is paused', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(const Key('capture-toggle')));
    await tester.pumpAndSettle();
    expect(h.controller.captureRequested, isFalse);

    await tester.tap(find.byKey(const Key('add-manual-clip')));
    await tester.pumpAndSettle();
    for (final key in <String>[
      'new-clip-from-clipboard',
      'new-clip-image',
      'new-clip-files',
      'manual-clip-text',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    await tester.enterText(find.byKey(const Key('manual-clip-text')), 'typed');
    await tester.tap(find.byKey(const Key('save-manual-clip')));
    await tester.pumpAndSettle();
    expect(h.store.clips.any((clip) => clip.text == 'typed'), isTrue);

    h.clipboard.current = ClipboardSnapshot.files(
      fileUris: const <String>['file:///tmp/report.pdf'],
    );
    await tester.tap(find.byKey(const Key('add-manual-clip')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-clip-from-clipboard')));
    await tester.pumpAndSettle();
    expect(
      h.store.clips.where((clip) => clip.kind == ClipKind.files),
      hasLength(1),
    );
  });
}
