import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

const int localEmbeddingDimensions = 384;
const String localEmbeddingModel = 'cliptown-fnv1a-v1';

List<double> createLocalEmbedding(String text) {
  final vector = List<double>.filled(localEmbeddingDimensions, 0);
  final tokens = text
      .toLowerCase()
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((token) => token.isNotEmpty);
  for (final token in tokens) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(token)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    final index = hash % localEmbeddingDimensions;
    vector[index] += hash & 0x80000000 == 0 ? 1 : -1;
  }
  final magnitude = math.sqrt(
    vector.fold<double>(0, (sum, value) => sum + value * value),
  );
  if (magnitude > 0) {
    for (var index = 0; index < vector.length; index += 1) {
      vector[index] /= magnitude;
    }
  }
  return vector;
}

Uint8List encodeLocalEmbedding(List<double> vector) {
  if (vector.length != localEmbeddingDimensions) {
    throw const FormatException('local embedding has unexpected dimensions');
  }
  final bytes = ByteData(vector.length * Float32List.bytesPerElement);
  for (var index = 0; index < vector.length; index += 1) {
    bytes.setFloat32(
      index * Float32List.bytesPerElement,
      vector[index],
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}

List<double> decodeLocalEmbedding(Uint8List bytes) {
  final expectedLength = localEmbeddingDimensions * Float32List.bytesPerElement;
  if (bytes.length != expectedLength) {
    throw const FormatException('stored local embedding is malformed');
  }
  final data = ByteData.sublistView(bytes);
  return List<double>.generate(
    localEmbeddingDimensions,
    (index) =>
        data.getFloat32(index * Float32List.bytesPerElement, Endian.little),
    growable: false,
  );
}

double localEmbeddingCosineDistance(List<double> left, List<double> right) {
  if (left.length != localEmbeddingDimensions ||
      right.length != localEmbeddingDimensions) {
    throw const FormatException('local embedding dimensions do not match');
  }
  var dotProduct = 0.0;
  var leftMagnitude = 0.0;
  var rightMagnitude = 0.0;
  for (var index = 0; index < localEmbeddingDimensions; index += 1) {
    dotProduct += left[index] * right[index];
    leftMagnitude += left[index] * left[index];
    rightMagnitude += right[index] * right[index];
  }
  if (leftMagnitude == 0 || rightMagnitude == 0) return 1;
  return 1 - (dotProduct / math.sqrt(leftMagnitude * rightMagnitude));
}
