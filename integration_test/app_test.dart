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
    expect(
      find.text('ClipTown cross-platform acceptance marker'),
      findsWidgets,
    );

    await tester.enterText(find.byKey(const Key('clip-search')), 'acceptance');
    await tester.pumpAndSettle();
    expect(
      find.text('ClipTown cross-platform acceptance marker'),
      findsWidgets,
    );

    final clipId = store.clips.single.id;
    await tester.tap(find.byKey(Key('pin-$clipId')));
    await tester.pumpAndSettle();
    expect(store.clips.single.pinned, isTrue);
  });
}
