import 'package:cliptown_app/clipboard/clipboard_controller.dart';
import 'package:cliptown_app/clipboard/clipboard_service.dart';
import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/desktop/desktop_shell.dart';
import 'package:cliptown_app/desktop/launch_at_login.dart';
import 'package:cliptown_app/history/clip_content_preview.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
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
  LaunchAtLogin? get launchAtLogin => null;
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
      find.text('Tray active • Alt+C opens • Alt+X hides • capture on'),
      findsOneWidget,
    );
    expect(find.textContaining('Shift+V'), findsNothing);
  });

  testWidgets('manual save is hidden while capture is automatic', (
    tester,
  ) async {
    final h = await _pump(tester, automaticCapture: true);
    expect(h.controller.monitoring, isTrue);
    expect(find.byKey(const Key('capture-now')), findsNothing);
    expect(find.text('Capture now'), findsNothing);
  });

  testWidgets('manual save sits with capture controls, not search', (
    tester,
  ) async {
    await _pump(tester);
    final button = find.byKey(const Key('capture-now'));
    expect(button, findsOneWidget);
    expect(find.text('Save clipboard now'), findsOneWidget);
    final searchBox = tester.getRect(find.byKey(const Key('clip-search')));
    expect(
      tester.getRect(button).top,
      greaterThan(searchBox.bottom),
      reason: 'not on the search row',
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

  testWidgets('tall clips scroll on click and collapse when the mouse leaves', (
    tester,
  ) async {
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

    final collapsed = find.byKey(const Key('clip-preview-collapsed'));
    expect(collapsed, findsOneWidget);
    expect(find.byKey(const Key('clip-preview-scrollbar')), findsNothing);
    final rowHeight = tester.getSize(collapsed).height;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(collapsed));
    await mouse.down(tester.getCenter(collapsed));
    await mouse.up();
    await tester.pumpAndSettle();

    final expanded = find.byKey(const Key('clip-preview-expanded'));
    expect(expanded, findsOneWidget);
    expect(find.byKey(const Key('clip-preview-scrollbar')), findsOneWidget);
    expect(tester.getSize(expanded).height, closeTo(rowHeight, 0.5));
    expect(find.text('line 39', findRichText: true), findsNothing);

    await tester.drag(expanded, const Offset(0, -400));
    await tester.pumpAndSettle();

    await mouse.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('clip-preview-scrollbar')), findsNothing);
    expect(find.byKey(const Key('clip-preview-collapsed')), findsOneWidget);
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
}
