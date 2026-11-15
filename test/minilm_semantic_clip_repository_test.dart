import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:cliptown_app/history/minilm_embedder.dart';
import 'package:cliptown_app/history/minilm_semantic_clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  late Directory temp;
  late String indexPath;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cliptown-minilm-test-');
    indexPath = '${temp.path}${Platform.pathSeparator}semantic.db';
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  MiniLmSemanticClipRepository newRepository({
    LocalTextEmbeddingModel? embedder,
    MemoryClipRepository? history,
  }) {
    return MiniLmSemanticClipRepository(
      history: history ?? MemoryClipRepository(seed: demoClipItems()),
      indexPath: indexPath,
      model: embedder ?? _FakeMeaningEmbedder(),
    );
  }

  test('backfills old clips to persistent local MiniLM vector rows', () async {
    final repo = newRepository();
    final original = await repo.load();
    await repo.waitForIndexing();

    expect(original, hasLength(3));
    expect(await repo.embeddingCount(), 2);
    expect(await File(indexPath).exists(), isTrue);
    expect(
      await repo.semanticSearchIds('software rollout release'),
      contains('deploy-command'),
    );

    // The search cache does not persist copied clipboard plaintext.
    final bytes = await File(indexPath).readAsBytes();
    expect(
      utf8.decode(bytes, allowMalformed: true),
      isNot(contains('kubectl')),
    );

    // Restarting with the same index reuses vectors instead of rebuilding.
    await repo.close();
    final restartedHistory = MemoryClipRepository(seed: original);
    final restartedModel = _FakeMeaningEmbedder();
    final reopened = newRepository(
      embedder: restartedModel,
      history: restartedHistory,
    );
    await reopened.load();
    await reopened.waitForIndexing();
    expect(restartedModel.calls, 0);
    expect(await reopened.embeddingCount(), 2);

    await reopened.clear();
  });

  test(
    'incremental saves preserve unchanged vectors and prune deleted clips',
    () async {
      final model = _FakeMeaningEmbedder();
      final history = MemoryClipRepository(seed: demoClipItems());
      final repo = newRepository(embedder: model, history: history);
      final clips = await repo.load();
      await repo.waitForIndexing();
      expect(model.calls, 2);

      // Pinning or reordering must not trigger another native model pass.
      await repo.save(clips);
      await repo.waitForIndexing();
      expect(model.calls, 2);

      final kept = clips.where((clip) => clip.id == 'security-notes').toList();
      await repo.save(kept);
      await repo.waitForIndexing();
      expect(await repo.embeddingCount(), 1);
      expect(await repo.semanticSearchIds('software rollout release'), isEmpty);

      await repo.clear();
      expect(await File(indexPath).exists(), isFalse);
    },
  );

  test('semantic result updates refresh an already-entered search', () async {
    final model = _DelayedMeaningEmbedder();
    final repo = newRepository(embedder: model);
    final store = ClipStore(repository: repo);
    await store.initialize();
    store.setQuery('software rollout release');
    expect(store.visibleClips, isEmpty);

    model.allow();
    await repo.waitForIndexing();
    // Index notifications start another query while the text stays unchanged.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(
      store.visibleClips.map((clip) => clip.id),
      contains('deploy-command'),
    );

    store.dispose();
    await repo.clear();
  });

  test('deletion during in-flight embedding never resurrects a clip', () async {
    final model = _DelayedMeaningEmbedder();
    final repo = newRepository(embedder: model);
    await repo.load();

    // The model is blocked on the first asynchronous vector.
    await repo.save(const []);
    model.allow();
    await repo.waitForIndexing();
    expect(await repo.embeddingCount(), 0);
    expect(await repo.semanticSearchIds('software rollout release'), isEmpty);
    await repo.clear();
  });

  test('vector codec still accepts exactly 384 floats', () {
    final fake = List<double>.filled(localEmbeddingDimensions, 0)..[0] = 1;
    expect(decodeLocalEmbedding(encodeLocalEmbedding(fake)), fake);
  });
}

class _FakeMeaningEmbedder implements LocalTextEmbeddingModel {
  int calls = 0;

  @override
  String get modelId => 'test-minilm-v1';

  @override
  Future<List<double>> embed(String text) async {
    calls += 1;
    final lower = text.toLowerCase();
    final isDeploy =
        lower.contains('kubectl') ||
        lower.contains('deploy') ||
        lower.contains('software rollout') ||
        lower.contains('release');
    final result = List<double>.filled(localEmbeddingDimensions, 0);
    result[isDeploy ? 0 : 1] = 1;
    return result;
  }
}

class _DelayedMeaningEmbedder extends _FakeMeaningEmbedder {
  final _gate = Completer<void>();

  void allow() => _gate.complete();

  @override
  Future<List<double>> embed(String text) async {
    await _gate.future;
    return super.embed(text);
  }
}
