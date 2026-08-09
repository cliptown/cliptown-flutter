import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/src/clip_store.dart';
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
