import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cliptown_app/proximity/ble_frame_codec.dart';
import 'package:cliptown_app/proximity/proximity_contract.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 24, 18);

  test(
    'shared proximity certification fixture parses and keeps valid digests',
    () async {
      final fixture = jsonDecode(
        await File('test/fixtures/proximity_v1.json').readAsString(),
      ) as Map<String, Object?>;
      final advertisement = fixture['advertisement']! as Map<String, Object?>;
      expect(advertisement.keys.toSet(), <String>{
        'protocol',
        'service_uuid',
        'rotation_epoch',
        'rotating_id',
      });
      final envelopes = fixture['envelopes']! as List<Object?>;
      expect(envelopes, hasLength(2));
      for (final raw in envelopes.cast<Map<String, Object?>>()) {
        final envelope = ProximityEnvelope.fromJson(raw);
        expect(await envelope.hasValidDigest(), isTrue);
      }
    },
  );

  test('advertisements rotate without stable account metadata', () async {
    final secret = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final first = await createProximityAdvertisement(
      discoverySecret: secret,
      deviceKeyId: 'device-key-1',
      now: now,
    );
    final sameEpoch = await createProximityAdvertisement(
      discoverySecret: secret,
      deviceKeyId: 'device-key-1',
      now: now.add(const Duration(seconds: 30)),
    );
    final nextEpoch = await createProximityAdvertisement(
      discoverySecret: secret,
      deviceKeyId: 'device-key-1',
      now: now.add(const Duration(minutes: 2)),
    );
    expect(first.rotatingId, sameEpoch.rotatingId);
    expect(first.rotatingId, isNot(nextEpoch.rotatingId));
    expect(jsonEncode(first.toJson()), isNot(contains('device-key-1')));
    expect(first.displayName, matches(r'^CT-[A-Za-z0-9_-]{6}$'));
  });

  test('safety code binds the complete handshake transcript', () async {
    final initiator = Uint8List(32)..fillRange(0, 32, 1);
    final responder = Uint8List(32)..fillRange(0, 32, 2);
    final nonce = Uint8List(32)..fillRange(0, 32, 3);
    final code = await deriveProximitySafetyCode(
      initiatorEphemeralKey: initiator,
      responderEphemeralKey: responder,
      sessionNonce: nonce,
    );
    final changedNonce = Uint8List.fromList(nonce)..[0] = 4;
    final changed = await deriveProximitySafetyCode(
      initiatorEphemeralKey: initiator,
      responderEphemeralKey: responder,
      sessionNonce: changedNonce,
    );
    expect(code, matches(r'^\d{6}$'));
    expect(changed, isNot(code));
  });

  test('signed envelopes verify digest, recipient, time, and replay', () async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final envelope = await signedEnvelope(keyPair: keyPair, now: now);
    expect(await envelope.hasValidDigest(), isTrue);
    expect(
      await envelope.hasValidSignature(Uint8List.fromList(publicKey.bytes)),
      isTrue,
    );
    expect(
      envelope.toString(),
      isNot(contains(base64Url.encode(envelope.ciphertext))),
    );

    final replay = ProximityReplayGuard();
    expect(
      await envelope.verifyAndAccept(
        enrolledPublicKey: Uint8List.fromList(publicKey.bytes),
        replayGuard: replay,
        now: now,
        localDeviceId: recipientDeviceId,
        expectedSenderDeviceId: senderDeviceId,
      ),
      ProximityReplayDecision.accepted,
    );
    expect(
      await envelope.verifyAndAccept(
        enrolledPublicKey: Uint8List.fromList(publicKey.bytes),
        replayGuard: replay,
        now: now,
        localDeviceId: recipientDeviceId,
        expectedSenderDeviceId: senderDeviceId,
      ),
      ProximityReplayDecision.duplicate,
    );
  });

  test('unknown and credential-shaped fields fail closed', () async {
    final keyPair = await Ed25519().newKeyPair();
    final envelope = await signedEnvelope(keyPair: keyPair, now: now);
    for (final forbidden in <String>[
      'otp_code',
      'totp_seed',
      'access_token',
      'factor_proof',
      'aal',
    ]) {
      expect(
        () => ProximityEnvelope.fromJson(<String, Object?>{
          ...envelope.toJson(),
          forbidden: 'must-not-cross-radio',
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'wrong recipient, wrong sender, order, future, and expiry reject',
    () async {
      final keyPair = await Ed25519().newKeyPair();
      final first = await signedEnvelope(
        keyPair: keyPair,
        now: now,
        sequence: 2,
      );
      final publicKey = await keyPair.extractPublicKey();
      final publicKeyBytes = Uint8List.fromList(publicKey.bytes);
      final guard = ProximityReplayGuard();
      expect(
        await first.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: guard,
          now: now,
          localDeviceId: senderDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.wrongRecipient,
      );
      expect(
        await first.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: guard,
          now: now,
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: recipientDeviceId,
        ),
        ProximityReplayDecision.wrongSender,
      );
      expect(
        await first.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: guard,
          now: now,
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.accepted,
      );
      final lower = await signedEnvelope(
        keyPair: keyPair,
        now: now,
        sequence: 1,
        messageId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      );
      expect(
        await lower.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: guard,
          now: now,
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.outOfOrder,
      );
      final future = await signedEnvelope(
        keyPair: keyPair,
        now: now.add(const Duration(minutes: 1)),
        messageId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      expect(
        await future.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: guard,
          now: now,
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.fromFuture,
      );
      expect(
        await first.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: ProximityReplayGuard(),
          now: now.add(const Duration(minutes: 3)),
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.expired,
      );

      final unsigned = ProximityEnvelope(
        protocol: first.protocol,
        messageKind: first.messageKind,
        messageId: first.messageId,
        sessionId: first.sessionId,
        sequence: first.sequence,
        issuedAtUnixMs: first.issuedAtUnixMs,
        expiresAtUnixMs: first.expiresAtUnixMs,
        senderDeviceId: first.senderDeviceId,
        recipientDeviceId: first.recipientDeviceId,
        scope: first.scope,
        ciphertext: first.ciphertext,
        ciphertextSha256: first.ciphertextSha256,
        signingKeyId: first.signingKeyId,
        signature: Uint8List(64),
      );
      final signatureGuard = ProximityReplayGuard();
      expect(
        await unsigned.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: signatureGuard,
          now: now,
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.invalidSignature,
      );
      expect(
        await first.verifyAndAccept(
          enrolledPublicKey: publicKeyBytes,
          replayGuard: signatureGuard,
          now: now,
          localDeviceId: recipientDeviceId,
          expectedSenderDeviceId: senderDeviceId,
        ),
        ProximityReplayDecision.accepted,
      );
    },
  );

  test('pairing and each offer require separate bilateral consent', () {
    final gate = ProximityConsentGate();
    gate.beginCodeComparison();
    gate.confirmCode(local: true);
    expect(gate.ready, isFalse);
    gate.confirmCode(local: false);
    expect(gate.ready, isTrue);
    gate.presentOffer('offer-1');
    expect(gate.approveOnce('offer-2'), isFalse);
    expect(gate.approveOnce('offer-1'), isTrue);
    expect(gate.approveOnce('offer-1'), isFalse);
    gate.close();
    expect(gate.state, ProximitySessionState.closed);
  });

  test('BLE framing round trips out of order and rejects duplicates', () {
    final codec = BleFrameCodec(random: Random(7));
    final message = Uint8List.fromList(List<int>.generate(700, (i) => i % 251));
    final packets = codec.fragment(message, packetBytes: 64);
    final reassembler = BleFrameReassembler();
    Uint8List? output;
    for (final packet in packets.reversed) {
      output = reassembler.add(packet, now: now) ?? output;
    }
    expect(output, message);
    final duplicate = BleFrameReassembler();
    expect(duplicate.add(packets.first, now: now), isNull);
    expect(() => duplicate.add(packets.first, now: now), throwsFormatException);
  });
}

const String senderDeviceId = '22222222-2222-4222-8222-222222222222';
const String recipientDeviceId = '33333333-3333-4333-8333-333333333333';

Future<ProximityEnvelope> signedEnvelope({
  required KeyPair keyPair,
  required DateTime now,
  int sequence = 1,
  String messageId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
}) async {
  final ciphertext = Uint8List.fromList(utf8.encode('encrypted-clip-envelope'));
  final digest = await Sha256().hash(ciphertext);
  final unsigned = ProximityEnvelope(
    protocol: cliptownProximityProtocol,
    messageKind: ProximityMessageKind.clipboardOffer,
    messageId: messageId,
    sessionId: 'AQIDBAUGBwgJCgsMDQ4PEA',
    sequence: sequence,
    issuedAtUnixMs: now.millisecondsSinceEpoch,
    expiresAtUnixMs: now.add(const Duration(minutes: 2)).millisecondsSinceEpoch,
    senderDeviceId: senderDeviceId,
    recipientDeviceId: recipientDeviceId,
    scope: ProximityMessageKind.clipboardOffer.requiredScope,
    ciphertext: ciphertext,
    ciphertextSha256: digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(),
    signingKeyId: 'device-key-1',
    signature: Uint8List(64),
  );
  final signature = await Ed25519().sign(
    unsigned.signingBytes(),
    keyPair: keyPair,
  );
  return ProximityEnvelope(
    protocol: unsigned.protocol,
    messageKind: unsigned.messageKind,
    messageId: unsigned.messageId,
    sessionId: unsigned.sessionId,
    sequence: unsigned.sequence,
    issuedAtUnixMs: unsigned.issuedAtUnixMs,
    expiresAtUnixMs: unsigned.expiresAtUnixMs,
    senderDeviceId: unsigned.senderDeviceId,
    recipientDeviceId: unsigned.recipientDeviceId,
    scope: unsigned.scope,
    ciphertext: unsigned.ciphertext,
    ciphertextSha256: unsigned.ciphertextSha256,
    signingKeyId: unsigned.signingKeyId,
    signature: Uint8List.fromList(signature.bytes),
  );
}
