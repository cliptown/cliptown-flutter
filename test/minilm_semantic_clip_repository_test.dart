import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:cliptown_app/history/minilm_embedder.dart';
import 'package:cliptown_app/history/minilm_semantic_clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

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
    // Index notifications are throttled to keep the UI responsive.
    await Future<void>.delayed(const Duration(milliseconds: 150));
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

  test(
    'transient embedding failure can recover on next history save',
    () async {
      final model = _TransientFailureEmbedder();
      final repo = newRepository(embedder: model);
      final clips = await repo.load();
      await repo.waitForIndexing();
      expect(await repo.embeddingCount(), 0);

      await repo.save(clips);
      await repo.waitForIndexing();
      expect(await repo.embeddingCount(), 2);
      expect(
        await repo.semanticSearchIds('software rollout release'),
        contains('deploy-command'),
      );
      await repo.clear();
    },
  );

  test('reconciles a truncated vector without rewriting the clip', () async {
    final model = _FakeMeaningEmbedder();
    final repo = newRepository(embedder: model);
    final clips = await repo.load();
    await repo.waitForIndexing();
    final db = sqlite3.open(indexPath);
    db.execute(
      "UPDATE vectors SET embedding = x'00' WHERE clip_id = 'deploy-command'",
    );
    db.close();

    await repo.save(clips);
    await repo.waitForIndexing();
    expect(await repo.embeddingCount(), 2);
    expect(model.calls, 3);
    expect(
      await repo.semanticSearchIds('software rollout release'),
      contains('deploy-command'),
    );
    await repo.clear();
  });

  test('non-finite persisted embeddings never enter ranked results', () async {
    final repo = newRepository();
    await repo.load();
    await repo.waitForIndexing();
    final bad = List<double>.filled(localEmbeddingDimensions, 0)
      ..[0] = double.nan;
    final db = sqlite3.open(indexPath);
    db.execute('UPDATE vectors SET embedding = ? WHERE clip_id = ?', <Object?>[
      encodeLocalEmbedding(bad),
      'deploy-command',
    ]);
    db.close();

    expect(await repo.semanticSearchIds('software rollout release'), isEmpty);
    await repo.clear();
  });

  test(
    'vault clear racing with an outstanding query cannot revive results',
    () async {
      final model = _BlockedQueryEmbedder();
      final repo = newRepository(embedder: model);
      await repo.load();
      await repo.waitForIndexing();
      final search = repo.semanticSearchIds('software rollout release');
      await model.queryStarted.future;

      await repo.clear();
      model.releaseQuery();
      expect(await search, isEmpty);
      expect(await File(indexPath).exists(), isFalse);
    },
  );

  test(
    'query recovers an offline-first model load without a history edit',
    () async {
      final model = _TransientFailureEmbedder();
      final repo = newRepository(embedder: model);
      await repo.load();
      await repo.waitForIndexing();
      expect(await repo.embeddingCount(), 0);

      expect(await repo.semanticSearchIds('software rollout release'), isEmpty);
      await repo.waitForIndexing();
      expect(await repo.embeddingCount(), 2);
      expect(
        await repo.semanticSearchIds('software rollout release'),
        contains('deploy-command'),
      );
      await repo.clear();
    },
  );

  test('replacing history invalidates an in-flight semantic query', () async {
    final model = _BlockedQueryEmbedder();
    final repo = newRepository(embedder: model);
    final clips = await repo.load();
    await repo.waitForIndexing();
    final search = repo.semanticSearchIds('software rollout release');
    await model.queryStarted.future;

    await repo.save(
      clips.where((clip) => clip.id == 'security-notes').toList(),
    );
    model.releaseQuery();
    expect(await search, isEmpty);
    await repo.clear();
  });

  test('query embedding is reused across index revisions', () async {
    final model = _FakeMeaningEmbedder();
    final repo = newRepository(embedder: model);
    final clips = await repo.load();
    await repo.waitForIndexing();
    expect(model.calls, 2);

    await repo.vectorSearch('software rollout release');
    await repo.vectorSearch('software rollout release');
    await repo.save(clips.reversed.toList());
    await repo.vectorSearch('software rollout release');
    expect(model.calls, 3, reason: 'same query needs one model inference');

    await repo.vectorSearch('entirely different query');
    expect(model.calls, 4);
    await repo.clear();
  });

  test('reordering unchanged clips preserves an in-flight query', () async {
    final model = _BlockedQueryEmbedder();
    final repo = newRepository(embedder: model);
    final clips = await repo.load();
    await repo.waitForIndexing();

    final search = repo.semanticSearchIds('software rollout release');
    await model.queryStarted.future;
    await repo.save(clips.reversed.toList());
    model.releaseQuery();

    expect(await search, contains('deploy-command'));
    await repo.clear();
  });

  test(
    'paged vector search produces exact top K past the first batch',
    () async {
      final now = DateTime.utc(2026, 11, 14);
      final many = List<ClipItem>.generate(
        520,
        (index) => ClipItem(
          id: 'clip-${index.toString().padLeft(4, '0')}',
          kind: ClipKind.text,
          title: 'Note $index',
          text: 'ordinary saved note $index',
          createdAt: now,
          lastUsedAt: now,
        ),
      );
      final repo = newRepository(history: MemoryClipRepository(seed: many));
      await repo.load();
      await repo.waitForIndexing();
      expect(await repo.embeddingCount(), 520);

      final results = await repo.vectorSearch('unrelated text', limit: 12);
      expect(
        results.map((match) => match.clipId),
        many.take(12).map((clip) => clip.id),
      );
      expect(results, hasLength(12));
      await repo.clear();
    },
  );

  test('index status reflects failure, retry and completed backfill', () async {
    final model = _TransientFailureEmbedder();
    final repo = newRepository(embedder: model);
    final states = <SemanticIndexProgress>[];
    final subscription = repo.indexProgressUpdates.listen(states.add);
    await repo.load();
    await repo.waitForIndexing();
    expect(repo.indexProgress.phase, SemanticIndexPhase.unavailable);

    await repo.retrySemanticIndex();
    await repo.waitForIndexing();
    expect(repo.indexProgress.phase, SemanticIndexPhase.ready);
    expect(repo.indexProgress.indexed, 2);
    expect(repo.indexProgress.total, 2);
    expect(states.any((s) => s.phase == SemanticIndexPhase.indexing), isTrue);
    await subscription.cancel();
    await repo.clear();
  });

  test('reports model-download percentage without clip plaintext', () async {
    final repo = newRepository();
    repo.reportModelDownloadProgress(1024, 2048);
    expect(repo.indexProgress.phase, SemanticIndexPhase.downloading);
    expect(repo.indexProgress.downloadPercent, 50);
    expect(repo.indexProgress.label, contains('50%'));
    await repo.load();
    await repo.waitForIndexing();
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

class _TransientFailureEmbedder extends _FakeMeaningEmbedder {
  bool failFirst = true;

  @override
  Future<List<double>> embed(String text) async {
    if (failFirst) {
      failFirst = false;
      throw const FormatException('temporary model load failure');
    }
    return super.embed(text);
  }
}

class _BlockedQueryEmbedder extends _FakeMeaningEmbedder {
  final Completer<void> queryStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();

  void releaseQuery() => _release.complete();

  @override
  Future<List<double>> embed(String text) async {
    if (text == 'software rollout release') {
      queryStarted.complete();
      await _release.future;
    }
    return super.embed(text);
  }
}
