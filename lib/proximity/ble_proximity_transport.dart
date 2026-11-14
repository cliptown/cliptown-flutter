import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import 'ble_frame_codec.dart';
import 'proximity_contract.dart';

const String cliptownAdvertisementCharacteristicUuid =
    'c11f7a00-7b9e-4d8a-9c3a-4b8a0d86e002';
const String cliptownInboundCharacteristicUuid =
    'c11f7a00-7b9e-4d8a-9c3a-4b8a0d86e003';
const String cliptownOutboundCharacteristicUuid =
    'c11f7a00-7b9e-4d8a-9c3a-4b8a0d86e004';

class ProximityTransportException implements Exception {
  const ProximityTransportException(this.code);

  final String code;

  @override
  String toString() => 'Proximity transport unavailable: $code';
}

final class BlePeerCandidate {
  const BlePeerCandidate({
    required this.transportId,
    required this.displayName,
    required this.rssi,
  });

  /// OS-scoped routing identifier. Never persist, log, or use as identity.
  final String transportId;
  final String displayName;
  final int? rssi;
}

enum BleProximityState {
  idle,
  discovering,
  advertising,
  connecting,
  connected,
  unavailable,
}

/// Foreground-only BLE adapter for ClipTown's encrypted proximity envelopes.
///
/// This class deliberately exposes no automatic startup. Discovery and
/// advertising begin only after a UI calls the corresponding method, and
/// [stopForBackground] tears down every radio/session resource. Peer identity,
/// consent, signature, replay, and decryption checks live above this untrusted
/// byte transport.
final class ClipTownBleTransport extends ChangeNotifier {
  ClipTownBleTransport({BleFrameCodec? frameCodec})
    : _frameCodec = frameCodec ?? BleFrameCodec();

  final BleFrameCodec _frameCodec;
  final BleFrameReassembler _centralReassembler = BleFrameReassembler();
  final Map<String, BleFrameReassembler> _peripheralReassemblers =
      <String, BleFrameReassembler>{};
  final Map<String, BlePeerCandidate> _peers = <String, BlePeerCandidate>{};
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();

  StreamSubscription<BleDevice>? _scanSubscription;
  StreamSubscription<Uint8List>? _notificationSubscription;
  StreamSubscription<BlePeripheralConnectionStateChanged>?
  _peripheralConnectionSubscription;
  BleProximityState _state = BleProximityState.idle;
  String? _connectedTransportId;
  int _packetBytes = 20;
  bool _advertising = false;
  bool _disposed = false;

  BleProximityState get state => _state;
  List<BlePeerCandidate> get peers =>
      List<BlePeerCandidate>.unmodifiable(_peers.values);
  Stream<Uint8List> get incoming => _incoming.stream;
  bool get advertising => _advertising;

  Future<void> startDiscovery() async {
    _ensureOpen();
    await stopDiscovery();
    try {
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
      final availability = await UniversalBle.getBluetoothAvailabilityState();
      if (availability != AvailabilityState.poweredOn) {
        _setState(BleProximityState.unavailable);
        throw const ProximityTransportException('bluetooth_not_ready');
      }
      _peers.clear();
      _scanSubscription = UniversalBle.scanStream.listen(_onScanResult);
      await UniversalBle.startScan(
        scanFilter: ScanFilter(
          withServices: const <String>[cliptownProximityServiceUuid],
          withNamePrefix: const <String>['CT-'],
        ),
      );
      _setState(BleProximityState.discovering);
    } on ProximityTransportException {
      rethrow;
    } on Object {
      _setState(BleProximityState.unavailable);
      throw const ProximityTransportException('discovery_failed');
    }
  }

  Future<void> stopDiscovery() async {
    try {
      if (await UniversalBle.isScanning()) await UniversalBle.stopScan();
    } on Object {
      // Cleanup remains best effort and never changes trust state.
    }
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (_state == BleProximityState.discovering) {
      _setState(BleProximityState.idle);
    }
  }

  void _onScanResult(BleDevice device) {
    final hasService = device.services.any(
      (service) => service.toLowerCase() == cliptownProximityServiceUuid,
    );
    final name = device.name ?? '';
    if (!hasService && !name.startsWith('CT-')) return;
    final safeName = RegExp(r'^CT-[A-Za-z0-9_-]{6}$').hasMatch(name)
        ? name
        : 'ClipTown nearby device';
    _peers[device.deviceId] = BlePeerCandidate(
      transportId: device.deviceId,
      displayName: safeName,
      rssi: device.rssi,
    );
    notifyListeners();
  }

