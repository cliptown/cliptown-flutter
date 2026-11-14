import 'dart:typed_data';

import 'package:cliptown_app/history/local_embedding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('creates deterministic normalized embeddings for Unicode text', () {
    final first = createLocalEmbedding('Clipboard café 東京');
    final second = createLocalEmbedding('clipboard café 東京');

    expect(first, hasLength(localEmbeddingDimensions));
    expect(first, second);
    expect(first.any((value) => value != 0), isTrue);
    expect(
      first.fold<double>(0, (sum, value) => sum + value * value),
      closeTo(1, 0.000001),
    );
  });

  test('encodes Float32 values and rejects malformed stored vectors', () {
    final vector = createLocalEmbedding('local vector round trip');
    final encoded = encodeLocalEmbedding(vector);
    final decoded = decodeLocalEmbedding(encoded);

    expect(
      encoded,
      hasLength(localEmbeddingDimensions * Float32List.bytesPerElement),
    );
    expect(localEmbeddingCosineDistance(vector, decoded), closeTo(0, 0.000001));
    expect(
      () => decodeLocalEmbedding(Uint8List(2)),
      throwsA(isA<FormatException>()),
    );
  });
}
