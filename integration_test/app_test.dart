import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create, search, and pin flow works on an installed app', (
    tester,
  ) async {
    final store = ClipStore(repository: MemoryClipRepository());
    await store.initialize();
    await tester.pumpWidget(ClipTownApp(store: store));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('empty-history')), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-manual-clip')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('manual-clip-text')),
      'ClipTown cross-platform acceptance marker',
    );
    await tester.tap(find.byKey(const Key('save-manual-clip')));
    await tester.pumpAndSettle();

    expect(store.clips, hasLength(1));
    await tester.ensureVisible(
      find.text('ClipTown cross-platform acceptance marker').first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('ClipTown cross-platform acceptance marker'),
      findsWidgets,
    );

    final clipId = store.clips.single.id;
    await tester.enterText(find.byKey(const Key('clip-search')), 'acceptance');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(store.visibleClips.map((clip) => clip.id), <String>[clipId]);
    expect(find.byKey(const Key('clip-history-list')), findsOneWidget);

    final card = find.byKey(Key('clip-$clipId'));
    final historyScrollable = find.descendant(
      of: find.byKey(const Key('clip-history-scroll')),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    expect(historyScrollable, findsOneWidget);
    await tester.scrollUntilVisible(card, 200, scrollable: historyScrollable);
    await tester.pumpAndSettle();
    expect(card, findsOneWidget);
    expect(
      find.text('ClipTown cross-platform acceptance marker'),
      findsWidgets,
    );

    final pinButton = find.byKey(Key('pin-$clipId'));
    await tester.ensureVisible(pinButton);
    await tester.pumpAndSettle();
    await tester.tap(pinButton);
    await tester.pumpAndSettle();
    expect(store.clips.single.pinned, isTrue);
  });
}