  Future<void> startAdvertising(ProximityAdvertisement advertisement) async {
    _ensureOpen();
    advertisement.validate();
    try {
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
      final capabilities = await UniversalBlePeripheral.getCapabilities();
      final readiness = await UniversalBlePeripheral.getAvailabilityState();
      if (!capabilities.supportsPeripheralMode ||
          readiness != PeripheralReadinessState.ready) {
        _setState(BleProximityState.unavailable);
        throw const ProximityTransportException(
          'peripheral_role_not_supported',
        );
      }
      await UniversalBlePeripheral.clearServices();
      UniversalBlePeripheral.setReadRequestHandlers((
        deviceId,
        characteristicId,
        offset,
        _,
      ) {
        if (characteristicId.toLowerCase() !=
            cliptownAdvertisementCharacteristicUuid) {
          return PeripheralReadRequestResult(value: Uint8List(0));
        }
        final encoded = advertisement.encode();
        if (offset < 0 || offset > encoded.length) {
          return PeripheralReadRequestResult(value: Uint8List(0));
        }
        return PeripheralReadRequestResult(
          value: Uint8List.fromList(encoded.sublist(offset)),
        );
      });
      UniversalBlePeripheral.setWriteRequestHandlers((
        deviceId,
        characteristicId,
        offset,
        value,
      ) {
        if (characteristicId.toLowerCase() !=
                cliptownInboundCharacteristicUuid ||
            offset != 0 ||
            value == null ||
            value.isEmpty ||
            value.length > 512) {
          return PeripheralWriteRequestResult();
        }
        try {
          final reassembler = _peripheralReassemblers.putIfAbsent(
            deviceId,
            BleFrameReassembler.new,
          );
          final message = reassembler.add(value, now: DateTime.now().toUtc());
          if (message != null) _incoming.add(message);
        } on FormatException {
          _peripheralReassemblers.remove(deviceId);
        }
        return PeripheralWriteRequestResult();
      });
      _peripheralConnectionSubscription ??= UniversalBlePeripheral
          .connectionStateStream
          .listen((event) {
            if (!event.connected) {
              _peripheralReassemblers.remove(event.deviceId)?.clear();
            }
          });
      await UniversalBlePeripheral.addService(
        BlePeripheralService(
          uuid: cliptownProximityServiceUuid,
          characteristics: <BlePeripheralCharacteristic>[
            BlePeripheralCharacteristic(
              uuid: cliptownAdvertisementCharacteristicUuid,
              properties: const <CharacteristicProperty>[
                CharacteristicProperty.read,
              ],
              permissions: const <PeripheralAttributePermission>[
                PeripheralAttributePermission.readable,
              ],
              value: advertisement.encode(),
            ),
            BlePeripheralCharacteristic(
              uuid: cliptownInboundCharacteristicUuid,
              properties: const <CharacteristicProperty>[
                CharacteristicProperty.write,
              ],
              permissions: const <PeripheralAttributePermission>[
                PeripheralAttributePermission.writeable,
              ],
            ),
            BlePeripheralCharacteristic(
              uuid: cliptownOutboundCharacteristicUuid,
              properties: const <CharacteristicProperty>[
                CharacteristicProperty.read,
                CharacteristicProperty.notify,
              ],
              permissions: const <PeripheralAttributePermission>[
                PeripheralAttributePermission.readable,
              ],
            ),
          ],
        ),
      );
      await UniversalBlePeripheral.startAdvertising(
        services: const <String>[cliptownProximityServiceUuid],
        localName: advertisement.displayName,
      );
      _advertising = true;
      _setState(BleProximityState.advertising);
    } on ProximityTransportException {
      rethrow;
    } on Object {
      await stopAdvertising();
      _setState(BleProximityState.unavailable);
      throw const ProximityTransportException('advertising_failed');
    }
  }

