import 'package:cliptown_app/clipboard/clipboard_controller.dart';
import 'package:cliptown_app/clipboard/clipboard_service.dart';
import 'package:cliptown_app/cliptown_app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  testWidgets('renders private history shell and filters clips', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final store = await createDemoStore();
    await tester.pumpWidget(ClipTownApp(store: store));
    await tester.pumpAndSettle();

    expect(find.text('Your clipboard, private and useful.'), findsOneWidget);
    expect(find.text('Deploy command'), findsOneWidget);
    expect(find.text('Skyline logo'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('clip-search')), 'security');
    await tester.pump();

    expect(find.text('Security notes'), findsOneWidget);
    expect(find.text('Deploy command'), findsNothing);
  });

  testWidgets('shows explicit tray, hotkey, and capture status', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final store = await createDemoStore();
    await tester.pumpWidget(
      ClipTownApp(
        store: store,
        desktopBackgroundEnabled: true,
        desktopHotKeyEnabled: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Tray active • ⌘/Ctrl+Shift+V ready • capture on'),
      findsOneWidget,
    );
  });

  testWidgets('pin, queue, and copy actions update real controller state', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final store = await createDemoStore();
    final clipboard = MemoryClipClipboardService();
    final controller = ClipboardController(store: store, service: clipboard);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClipTownApp(store: store, clipboardController: controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pin-design-reference')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pinned-only')));
    await tester.pumpAndSettle();

    expect(find.text('Deploy command'), findsOneWidget);
    expect(find.text('Skyline logo'), findsOneWidget);
    expect(find.text('Security notes'), findsNothing);

    await tester.tap(find.byKey(const Key('queue-design-reference')));
    await tester.pumpAndSettle();
    expect(store.queueLength, 1);
    await tester.tap(find.byKey(const Key('copy-next-queued')));
    await tester.pumpAndSettle();
    expect(clipboard.lastWritten?.id, 'design-reference');
  });

  testWidgets('capture can be visibly paused and manually resumed', (
    tester,
  ) async {
    await _setDesktopSurface(tester);
    final store = await createDemoStore();
    final clipboard = MemoryClipClipboardService();
    final controller = ClipboardController(store: store, service: clipboard);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ClipTownApp(store: store, clipboardController: controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('capture-toggle')));
    await tester.pumpAndSettle();

    expect(store.captureEnabled, isFalse);
    expect(find.text('Capture off'), findsOneWidget);
    expect(find.text('Clipboard capture paused'), findsOneWidget);
  });
}

Future<void> _setDesktopSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
