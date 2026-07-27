import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('search and pin flow works on a real device surface', (
    tester,
  ) async {
    await tester.pumpWidget(ClipTownApp(store: ClipStore()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('clip-search')), 'skyline');
    await tester.pumpAndSettle();
    expect(find.text('Skyline logo'), findsOneWidget);
    expect(find.text('Deploy command'), findsNothing);

    await tester.enterText(find.byKey(const Key('clip-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pin-design-reference')));
    await tester.tap(find.byKey(const Key('pinned-only')));
    await tester.pumpAndSettle();

    expect(find.text('Skyline logo'), findsOneWidget);
    expect(find.text('Security notes'), findsNothing);
  });
}
