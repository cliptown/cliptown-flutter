import 'dart:io';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:cliptown_app/history/minilm_semantic_clip_repository.dart';
import 'package:cliptown_app/history/minilm_embedder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final live = Platform.environment['CLIPTOWN_RUN_MINILM_LIVE_TEST'] == '1';

  test(
    'native MiniLM retrieves paraphrases without literal overlap',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'cliptown-live-minilm-',
      );
      final model = MiniLmOnDeviceEmbedder(modelDirectory: temp);
      try {
        final a = await model.embed('A person buys a pair of sneakers.');
        final b = await model.embed('Someone purchases new athletic shoes.');
        final unrelated = await model.embed('The storm produced strong winds.');
        expect(a, hasLength(384));
        // Long clipboard content must not exceed the encoder micro-batch.
        final longVector = await model.embed(
          List<String>.filled(
            250,
            'Athletic shoes and running gear.',
          ).join(' '),
        );
        expect(longVector, hasLength(384));
        expect(
          localEmbeddingCosineDistance(a, b),
          lessThan(localEmbeddingCosineDistance(a, unrelated)),
        );
        final now = DateTime.utc(2026, 11, 14);
        final index = MiniLmSemanticClipRepository(
          history: MemoryClipRepository(
            seed: <ClipItem>[
              ClipItem(
                id: 'shoes',
                kind: ClipKind.text,
                title: 'Shoe shopping',
                text: 'Someone purchases new athletic shoes.',
                createdAt: now,
                lastUsedAt: now,
              ),
              ClipItem(
                id: 'storm',
                kind: ClipKind.text,
                title: 'Weather report',
                text: 'The storm produced strong winds.',
                createdAt: now,
                lastUsedAt: now,
              ),
            ],
          ),
          indexPath: '${temp.path}${Platform.pathSeparator}semantic.db',
          model: model,
        );
        await index.load();
        await index.waitForIndexing();
        final matches = await index.vectorSearch(
          'A person buys a pair of sneakers.',
        );
        expect(matches.first.clipId, 'shoes');
        expect(matches.first.distance, lessThan(matches.last.distance));
        await index.close();
      } finally {
        await model.dispose();
        await temp.delete(recursive: true);
      }
    },
    skip: live
        ? false
        : 'Set CLIPTOWN_RUN_MINILM_LIVE_TEST=1 to test model inference',
  );
}