  Future<ProximityAdvertisement> connectAndReadAdvertisement(
    String transportId,
  ) async {
    _ensureOpen();
    if (!_peers.containsKey(transportId)) {
      throw const ProximityTransportException('peer_not_discovered');
    }
    _setState(BleProximityState.connecting);
    await stopDiscovery();
    try {
      await UniversalBle.connect(
        transportId,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      final services = await UniversalBle.discoverServices(
        transportId,
        timeout: const Duration(seconds: 10),
      );
      final service = services.where(
        (candidate) =>
            candidate.uuid.toLowerCase() == cliptownProximityServiceUuid,
      );
      if (service.isEmpty) {
        throw const ProximityTransportException('service_missing');
      }
      final characteristics = service.first.characteristics
          .map((value) => value.uuid.toLowerCase())
          .toSet();
      if (!characteristics.contains(cliptownAdvertisementCharacteristicUuid) ||
          !characteristics.contains(cliptownInboundCharacteristicUuid) ||
          !characteristics.contains(cliptownOutboundCharacteristicUuid)) {
        throw const ProximityTransportException('characteristic_missing');
      }
      final advertisementBytes = await UniversalBle.read(
        transportId,
        cliptownProximityServiceUuid,
        cliptownAdvertisementCharacteristicUuid,
      );
      final advertisement = ProximityAdvertisement.fromBytes(
        advertisementBytes,
      );
      await UniversalBle.subscribeNotifications(
        transportId,
        cliptownProximityServiceUuid,
        cliptownOutboundCharacteristicUuid,
      );
      _notificationSubscription =
          UniversalBle.characteristicValueStream(
            transportId,
            cliptownOutboundCharacteristicUuid,
          ).listen((packet) {
            try {
              final message = _centralReassembler.add(
                packet,
                now: DateTime.now().toUtc(),
              );
              if (message != null) _incoming.add(message);
            } on FormatException {
              _centralReassembler.clear();
            }
          });
      try {
        final mtu = await UniversalBle.requestMtu(transportId, 247);
        _packetBytes = (mtu - 3).clamp(20, 185);
      } on Object {
        _packetBytes = 20;
      }
      _connectedTransportId = transportId;
      _setState(BleProximityState.connected);
      return advertisement;
    } on ProximityTransportException {
      await disconnect();
      rethrow;
    } on Object {
      await disconnect();
      throw const ProximityTransportException('connection_failed');
    }
  }

  Future<void> send(Uint8List encryptedEnvelope) async {
    _ensureOpen();
    final transportId = _connectedTransportId;
    if (_state != BleProximityState.connected || transportId == null) {
      throw const ProximityTransportException('not_connected');
    }
    final packets = _frameCodec.fragment(
      encryptedEnvelope,
      packetBytes: _packetBytes,
    );
    for (final packet in packets) {
      await UniversalBle.write(
        transportId,
        cliptownProximityServiceUuid,
        cliptownInboundCharacteristicUuid,
        packet,
        withoutResponse: false,
        timeout: const Duration(seconds: 5),
      );
    }
  }

  Future<void> notifySubscribedPeers(Uint8List encryptedEnvelope) async {
    _ensureOpen();
    if (!_advertising) {
      throw const ProximityTransportException('not_advertising');
    }
    final subscribers = await UniversalBlePeripheral.getSubscribedClients(
      cliptownOutboundCharacteristicUuid,
    );
    if (subscribers.length != 1) {
      throw const ProximityTransportException('expected_one_subscribed_peer');
    }
    final maxLength = await UniversalBlePeripheral.getMaximumNotifyLength(
      subscribers.single,
    );
    final packetBytes = (maxLength ?? 20).clamp(20, 185);
    final packets = _frameCodec.fragment(
      encryptedEnvelope,
      packetBytes: packetBytes,
    );
    for (final packet in packets) {
      await UniversalBlePeripheral.updateCharacteristicValue(
        characteristicId: cliptownOutboundCharacteristicUuid,
        value: packet,
        deviceId: subscribers.single,
      );
    }
  }

  Future<void> disconnect() async {
    final transportId = _connectedTransportId;
    _connectedTransportId = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _centralReassembler.clear();
    if (transportId != null) {
      try {
        await UniversalBle.unsubscribe(
          transportId,
          cliptownProximityServiceUuid,
          cliptownOutboundCharacteristicUuid,
        );
      } on Object {
        // Continue teardown.
      }
      await UniversalBle.disconnect(transportId);
    }
    if (!_advertising && !_disposed) _setState(BleProximityState.idle);
  }

  Future<void> stopAdvertising() async {
    _advertising = false;
    try {
      await UniversalBlePeripheral.stopAdvertising();
    } on Object {
      // Continue cleanup.
    }
    try {
      await UniversalBlePeripheral.clearServices();
    } on Object {
      // Continue cleanup.
    }
    UniversalBlePeripheral.setReadRequestHandlers(null);
    UniversalBlePeripheral.setWriteRequestHandlers(null);
    _peripheralReassemblers
      ..forEach((_, value) => value.clear())
      ..clear();
    if (_connectedTransportId == null && !_disposed) {
      _setState(BleProximityState.idle);
    }
  }

  Future<void> stopForBackground() async {
    await stopDiscovery();
    await disconnect();
    await stopAdvertising();
    _peers.clear();
    notifyListeners();
  }

  void _setState(BleProximityState value) {
    if (_state == value) return;
    _state = value;
    notifyListeners();
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('BLE transport is disposed');
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stopForBackground());
    unawaited(_peripheralConnectionSubscription?.cancel());
    unawaited(_incoming.close());
    super.dispose();
  }
}
