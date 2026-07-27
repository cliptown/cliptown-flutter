import 'dart:math';

const int minEncryptedChunkSize = 64 * 1024;
const int maxEncryptedChunkSize = 16 * 1024 * 1024;
const int maxEncryptedObjectChunks = 100000;

final class PlannedEncryptedChunk {
  const PlannedEncryptedChunk({
    required this.index,
    required this.plaintextOffset,
    required this.plaintextLength,
    required this.randomizedStorageKey,
  });

  final int index;
  final int plaintextOffset;
  final int plaintextLength;
  final String randomizedStorageKey;
}

final class EncryptedUploadPlan {
  const EncryptedUploadPlan({
    required this.objectId,
    required this.chunkSize,
    required this.chunks,
  });

  final String objectId;
  final int chunkSize;
  final List<PlannedEncryptedChunk> chunks;
}

EncryptedUploadPlan planEncryptedUpload({
  required String objectId,
  required int plaintextLength,
  int chunkSize = 4 * 1024 * 1024,
  String Function()? randomSegment,
}) {
  if (objectId.isEmpty || objectId.length > 128) {
    throw const FormatException('object_id is empty or too long');
  }
  if (plaintextLength < 0) {
    throw const FormatException('plaintext_length must be non-negative');
  }
  if (chunkSize < minEncryptedChunkSize || chunkSize > maxEncryptedChunkSize) {
    throw const FormatException('chunk_size is outside supported bounds');
  }

  final count = plaintextLength == 0 ? 1 : (plaintextLength + chunkSize - 1) ~/ chunkSize;
  if (count > maxEncryptedObjectChunks) {
    throw const FormatException('object requires too many encrypted chunks');
  }

  final segmentFactory = randomSegment ?? _secureRandomSegment;
  final chunks = <PlannedEncryptedChunk>[];
  final seen = <String>{};
  for (var index = 0; index < count; index += 1) {
    final offset = index * chunkSize;
    final remaining = plaintextLength - offset;
    final length = plaintextLength == 0 ? 0 : min(chunkSize, remaining);
    final segment = segmentFactory();
    if (segment.length < 32 || !seen.add(segment)) {
      throw const FormatException('random storage segment is short or duplicated');
    }
    chunks.add(
      PlannedEncryptedChunk(
        index: index,
        plaintextOffset: offset,
        plaintextLength: length,
        randomizedStorageKey: 'objects/$segment/chunk-${index.toString().padLeft(6, '0')}',
      ),
    );
  }

  return EncryptedUploadPlan(
    objectId: objectId,
    chunkSize: chunkSize,
    chunks: List.unmodifiable(chunks),
  );
}

String _secureRandomSegment() {
  final random = Random.secure();
  final buffer = StringBuffer();
  for (var index = 0; index < 24; index += 1) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
