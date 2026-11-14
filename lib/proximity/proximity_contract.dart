import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String cliptownProximityProtocol = 'cliptown.proximity.v1';
const String cliptownProximityServiceUuid =
    'c11f7a00-7b9e-4d8a-9c3a-4b8a0d86e001';
const int maxProximityCiphertextBytes = 32 * 1024;
const int maxProximitySequence = 0x7fffffff;
const Duration maxProximityLifetime = Duration(minutes: 2);
const Duration maxProximityClockSkew = Duration(seconds: 30);
const Duration defaultAdvertisementRotation = Duration(minutes: 2);

enum ProximityMessageKind {
  pairingHello('pairing_hello', 'cliptown:device:pair'),
  clipboardOffer('clipboard_offer', 'cliptown:clipboard:import'),
  clipboardChunk('clipboard_chunk', 'cliptown:clipboard:import'),
  sharedAuthStepUp('shared_auth_step_up', 'shared-auth:step-up:relay');

  const ProximityMessageKind(this.wireName, this.requiredScope);

  final String wireName;
  final String requiredScope;

  static ProximityMessageKind parse(Object? value) {
    for (final kind in values) {
      if (kind.wireName == value) return kind;
    }
    throw const FormatException('unknown proximity message kind');
  }
}

final class ProximityAdvertisement {
  const ProximityAdvertisement({
    required this.protocol,
    required this.serviceUuid,
    required this.rotationEpoch,
    required this.rotatingId,
  });

  final String protocol;
  final String serviceUuid;
  final int rotationEpoch;
  final String rotatingId;

  String get displayName => 'CT-${rotatingId.substring(0, 6)}';

  void validate() {
    if (protocol != cliptownProximityProtocol ||
        serviceUuid.toLowerCase() != cliptownProximityServiceUuid ||
        rotationEpoch < 0 ||
        !RegExp(r'^[A-Za-z0-9_-]{12}$').hasMatch(rotatingId)) {
      throw const FormatException('invalid ClipTown proximity advertisement');
    }
  }

  Map<String, Object?> toJson() {
    validate();
    return <String, Object?>{
      'protocol': protocol,
      'service_uuid': serviceUuid,
      'rotation_epoch': rotationEpoch,
      'rotating_id': rotatingId,
    };
  }

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  factory ProximityAdvertisement.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const <String>{
      'protocol',
      'service_uuid',
      'rotation_epoch',
      'rotating_id',
    });
    final advertisement = ProximityAdvertisement(
      protocol: _requiredString(json, 'protocol'),
      serviceUuid: _requiredString(json, 'service_uuid').toLowerCase(),
      rotationEpoch: _requiredInt(json, 'rotation_epoch'),
      rotatingId: _requiredString(json, 'rotating_id'),
    );
    advertisement.validate();
    return advertisement;
  }

  factory ProximityAdvertisement.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 512) {
      throw const FormatException('invalid proximity advertisement size');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      throw const FormatException('advertisement is not valid UTF-8 JSON');
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('advertisement must be an object');
    }
    return ProximityAdvertisement.fromJson(_stringMap(decoded));
  }
}

Future<ProximityAdvertisement> createProximityAdvertisement({
  required Uint8List discoverySecret,
  required String deviceKeyId,
  required DateTime now,
  Duration rotation = defaultAdvertisementRotation,
}) async {
  if (discoverySecret.length < 32 ||
      !_boundedIdentifier(deviceKeyId, 128) ||
      rotation <= Duration.zero ||
      rotation > const Duration(minutes: 10)) {
    throw const FormatException('invalid advertisement derivation input');
  }
  final epoch = now.toUtc().millisecondsSinceEpoch ~/ rotation.inMilliseconds;
  final input = utf8.encode(
    '$cliptownProximityProtocol\u0000$cliptownProximityServiceUuid\u0000'
    '$deviceKeyId\u0000$epoch',
  );
  final mac = await Hmac.sha256().calculateMac(
    input,
    secretKey: SecretKey(discoverySecret),
  );
  final rotatingId = base64Url
      .encode(mac.bytes.sublist(0, 9))
      .replaceAll('=', '');
  return ProximityAdvertisement(
    protocol: cliptownProximityProtocol,
    serviceUuid: cliptownProximityServiceUuid,
    rotationEpoch: epoch,
    rotatingId: rotatingId,
  );
}

