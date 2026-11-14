import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:cliptown_app/history/text_dedupe.dart';
import 'package:cliptown_app/history/text_dedupe_worker.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

final DateTime _t0 = demoFixtureBase;

ClipItem _text(
  String id,
  String text, {
  int minutesAgo = 0,
  bool pinned = false,
  Set<String> tags = const <String>{},
  String? collection,
}) {
  final at = _t0.subtract(Duration(minutes: minutesAgo));
  return ClipItem(
    id: id,
    kind: inferTextKind(text, hasHtml: false),
    title: id,
    text: text,
    createdAt: at,
    lastUsedAt: at,
    pinned: pinned,
    tags: tags,
    collection: collection,
  );
}

ClipItem _image(String id, {int minutesAgo = 0}) {
  final at = _t0.subtract(Duration(minutes: minutesAgo));
  return ClipItem(
    id: id,
    kind: ClipKind.image,
    title: id,
    dataBase64: base64Encode(<int>[1, 2, 3]),
    mimeType: 'image/png',
    createdAt: at,
    lastUsedAt: at,
  );
}

Future<ClipStore> _store(List<ClipItem> seed) async {
  final store = ClipStore(
    repository: MemoryClipRepository(seed: seed),
    clock: demoClock,
  );
  await store.initialize();
  return store;
}

