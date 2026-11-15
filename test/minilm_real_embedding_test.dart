import 'dart:io';

import 'package:cliptown_app/history/local_embedding.dart';
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
        expect(
          localEmbeddingCosineDistance(a, b),
          lessThan(localEmbeddingCosineDistance(a, unrelated)),
        );
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