Future<String> deriveProximitySafetyCode({
  required Uint8List initiatorEphemeralKey,
  required Uint8List responderEphemeralKey,
  required Uint8List sessionNonce,
}) async {
  if (initiatorEphemeralKey.length < 16 ||
      responderEphemeralKey.length < 16 ||
      sessionNonce.length < 16) {
    throw const FormatException('safety-code transcript is incomplete');
  }
  final transcript = BytesBuilder(copy: false)
    ..add(utf8.encode('$cliptownProximityProtocol\u0000'))
    ..add(_lengthPrefix(initiatorEphemeralKey))
    ..add(_lengthPrefix(responderEphemeralKey))
    ..add(_lengthPrefix(sessionNonce));
  final digest = await Sha256().hash(transcript.takeBytes());
  final number =
      ((digest.bytes[0] << 24) |
          (digest.bytes[1] << 16) |
          (digest.bytes[2] << 8) |
          digest.bytes[3]) &
      0x7fffffff;
  return (number % 1000000).toString().padLeft(6, '0');
}

final class ProximityEnvelope {
  ProximityEnvelope({
    required this.protocol,
    required this.messageKind,
    required this.messageId,
    required this.sessionId,
    required this.sequence,
    required this.issuedAtUnixMs,
    required this.expiresAtUnixMs,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.scope,
    required Uint8List ciphertext,
    required this.ciphertextSha256,
    required this.signingKeyId,
    required Uint8List signature,
  }) : ciphertext = Uint8List.fromList(ciphertext),
       signature = Uint8List.fromList(signature);

  final String protocol;
  final ProximityMessageKind messageKind;
  final String messageId;
  final String sessionId;
  final int sequence;
  final int issuedAtUnixMs;
  final int expiresAtUnixMs;
  final String senderDeviceId;
  final String recipientDeviceId;
  final String scope;
  final Uint8List ciphertext;
  final String ciphertextSha256;
  final String signingKeyId;
  final Uint8List signature;

  void validateStructure() {
    if (protocol != cliptownProximityProtocol ||
        !_isUuid(messageId) ||
        !_base64UrlNoPadding(sessionId, min: 22, max: 86) ||
        sequence < 1 ||
        sequence > maxProximitySequence ||
        issuedAtUnixMs < 0 ||
        expiresAtUnixMs <= issuedAtUnixMs ||
        expiresAtUnixMs - issuedAtUnixMs >
            maxProximityLifetime.inMilliseconds ||
        !_isUuid(senderDeviceId) ||
        !_isUuid(recipientDeviceId) ||
        senderDeviceId == recipientDeviceId ||
        scope != messageKind.requiredScope ||
        ciphertext.isEmpty ||
        ciphertext.length > maxProximityCiphertextBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(ciphertextSha256) ||
        !_boundedIdentifier(signingKeyId, 128) ||
        signature.length != 64) {
      throw const FormatException('invalid ClipTown proximity envelope');
    }
  }

  void validateTime(DateTime now) {
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    if (issuedAtUnixMs > nowMs + maxProximityClockSkew.inMilliseconds ||
        expiresAtUnixMs <= nowMs) {
      throw const FormatException(
        'proximity envelope is expired or from future',
      );
    }
  }

  Future<bool> hasValidDigest() async {
    final digest = await Sha256().hash(ciphertext);
    return _hex(digest.bytes) == ciphertextSha256;
  }

