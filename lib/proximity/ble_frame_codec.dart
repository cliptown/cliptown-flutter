import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

const int _frameHeaderBytes = 12;
const int _frameMagic = 0x4354; // "CT"
const int _frameVersion = 1;
const int maxBleFrameParts = 4096;

/// Deterministic ClipTown framing over BLE characteristics.
///
/// Every packet carries `CT`, version, flags, a random frame id, part index,
/// part count, and payload. The receiver bounds allocation before retaining any
/// part and rejects duplicates, conflicting counts, malformed order, and stale
/// partial frames. Envelope replay protection is a separate higher-level gate.
final class BleFrameCodec {
  BleFrameCodec({Random? random}) : _random = random ?? Random.secure();

  final Random _random;

  List<Uint8List> fragment(Uint8List message, {required int packetBytes}) {
    if (message.isEmpty || message.length > maxProximityFrameBytes) {
      throw const FormatException('BLE message is empty or too large');
    }
    if (packetBytes < 20 || packetBytes > 512) {
      throw const FormatException('BLE packet size is outside reviewed bounds');
    }
    final payloadBytes = packetBytes - _frameHeaderBytes;
    final total = (message.length + payloadBytes - 1) ~/ payloadBytes;
    if (total < 1 || total > maxBleFrameParts) {
      throw const FormatException('BLE message requires too many packets');
    }
    final frameId = _random.nextInt(0x100000000);
    return List<Uint8List>.generate(total, (index) {
      final start = index * payloadBytes;
      final end = min(start + payloadBytes, message.length);
      final data = ByteData(_frameHeaderBytes)
        ..setUint16(0, _frameMagic, Endian.big)
        ..setUint8(2, _frameVersion)
        ..setUint8(3, index == total - 1 ? 1 : 0)
        ..setUint32(4, frameId, Endian.big)
        ..setUint16(8, index, Endian.big)
        ..setUint16(10, total, Endian.big);
      return Uint8List.fromList(<int>[
        ...data.buffer.asUint8List(),
        ...message.sublist(start, end),
      ]);
    });
  }
}

const int maxProximityFrameBytes = 48 * 1024;

final class BleFrameReassembler {
  BleFrameReassembler({
    this.capacity = 8,
    this.timeout = const Duration(seconds: 15),
  }) {
    if (capacity < 1 || capacity > 32 || timeout <= Duration.zero) {
      throw ArgumentError('invalid BLE reassembly bounds');
    }
  }

  final int capacity;
  final Duration timeout;
  final LinkedHashMap<int, _PendingFrame> _pending = LinkedHashMap();

  Uint8List? add(Uint8List packet, {required DateTime now}) {
    _expire(now.toUtc());
    if (packet.length < _frameHeaderBytes + 1 || packet.length > 512) {
      throw const FormatException('invalid BLE packet size');
    }
    final data = ByteData.sublistView(packet);
    final magic = data.getUint16(0, Endian.big);
    final version = data.getUint8(2);
    final flags = data.getUint8(3);
    final frameId = data.getUint32(4, Endian.big);
    final index = data.getUint16(8, Endian.big);
    final total = data.getUint16(10, Endian.big);
    if (magic != _frameMagic ||
        version != _frameVersion ||
        flags & ~1 != 0 ||
        total < 1 ||
        total > maxBleFrameParts ||
        index >= total ||
        ((flags & 1) == 1) != (index == total - 1)) {
      throw const FormatException('invalid BLE packet header');
    }

    final frame = _pending.putIfAbsent(
      frameId,
      () => _PendingFrame(total: total, expiresAt: now.toUtc().add(timeout)),
    );
    if (frame.total != total || frame.parts.containsKey(index)) {
      _pending.remove(frameId);
      throw const FormatException('conflicting or duplicate BLE packet');
    }
    frame.parts[index] = Uint8List.fromList(packet.sublist(_frameHeaderBytes));
    frame.byteCount += packet.length - _frameHeaderBytes;
    if (frame.byteCount > maxProximityFrameBytes) {
      _pending.remove(frameId);
      throw const FormatException('reassembled BLE frame exceeds limit');
    }
    while (_pending.length > capacity) {
      _pending.remove(_pending.keys.first);
    }
    if (frame.parts.length != total) return null;

    final output = BytesBuilder(copy: false);
    for (var part = 0; part < total; part += 1) {
      final bytes = frame.parts[part];
      if (bytes == null) return null;
      output.add(bytes);
    }
    _pending.remove(frameId);
    return output.takeBytes();
  }

  void clear() => _pending.clear();

  void _expire(DateTime now) {
    final expired = _pending.entries
        .where((entry) => !entry.value.expiresAt.isAfter(now))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final frameId in expired) {
      _pending.remove(frameId);
    }
  }
}

final class _PendingFrame {
  _PendingFrame({required this.total, required this.expiresAt});

  final int total;
  final DateTime expiresAt;
  final Map<int, Uint8List> parts = <int, Uint8List>{};
  int byteCount = 0;
}
