import 'package:cliptown_app/clipboard/clipboard_controller.dart';
import 'package:cliptown_app/clipboard/clipboard_service.dart';
import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:cliptown_app/state.dart';
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
    expect(
      find.text('Local mode • vault unlocked • capture ready • sync disabled'),
      findsOneWidget,
    );
  });

  testWidgets('formal app state is rendered from the transition authority', (
    tester,
  ) async {
    final stateMachine = AppStateMachine.initial(AppRuntimeKind.mobile);
    addTearDown(stateMachine.dispose);
    await tester.pumpWidget(
      ClipTownApp(store: ClipStore(), stateMachine: stateMachine),
    );

    expect(stateMachine.dispatch(AppEvent.bootAuthenticated).accepted, isTrue);
    expect(stateMachine.dispatch(AppEvent.unlockSucceeded).accepted, isTrue);
    await tester.pump();

    expect(
      find.text('foreground • vault unlocked • capture disabled • sync idle'),
      findsOneWidget,
    );
  });

  testWidgets('mobile OS background event locks the vault and disables sync', (
    tester,
  ) async {
    final stateMachine = AppStateMachine.initial(AppRuntimeKind.mobile);
    addTearDown(stateMachine.dispose);
    await tester.pumpWidget(
      ClipTownApp(store: ClipStore(), stateMachine: stateMachine),
    );

    expect(stateMachine.dispatch(AppEvent.bootAuthenticated).accepted, isTrue);
    expect(stateMachine.dispatch(AppEvent.unlockSucceeded).accepted, isTrue);
    expect(stateMachine.dispatch(AppEvent.networkConnected).accepted, isTrue);
    expect(stateMachine.dispatch(AppEvent.syncRequested).accepted, isTrue);
    expect(stateMachine.state.sync, AppSyncState.running);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(stateMachine.state.lifecycle, AppLifecyclePhase.background);
    expect(stateMachine.state.vault, AppVaultState.locked);
    expect(stateMachine.state.sync, AppSyncState.disabled);
    expect(stateMachine.state.invariantViolations(), isEmpty);
    expect(
      find.text('background • vault locked • capture disabled • sync disabled'),
      findsOneWidget,
    );
  });

  testWidgets(
    'locked foreground hides loaded history and disables local writes',
    (tester) async {
      final store = await createDemoStore();
      final stateMachine = AppStateMachine.localReady(
        AppRuntimeKind.mobile,
        captureRequested: true,
      );
      final controller = ClipboardController(
        store: store,
        service: MemoryClipClipboardService(),
        stateMachine: stateMachine,
      );
      addTearDown(stateMachine.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ClipTownApp(
          store: store,
          stateMachine: stateMachine,
          clipboardController: controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Deploy command'), findsOneWidget);

      expect(
        stateMachine.dispatch(AppEvent.backgroundRequested).accepted,
        isTrue,
      );
      expect(
        stateMachine.dispatch(AppEvent.foregroundRequested).accepted,
        isTrue,
      );
      await tester.pumpAndSettle();

      expect(stateMachine.state.lifecycle, AppLifecyclePhase.foreground);
      expect(stateMachine.state.vault, AppVaultState.locked);
      expect(find.text('Deploy command'), findsNothing);
      expect(
        find.text(
          'Encrypted history is locked. ClipTown refuses to capture or fall back to plaintext.',
        ),
        findsOneWidget,
      );
      final addButton = tester.widget<FloatingActionButton>(
        find.byKey(const Key('add-manual-clip')),
      );
      expect(addButton.onPressed, isNull);
    },
  );

  testWidgets('desktop Flutter lifecycle does not bypass tray authority', (
    tester,
  ) async {
    final stateMachine = AppStateMachine.signedOut(AppRuntimeKind.desktop);
    addTearDown(stateMachine.dispose);
    await tester.pumpWidget(
      ClipTownApp(store: ClipStore(), stateMachine: stateMachine),
    );
    final before = stateMachine.state;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(stateMachine.state, same(before));
    expect(stateMachine.state.invariantViolations(), isEmpty);
  });

  testWidgets('split clipboard and app transition authorities are rejected', (
    tester,
  ) async {
    final store = await createDemoStore();
    final appMachine = AppStateMachine.localReady(
      AppRuntimeKind.mobile,
      captureRequested: true,
    );
    final controller = ClipboardController(
      store: store,
      service: MemoryClipClipboardService(),
    );
    addTearDown(appMachine.dispose);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ClipTownApp(
        store: store,
        stateMachine: appMachine,
        clipboardController: controller,
      ),
    );

    expect(tester.takeException(), isA<StateError>());
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

  testWidgets('compact mobile viewport scrolls without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(402, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await createDemoStore();

    await tester.pumpWidget(ClipTownApp(store: store));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('clip-history-scroll')), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('clip-history-scroll')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(find.text('Deploy command'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _setDesktopSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}