  Future<bool> hasValidSignature(Uint8List enrolledPublicKey) async {
    if (enrolledPublicKey.length != 32) return false;
    return Ed25519().verify(
      signingBytes(),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          enrolledPublicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
  }

  Map<String, Object?> _unsignedJson() => <String, Object?>{
    'protocol': protocol,
    'message_kind': messageKind.wireName,
    'message_id': messageId,
    'session_id': sessionId,
    'sequence': sequence,
    'issued_at_unix_ms': issuedAtUnixMs,
    'expires_at_unix_ms': expiresAtUnixMs,
    'sender_device_id': senderDeviceId,
    'recipient_device_id': recipientDeviceId,
    'scope': scope,
    'ciphertext': base64Url.encode(ciphertext).replaceAll('=', ''),
    'ciphertext_sha256': ciphertextSha256,
    'signing_key_id': signingKeyId,
  };

  Uint8List signingBytes() =>
      Uint8List.fromList(utf8.encode(jsonEncode(_unsignedJson())));

  Map<String, Object?> toJson() {
    validateStructure();
    return <String, Object?>{
      ..._unsignedJson(),
      'signature': base64Url.encode(signature).replaceAll('=', ''),
    };
  }

  Uint8List encode() {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
    if (bytes.length > 48 * 1024) {
      throw const FormatException('encoded proximity envelope is too large');
    }
    return bytes;
  }

  factory ProximityEnvelope.fromBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 48 * 1024) {
      throw const FormatException('invalid proximity envelope size');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      throw const FormatException('proximity envelope is not UTF-8 JSON');
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const FormatException('proximity envelope must be an object');
    }
    return ProximityEnvelope.fromJson(_stringMap(decoded));
  }

  factory ProximityEnvelope.fromJson(Map<String, Object?> json) {
    _requireExactKeys(json, const <String>{
      'protocol',
      'message_kind',
      'message_id',
      'session_id',
      'sequence',
      'issued_at_unix_ms',
      'expires_at_unix_ms',
      'sender_device_id',
      'recipient_device_id',
      'scope',
      'ciphertext',
      'ciphertext_sha256',
      'signing_key_id',
      'signature',
    });
    final envelope = ProximityEnvelope(
      protocol: _requiredString(json, 'protocol'),
      messageKind: ProximityMessageKind.parse(json['message_kind']),
      messageId: _requiredString(json, 'message_id'),
      sessionId: _requiredString(json, 'session_id'),
      sequence: _requiredInt(json, 'sequence'),
      issuedAtUnixMs: _requiredInt(json, 'issued_at_unix_ms'),
      expiresAtUnixMs: _requiredInt(json, 'expires_at_unix_ms'),
      senderDeviceId: _requiredString(json, 'sender_device_id'),
      recipientDeviceId: _requiredString(json, 'recipient_device_id'),
      scope: _requiredString(json, 'scope'),
      ciphertext: _decodeBase64Url(_requiredString(json, 'ciphertext')),
      ciphertextSha256: _requiredString(json, 'ciphertext_sha256'),
      signingKeyId: _requiredString(json, 'signing_key_id'),
      signature: _decodeBase64Url(_requiredString(json, 'signature')),
    );
    envelope.validateStructure();
    return envelope;
  }

  /// Verifies the cryptographic and contextual boundary before committing any
  /// replay state. Callers cannot accidentally let an unsigned or tampered
  /// packet consume a message id or advance a session sequence.
  Future<ProximityReplayDecision> verifyAndAccept({
    required Uint8List enrolledPublicKey,
    required ProximityReplayGuard replayGuard,
    required DateTime now,
    required String localDeviceId,
    required String expectedSenderDeviceId,
  }) async {
    try {
      validateStructure();
    } on FormatException {
      return ProximityReplayDecision.invalid;
    }
    if (!await hasValidDigest()) {
      return ProximityReplayDecision.invalidDigest;
    }
    if (!await hasValidSignature(enrolledPublicKey)) {
      return ProximityReplayDecision.invalidSignature;
    }
    return replayGuard._acceptVerified(
      this,
      now: now,
      localDeviceId: localDeviceId,
      expectedSenderDeviceId: expectedSenderDeviceId,
    );
  }

  @override
  String toString() =>
      'ProximityEnvelope(kind: ${messageKind.wireName}, '
      'messageId: $messageId, ciphertext: <redacted>, signature: <redacted>)';
}

enum ProximityReplayDecision {
  accepted,
  duplicate,
  outOfOrder,
  expired,
  fromFuture,
  wrongRecipient,
  wrongSender,
  invalidDigest,
  invalidSignature,
  invalid,
}

final class ProximityReplayGuard {
  ProximityReplayGuard({this.capacity = 512}) {
    if (capacity < 16 || capacity > 4096) {
      throw ArgumentError.value(capacity, 'capacity', 'must be 16..4096');
    }
  }

  final int capacity;
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  final Map<String, int> _lastSequence = <String, int>{};

