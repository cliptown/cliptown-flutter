import 'dart:typed_data';

import 'package:cliptown_app/history/cache/bounded_vector_search.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounded top-K exactly matches a full reference sort', () {
    const count = 50000;
    const limit = 20;
    final heap = BoundedVectorSearch(limit);
    final reference = <ClipVectorMatch>[];
    for (var i = count - 1; i >= 0; i -= 1) {
      // Include many equal distances so tie-breaking is exercised.
      final distance = ((i * 113) % 997).toDouble() / 997;
      final id = 'clip-${i.toString().padLeft(6, '0')}';
      heap.offer(id, distance);
      reference.add(ClipVectorMatch(id, distance));
      expect(heap.retainedCount, lessThanOrEqualTo(limit));
    }
    reference.sort((a, b) {
      final score = a.distance.compareTo(b.distance);
      return score != 0 ? score : a.clipId.compareTo(b.clipId);
    });
    expect(
      heap.sorted().map((match) => match.clipId),
      reference.take(limit).map((match) => match.clipId),
    );
    expect(
      heap.sorted().map((match) => match.distance),
      reference.take(limit).map((match) => match.distance),
    );
  });

  test('exact cosine scan reads Float32 directly without decoding a list', () {
    final query = List<double>.filled(localEmbeddingDimensions, 0)..[0] = 1;
    final stored = List<double>.filled(localEmbeddingDimensions, 0)
      ..[0] = 0.6
      ..[1] = 0.8;
    final norm = validEmbeddingMagnitude(query)!;
    expect(
      encodedCosineDistance(query, norm, encodeLocalEmbedding(stored)),
      closeTo(0.4, 0.00001),
    );
    expect(
      encodedCosineDistance(query, norm, Uint8List(2)),
      isNull,
    );
    final invalid = List<double>.filled(localEmbeddingDimensions, 0)
      ..[0] = double.nan;
    expect(
      encodedCosineDistance(query, norm, encodeLocalEmbedding(invalid)),
      isNull,
    );
    expect(validEmbeddingMagnitude(invalid), isNull);
    expect(
      encodedCosineDistance(
        query,
        norm,
        encodeLocalEmbedding(
          List<double>.filled(localEmbeddingDimensions, 0),
        ),
      ),
      isNull,
    );
  });

  test('equal-distance hits are ordered by ID regardless of insertion order', () {
    final heap = BoundedVectorSearch(2);
    heap.offer('z', 0.5);
    heap.offer('y', 0.5);
    heap.offer('x', 0.5);
    heap.offer('a', 0.8);
    heap.offer('ignored', double.nan);
    expect(heap.sorted().map((hit) => hit.clipId), <String>['x', 'y']);
    expect(heap.retainedCount, 2);
  });
}
