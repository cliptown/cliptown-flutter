import 'package:cliptown_app/security.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const pinPolicy = LocalUnlockPolicy(
    pinEnabled: true,
    biometricEnabled: true,
    passkeyEnabled: true,
    pinKdf: PinKdfPolicy(
      algorithm: 'argon2id-v1',
      memoryKib: 65536,
      iterations: 3,
      parallelism: 1,
      maxAttempts: 10,
      lockoutSeconds: 60,
    ),
  );

  test('PIN is modeled only as local KDF and throttling policy', () {
    expect(pinPolicy.validate, returnsNormally);
    expect(
      const LocalUnlockPolicy(
        pinEnabled: true,
        biometricEnabled: false,
        passkeyEnabled: false,
      ).validate,
      throwsFormatException,
    );
  });

  test('revoked device state is terminal', () {
    expect(
      deviceTransitionAllowed(
        DeviceLifecycleState.pending,
        DeviceLifecycleState.active,
      ),
      isTrue,
    );
    expect(
      deviceTransitionAllowed(
        DeviceLifecycleState.active,
        DeviceLifecycleState.suspended,
      ),
      isTrue,
    );
    expect(
      deviceTransitionAllowed(
        DeviceLifecycleState.revoked,
        DeviceLifecycleState.active,
      ),
      isFalse,
    );
  });

  test('recovery OTP is a bounded numeric challenge', () {
    expect(recoveryCodeIsWellFormed('123456'), isTrue);
    expect(recoveryCodeIsWellFormed('12 456'), isFalse);
    expect(recoveryCodeIsWellFormed('12345'), isFalse);
  });

  test('encrypted upload plan uses contiguous randomized R2 keys', () {
    var counter = 0;
    final plan = planEncryptedUpload(
      objectId: 'object-1',
      plaintextLength: 150000,
      chunkSize: minEncryptedChunkSize,
      randomSegment: () =>
          'randomized-storage-segment-${counter++}'.padRight(32, 'x'),
    );
    expect(plan.chunks.length, 3);
    expect(plan.chunks.map((chunk) => chunk.index), orderedEquals([0, 1, 2]));
    expect(
      plan.chunks.map((chunk) => chunk.randomizedStorageKey).toSet().length,
      3,
    );
    expect(
      plan.chunks.every(
        (chunk) => !chunk.randomizedStorageKey.contains('object-1'),
      ),
      isTrue,
    );
  });
}