void main() {
  group('rules', () {
    test('only text is keyed, verbatim', () {
      expect(textDedupeKey(ClipKind.text, ' a\n'), ' a\n');
      expect(textDedupeKey(ClipKind.code, 'x'), 'x');
      expect(textDedupeKey(ClipKind.image, null), isNull);
      expect(textDedupeKey(ClipKind.files, 'file:///a'), isNull);
    });

    test('consecutive snapshots: same text is the same copy, whatever the '
        'HTML; whitespace differences are not', () {
      final plain = ClipboardSnapshot.text(text: 'hello');
      final rich = ClipboardSnapshot.text(text: 'hello', html: '<b>hello</b>');
      expect(sameClipboardContent(plain, rich), isTrue);
      expect(
        sameClipboardContent(plain, ClipboardSnapshot.text(text: 'hello ')),
        isFalse,
      );
      expect(
        sameClipboardContent(plain, ClipboardSnapshot.text(text: 'Hello')),
        isFalse,
      );
      final png = ClipboardSnapshot.image(
        data: Uint8List.fromList(<int>[1, 2]),
        mimeType: 'image/png',
      );
      expect(sameClipboardContent(png, png), isTrue);
      expect(sameClipboardContent(png, plain), isFalse);
    });

    test('plan keeps the youngest and folds older metadata into it', () {
      final plan = planTextDedupe(<ClipItem>[
        _text('old', 'same', minutesAgo: 30, pinned: true, tags: {'a'}),
        _text('mid', 'same', minutesAgo: 10, collection: 'work'),
        _text('new', 'same', tags: {'b'}),
        _text('spaced', 'same ', minutesAgo: 5),
        _image('img1'),
        _image('img2', minutesAgo: 1),
      ]);
      expect(plan.removedIds, <String>{'old', 'mid'});
      final keeper = plan.keepers['new']!;
      expect(keeper.pinned, isTrue);
      expect(keeper.tags, <String>{'a', 'b'});
      expect(keeper.collection, 'work');
      expect(plan.keepers.containsKey('spaced'), isFalse);
      expect(plan.removedIds.any((id) => id.startsWith('img')), isFalse);
    });

    test('merged tags stay within the per-clip limit', () {
      final older = List<ClipItem>.generate(
        3,
        (i) => _text(
          'o$i',
          'same',
          minutesAgo: i + 1,
          tags: {for (var t = 0; t < 20; t += 1) 'o$i-$t'},
        ),
      );
      final plan = planTextDedupe(<ClipItem>[_text('k', 'same'), ...older]);
      expect(plan.keepers['k']!.tags.length, maxClipTags);
      plan.keepers['k']!.validate();
    });
  });

  group('capture', () {
    test('a verbatim repeat replaces all older copies and keeps their '
        'metadata', () async {
      final store = await _store(<ClipItem>[
        _text('a1', 'deploy', minutesAgo: 20, pinned: true),
        _text('a2', 'deploy', minutesAgo: 10, tags: {'ops'}),
        _text('b', 'other', minutesAgo: 5),
      ]);
      final result = await store.capture(
        ClipboardSnapshot.text(text: 'deploy', html: '<p>deploy</p>'),
      );
      expect(result.refreshedExisting, isTrue);
      final copies = store.clips.where((clip) => clip.text == 'deploy');
      expect(copies, hasLength(1));
      final kept = copies.single;
      expect(kept.html, '<p>deploy</p>', reason: 'the younger copy wins');
      expect(kept.pinned, isTrue);
      expect(kept.tags, <String>{'ops'});
      expect(store.visibleClips.first.id, kept.id);
    });

    test('whitespace differences are separate clips', () async {
      final store = await _store(const <ClipItem>[]);
      await store.addText('x');
      await store.addText('x ');
      await store.addText('\tx');
      expect(store.clips, hasLength(3));
    });

    test('identical images are not merged by the text rule', () async {
      final store = await _store(const <ClipItem>[]);
      final png = Uint8List.fromList(<int>[9, 9, 9]);
      await store.capture(
        ClipboardSnapshot.image(data: png, mimeType: 'image/png'),
      );
      await store.addText('caption');
      await store.capture(
        ClipboardSnapshot.image(data: png, mimeType: 'image/png'),
      );
      expect(store.clips.where((c) => c.kind == ClipKind.image), hasLength(1));
      expect(store.clips, hasLength(2));
    });
  });

  group('background sweep', () {
    test('removes older verbatim duplicates and is idempotent', () async {
      final store = await _store(<ClipItem>[
        _text('old', 'same', minutesAgo: 30, pinned: true),
        _text('new', 'same'),
        _text('alone', 'unique', minutesAgo: 3),
        _image('img1'),
        _image('img2', minutesAgo: 2),
      ]);
      store.toggleQueued('old');
      expect(await store.dedupeText(), 1);
      expect(store.findById('old'), isNull);
      expect(store.findById('new')!.pinned, isTrue);
      expect(store.queuedIds, isEmpty);
      expect(store.clips.where((c) => c.kind == ClipKind.image), hasLength(2));
      expect(await store.dedupeText(), 0);
    });

    test('restore never re-creates a duplicate', () async {
      final store = await _store(<ClipItem>[_text('a', 'same', minutesAgo: 5)]);
      final removed = store.itemById('a');
      await store.delete('a');
      await store.addText('same');
      await store.restore(removed);
      expect(store.clips.where((c) => c.text == 'same'), hasLength(1));
    });
  });

  group('worker (rxdart)', () {
    testWidgets('sweeps once the history has been quiet, without blocking '
        'start-up', (tester) async {
      final store = _CountingStore(<ClipItem>[
        _text('old', 'same', minutesAgo: 30),
        _text('new', 'same'),
      ]);
      await store.initialize();
      final worker = TextDedupeWorker(store)..start();

      await tester.pump(const Duration(milliseconds: 500));
      expect(store.clips, hasLength(2), reason: 'not yet: still debouncing');
      await tester.pump(const Duration(seconds: 2));
      expect(store.clips.single.id, 'new');
      expect(store.sweeps, 1);
      unawaited(worker.dispose());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('bursts of changes coalesce into one sweep', (tester) async {
      final store = _CountingStore(const <ClipItem>[]);
      await store.initialize();
      final worker = TextDedupeWorker(store)..start();
      await tester.pump(const Duration(seconds: 3));
      final afterStartup = store.sweeps;

      for (var i = 0; i < 10; i += 1) {
        store.setQuery('q$i');
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.pump(const Duration(seconds: 3));
      expect(store.sweeps - afterStartup, 1);
      unawaited(worker.dispose());
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

class _CountingStore extends ClipStore {
  _CountingStore(List<ClipItem> seed)
    : super(
        repository: MemoryClipRepository(seed: seed),
        clock: demoClock,
      );

  int sweeps = 0;

  @override
  Future<int> dedupeText() {
    sweeps += 1;
    return super.dedupeText();
  }
}