  ProximityReplayDecision _acceptVerified(
    ProximityEnvelope envelope, {
    required DateTime now,
    required String localDeviceId,
    required String expectedSenderDeviceId,
  }) {
    try {
      envelope.validateStructure();
    } on FormatException {
      return ProximityReplayDecision.invalid;
    }
    final nowMs = now.toUtc().millisecondsSinceEpoch;
    if (envelope.recipientDeviceId != localDeviceId) {
      return ProximityReplayDecision.wrongRecipient;
    }
    if (envelope.senderDeviceId != expectedSenderDeviceId) {
      return ProximityReplayDecision.wrongSender;
    }
    if (envelope.issuedAtUnixMs >
        nowMs + maxProximityClockSkew.inMilliseconds) {
      return ProximityReplayDecision.fromFuture;
    }
    if (envelope.expiresAtUnixMs <= nowMs) {
      return ProximityReplayDecision.expired;
    }
    if (_seen.contains(envelope.messageId)) {
      return ProximityReplayDecision.duplicate;
    }
    final sessionKey =
        '${envelope.senderDeviceId}\u0000'
        '${envelope.recipientDeviceId}\u0000${envelope.sessionId}';
    if (envelope.sequence <= (_lastSequence[sessionKey] ?? 0)) {
      return ProximityReplayDecision.outOfOrder;
    }
    if (!_lastSequence.containsKey(sessionKey) &&
        _lastSequence.length >= capacity) {
      _lastSequence.remove(_lastSequence.keys.first);
    }
    _lastSequence[sessionKey] = envelope.sequence;
    _seen.add(envelope.messageId);
    while (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return ProximityReplayDecision.accepted;
  }

  void clear() {
    _seen.clear();
    _lastSequence.clear();
  }
}

enum ProximitySessionState {
  idle,
  comparingCode,
  ready,
  awaitingConsent,
  closed,
}

final class ProximityConsentGate {
  ProximitySessionState _state = ProximitySessionState.idle;
  bool _localCodeAccepted = false;
  bool _remoteCodeAccepted = false;
  String? _pendingOfferId;
  final Set<String> _consumedOfferIds = <String>{};

  ProximitySessionState get state => _state;
  bool get ready => _state == ProximitySessionState.ready;

  void beginCodeComparison() {
    if (_state != ProximitySessionState.idle) {
      throw StateError('a proximity session is already active');
    }
    _state = ProximitySessionState.comparingCode;
  }

  void confirmCode({required bool local}) {
    if (_state != ProximitySessionState.comparingCode) {
      throw StateError('safety code is not awaiting comparison');
    }
    if (local) {
      _localCodeAccepted = true;
    } else {
      _remoteCodeAccepted = true;
    }
    if (_localCodeAccepted && _remoteCodeAccepted) {
      _state = ProximitySessionState.ready;
    }
  }

  void presentOffer(String offerId) {
    if (!ready || !_boundedIdentifier(offerId, 128)) {
      throw StateError('offer requires a mutually verified session');
    }
    if (_consumedOfferIds.contains(offerId)) {
      throw StateError('offer was already consumed');
    }
    _pendingOfferId = offerId;
    _state = ProximitySessionState.awaitingConsent;
  }

  bool approveOnce(String offerId) {
    if (_state != ProximitySessionState.awaitingConsent ||
        _pendingOfferId != offerId ||
        _consumedOfferIds.contains(offerId)) {
      return false;
    }
    _consumedOfferIds.add(offerId);
    _pendingOfferId = null;
    _state = ProximitySessionState.ready;
    return true;
  }

  void denyOffer() {
    if (_state == ProximitySessionState.awaitingConsent) {
      _pendingOfferId = null;
      _state = ProximitySessionState.ready;
    }
  }

  void close() {
    _pendingOfferId = null;
    _localCodeAccepted = false;
    _remoteCodeAccepted = false;
    _state = ProximitySessionState.closed;
  }
}

Uint8List _decodeBase64Url(String value) {
  if (value.isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw const FormatException('value is not unpadded base64url');
  }
  try {
    return Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
  } on FormatException {
    throw const FormatException('value is not unpadded base64url');
  }
}

bool _base64UrlNoPadding(String value, {required int min, required int max}) =>
    value.length >= min &&
    value.length <= max &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

bool _boundedIdentifier(String value, int max) =>
    value.isNotEmpty &&
    value.length <= max &&
    RegExp(r'^[A-Za-z0-9._:@/-]+$').hasMatch(value);

bool _isUuid(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

String _hex(List<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

Uint8List _lengthPrefix(List<int> bytes) {
  final prefix = ByteData(4)..setUint32(0, bytes.length, Endian.big);
  return Uint8List.fromList(<int>[...prefix.buffer.asUint8List(), ...bytes]);
}

void _requireExactKeys(Map<String, Object?> json, Set<String> expected) {
  if (json.length != expected.length || !json.keys.every(expected.contains)) {
    throw const FormatException('object contains missing or unknown fields');
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

int _requiredInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw FormatException('$key must be an integer');
  return value;
}

Map<String, Object?> _stringMap(Map<Object?, Object?> value) {
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw const FormatException('object keys must be strings');
    }
    result[entry.key! as String] = entry.value;
  }
  return result;
}
