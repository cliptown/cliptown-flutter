import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:cliptown_app/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders ClipTown shell and filters clips', (tester) async {
    await tester.pumpWidget(ClipTownApp(store: ClipStore()));

    expect(find.text('Your clipboard has a memory.'), findsOneWidget);
    expect(find.text('Deploy command'), findsOneWidget);
    expect(find.text('Skyline logo'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('clip-search')), 'security');
    await tester.pump();

    expect(find.text('Security notes'), findsOneWidget);
    expect(find.text('Deploy command'), findsNothing);
  });

  testWidgets('shows explicit background status when tray mode is active', (
    tester,
  ) async {
    await tester.pumpWidget(
      ClipTownApp(store: ClipStore(), desktopBackgroundEnabled: true),
    );

    expect(
      find.text('Tray active • close keeps ClipTown running'),
      findsOneWidget,
    );
    expect(
      find.text('Signed out • vault unavailable • sync disabled'),
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
      find.text('foreground • vault unlocked • sync idle'),
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
      find.text('background • vault locked • sync disabled'),
      findsOneWidget,
    );
  });

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

  testWidgets('pin button updates pinned-only results', (tester) async {
    final store = ClipStore();
    await tester.pumpWidget(ClipTownApp(store: store));

    await tester.tap(find.byKey(const Key('pin-design-reference')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pinned-only')));
    await tester.pump();

    expect(find.text('Deploy command'), findsOneWidget);
    expect(find.text('Skyline logo'), findsOneWidget);
    expect(find.text('Security notes'), findsNothing);
  });
}
