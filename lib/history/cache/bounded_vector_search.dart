import 'dart:math' as math;
import 'dart:typed_data';

import '../local_embedding.dart';

/// Exact, deterministic top-K cosine ranking with O(K) retained results.
/// The worst candidate stays at heap[0] for O(log K) replacement.
final class ClipVectorMatch {
  const ClipVectorMatch(this.clipId, this.distance);

  final String clipId;
  final double distance;
}

final class BoundedVectorSearch {
  BoundedVectorSearch(this.limit) : assert(limit > 0);

  final int limit;
  final List<ClipVectorMatch> _heap = <ClipVectorMatch>[];

  int retainedCount() => _heap.length;

  static bool _isWorse(ClipVectorMatch a, ClipVectorMatch b) {
    final comparison = a.distance.compareTo(b.distance);
    return comparison != 0
        ? comparison > 0
        : a.clipId.compareTo(b.clipId) > 0;
  }

  void offer(String clipId, double distance) {
    if (!distance.isFinite) return;
    final candidate = ClipVectorMatch(clipId, distance);
    if (_heap.length < limit) {
      _heap.add(candidate);
      _siftUp(_heap.length - 1);
    } else if (_isWorse(_heap.first, candidate)) {
      _heap[0] = candidate;
      _siftDown(0);
    }
  }

  List<ClipVectorMatch> sorted() {
    final matches = List<ClipVectorMatch>.of(_heap);
    matches.sort((a, b) {
      final comparison = a.distance.compareTo(b.distance);
      return comparison != 0
          ? comparison
          : a.clipId.compareTo(b.clipId);
    });
    return matches;
  }

  void _siftUp(int index) {
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (!_isWorse(_heap[index], _heap[parent])) break;
      final previous = _heap[parent];
      _heap[parent] = _heap[index];
      _heap[index] = previous;
      index = parent;
    }
  }

  void _siftDown(int index) {
    while (true) {
      final left = index * 2 + 1;
      if (left >= _heap.length) return;
      final right = left + 1;
      var worst = left;
      if (right < _heap.length && _isWorse(_heap[right], _heap[left])) {
        worst = right;
      }
      if (!_isWorse(_heap[worst], _heap[index])) return;
      final previous = _heap[index];
      _heap[index] = _heap[worst];
      _heap[worst] = previous;
      index = worst;
    }
  }
}

/// Calculate query magnitude once per search, not once per stored vector.
/// Reject corrupted/non-finite native model outputs rather than rank them.
double? validEmbeddingMagnitude(List<double> query) {
  if (query.length != localEmbeddingDimensions) return null;
  var squared = 0.0;
  for (final value in query) {
    if (!value.isFinite) return null;
    squared += value * value;
  }
  if (!squared.isFinite || squared <= 0) return null;
  return math.sqrt(squared);
}

/// Scan a little-endian Float32 SQLite vector in place. Avoids materializing
/// 384 Dart doubles for every row (100k rows otherwise create 38.4m doubles).
/// Malformed, zero-length and non-finite vectors are skipped.
double? encodedCosineDistance(
  List<double> query,
  double queryMagnitude,
  Uint8List bytes,
) {
  if (query.length != localEmbeddingDimensions ||
      !queryMagnitude.isFinite ||
      queryMagnitude <= 0 ||
      bytes.length !=
          localEmbeddingDimensions * Float32List.bytesPerElement) {
    return null;
  }
  final values = ByteData.sublistView(bytes);
  var dot = 0.0;
  var squared = 0.0;
  for (var index = 0; index < localEmbeddingDimensions; index += 1) {
    final value = values.getFloat32(
      index * Float32List.bytesPerElement,
      Endian.little,
    );
    if (!value.isFinite) return null;
    dot += value * query[index];
    squared += value * value;
  }
  if (!squared.isFinite || squared <= 0) return null;
  final denominator = queryMagnitude * math.sqrt(squared);
  if (!denominator.isFinite || denominator <= 0) return null;
  final distance = 1 - dot / denominator;
  return distance.isFinite ? distance.clamp(0.0, 2.0).toDouble() : null;
}
