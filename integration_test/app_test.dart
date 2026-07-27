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
    final store = ClipStore();
    await tester.pumpWidget(ClipTownApp(store: store));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('clip-search')), 'skyline');
    await tester.pumpAndSettle();
    expect(find.text('Skyline logo'), findsOneWidget);
    expect(find.text('Deploy command'), findsNothing);

    final pin = find.byKey(const Key('pin-design-reference'));
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(
      store.visibleClips
          .singleWhere((clip) => clip.id == 'design-reference')
          .pinned,
      isTrue,
    );

    await tester.enterText(find.byKey(const Key('clip-search')), '');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pinned-only')));
    await tester.pumpAndSettle();

    final chip = tester.widget<FilterChip>(
      find.byKey(const Key('pinned-only')),
    );
    expect(chip.selected, isTrue);
    expect(
      store.visibleClips.map((clip) => clip.id),
      orderedEquals(<String>['deploy-command', 'design-reference']),
    );
    expect(find.text('Deploy command'), findsOneWidget);
    expect(find.text('Security notes'), findsNothing);
  });
}
