import 'dart:typed_data';

import 'security_models.dart';

/// Production implementations delegate to a reviewed Signal Protocol library
/// through FFI/platform bindings. This interface intentionally contains no
/// cryptographic primitive implementation.
abstract interface class SignalProtocolProvider {
  Future<Uint8List> publishPublicPreKeyBundle();
  Future<String> safetyNumberForDevice(String deviceId);
  Future<Uint8List> encryptForDevice({
    required String recipientDeviceId,
    required Uint8List associatedData,
    required Uint8List plaintext,
  });
  Future<Uint8List> decryptFromDevice({
    required String senderDeviceId,
    required Uint8List associatedData,
    required Uint8List ciphertext,
  });
  Future<void> revokeSession(String deviceId);
}

/// Device-bound secure storage and platform authentication boundary.
///
/// Implementations use Keychain/Secure Enclave, Android Keystore and
/// BiometricPrompt, Windows Hello, or platform equivalents. Callers must never
/// log, sync, or persist the raw PIN outside the provider.
abstract interface class LocalKeyGuard {
  Future<bool> get biometricAvailable;
  Future<bool> get passkeyAvailable;

  Future<void> createRandomAccountMasterKey();
  Future<void> configurePin(String sixDigitPin, PinKdfPolicy policy);
  Future<void> unlockWithPin(String sixDigitPin);
  Future<void> unlockWithBiometric();
  Future<void> lock();
  Future<void> destroyLocalKeys();
}

abstract interface class AccountSecurityService {
  Future<List<DeviceSummary>> listDevices();
  Future<void> beginTrustedDeviceEnrollment({
    required String deviceName,
    required String platform,
    required Uint8List publicPreKeyBundle,
    required LocalUnlockPolicy localUnlock,
  });
  Future<void> approveDevice(
    String deviceId, {
    required int expectedRevision,
  });
  Future<void> suspendDevice(
    String deviceId, {
    required int expectedRevision,
  });
  Future<void> revokeDevice(
    String deviceId, {
    required int expectedRevision,
  });

  Future<List<RecoveryChannelSummary>> listRecoveryChannels();
  Future<RecoveryChannelSummary> addRecoveryChannel({
    required RecoveryChannelKind kind,
    required String destination,
  });
  Future<void> removeRecoveryChannel(String channelId);
  Future<RecoveryChallenge> requestChallenge(
    String channelId,
    RecoveryPurpose purpose,
  );
  Future<void> verifyChallenge(String challengeId, String code);
}
