import 'package:cliptown_app/history/capture_policy.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  test('pinned clips sort first and filters combine', () async {
    final store = await createDemoStore();
    expect(store.visibleClips.first.id, 'deploy-command');

    store.setPinnedOnly(true);
    expect(store.visibleClips.map((clip) => clip.id), <String>[
      'deploy-command',
    ]);

    await store.togglePinned('design-reference');
    expect(store.visibleClips.map((clip) => clip.id).toSet(), <String>{
      'deploy-command',
      'design-reference',
    });

    store.setKindFilter(ClipKind.image);
    expect(store.visibleClips.single.id, 'design-reference');
  });

  test('search covers content, kind, tags, and collection', () async {
    final store = await createDemoStore();
    store.setQuery('image');
    expect(store.visibleClips.single.id, 'design-reference');

    store.setQuery('master key');
    expect(store.visibleClips.single.id, 'security-notes');

    store.setQuery('kubernetes');
    expect(store.visibleClips.single.id, 'deploy-command');

    store.setQuery('operations');
    expect(store.visibleClips.single.id, 'deploy-command');
  });

  test(
    'search merges local embedding matches without replacing lexical hits',
    () async {
      final repository = _SemanticRepository(seed: demoClipItems());
      final store = ClipStore(repository: repository);
      await store.initialize();

      store.setQuery('release procedure');
      await Future<void>.delayed(Duration.zero);

      expect(store.visibleClips.single.id, 'deploy-command');
      expect(repository.lastQuery, 'release procedure');
    },
  );

  test('saved-item limit is configurable and keeps pinned clips', () async {
    final store = await createDemoStore();

    await store.setHistoryLimit(1);

    expect(store.policy.maxHistoryItems, 1);
    expect(store.clips.where((clip) => clip.pinned), hasLength(1));
    expect(store.clips.where((clip) => !clip.pinned), hasLength(1));
    await expectLater(store.setHistoryLimit(0), throwsFormatException);
  });

  test('capture deduplicates and preserves organization', () async {
    var now = DateTime.utc(2026, 8, 22, 13);
    final store = ClipStore(
      repository: MemoryClipRepository(),
      clock: () => now,
    );
    await store.initialize();
    final first = await store.addText('https://cliptown.example/docs');
    await store.togglePinned(first.item!.id);
    await store.setCollection(first.item!.id, 'Research');

    now = now.add(const Duration(minutes: 1));
    final second = await store.addText('https://cliptown.example/docs');

    expect(second.refreshedExisting, isTrue);
    expect(store.clips, hasLength(1));
    expect(store.clips.single.id, first.item!.id);
    expect(store.clips.single.pinned, isTrue);
    expect(store.clips.single.collection, 'Research');
    expect(store.clips.single.createdAt, now);
  });

  test('likely secrets are rejected before repository persistence', () async {
    final repository = _RecordingRepository();
    final store = ClipStore(repository: repository);
    await store.initialize();

    final result = await store.addText(
      'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456',
    );

    expect(result.accepted, isFalse);
    expect(result.rejectionReason, CaptureRejectionReason.likelySensitive);
    expect(repository.saveCount, 0);
    expect(store.clips, isEmpty);
  });

  test('retention and size caps exempt pinned items', () async {
    final now = DateTime.utc(2026, 8, 22, 13);
    final old = demoClipItems().first.copyWith(
      createdAt: now.subtract(const Duration(days: 90)),
      lastUsedAt: now.subtract(const Duration(days: 90)),
      pinned: true,
    );
    final expired = demoClipItems().last.copyWith(
      createdAt: now.subtract(const Duration(days: 90)),
      lastUsedAt: now.subtract(const Duration(days: 90)),
    );
    final store = ClipStore(
      repository: MemoryClipRepository(seed: <ClipItem>[old, expired]),
      policy: const CapturePolicy(
        retention: Duration(days: 30),
        maxHistoryItems: 1,
      ),
      clock: () => now,
    );

    await store.initialize();
    expect(store.clips.map((clip) => clip.id), <String>['deploy-command']);
  });

  test('queue preserves explicit order and skips deleted clips', () async {
    final store = await createDemoStore();
    store.toggleQueued('security-notes');
    store.toggleQueued('deploy-command');
    await store.delete('security-notes');

    expect(store.takeNextQueued()!.id, 'deploy-command');
    expect(store.takeNextQueued(), isNull);
  });

  test('repository write failure rolls back and locks capture', () async {
    final repository = _RecordingRepository(failWrites: true);
    final store = ClipStore(repository: repository);
    await store.initialize();

    await expectLater(
      store.addText('safe local note'),
      throwsA(isA<ClipRepositoryException>()),
    );

    expect(store.clips, isEmpty);
    expect(store.vaultLocked, isTrue);
    expect(store.captureEnabled, isFalse);
  });

  test(
    'source exclusions are enforced when an adapter supplies identity',
    () async {
      final store = ClipStore(
        repository: MemoryClipRepository(),
        policy: const CapturePolicy(
          ignoredApplications: <String>{'com.example.passwords'},
        ),
      );
      await store.initialize();

      final result = await store.capture(
        ClipboardSnapshot.text(
          text: 'ordinary-looking copied value',
          sourceApplication: 'com.example.passwords',
        ),
      );

      expect(result.rejectionReason, CaptureRejectionReason.ignoredApplication);
      expect(store.clips, isEmpty);
    },
  );
}

class _RecordingRepository implements ClipRepository {
  _RecordingRepository({this.failWrites = false});

  final bool failWrites;
  int saveCount = 0;

  @override
  Future<void> clear() async {}

  @override
  Future<List<ClipItem>> load() async => <ClipItem>[];

  @override
  Future<void> save(List<ClipItem> clips) async {
    saveCount += 1;
    if (failWrites) throw StateError('simulated write failure');
  }
}

class _SemanticRepository extends MemoryClipRepository
    implements SemanticClipRepository {
  _SemanticRepository({required super.seed});

  String? lastQuery;

  @override
  Future<List<String>> semanticSearchIds(String query, {int limit = 20}) async {
    lastQuery = query;
    return <String>['deploy-command'];
  }
}
