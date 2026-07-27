import 'dart:typed_data';

enum DeviceLifecycleState { pending, active, suspended, revoked }
enum RecoveryChannelKind { email, phone }
enum RecoveryPurpose {
  addDevice,
  accountRecovery,
  stepUp,
  changeChannel,
  revokeDevice,
}

final class PinKdfPolicy {
  const PinKdfPolicy({
    required this.algorithm,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.maxAttempts,
    required this.lockoutSeconds,
  });

  final String algorithm;
  final int memoryKib;
  final int iterations;
  final int parallelism;
  final int maxAttempts;
  final int lockoutSeconds;

  void validate() {
    if (algorithm != 'argon2id-v1' && algorithm != 'scrypt-v1') {
      throw const FormatException('unsupported PIN KDF policy');
    }
    if (memoryKib < 8192 || memoryKib > 1048576) {
      throw const FormatException('PIN KDF memory is outside supported bounds');
    }
    if (iterations < 1 || iterations > 20 || parallelism < 1 || parallelism > 8) {
      throw const FormatException('PIN KDF cost is outside supported bounds');
    }
    if (maxAttempts < 3 || maxAttempts > 20 || lockoutSeconds < 1 || lockoutSeconds > 86400) {
      throw const FormatException('PIN throttling is outside supported bounds');
    }
  }
}

/// Local capability/policy only. The PIN and biometric templates are absent.
final class LocalUnlockPolicy {
  const LocalUnlockPolicy({
    required this.pinEnabled,
    required this.biometricEnabled,
    required this.passkeyEnabled,
    this.pinKdf,
  });

  final bool pinEnabled;
  final bool biometricEnabled;
  final bool passkeyEnabled;
  final PinKdfPolicy? pinKdf;

  void validate() {
    if (pinEnabled && pinKdf == null) {
      throw const FormatException('PIN unlock requires a bounded KDF policy');
    }
    pinKdf?.validate();
  }
}

final class DeviceSummary {
  DeviceSummary({
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    required this.state,
    required this.deviceListRevision,
    required Uint8List identityKeyFingerprint,
    required this.localUnlock,
    required this.createdAt,
    this.verifiedAt,
    this.lastSeenAt,
    this.revokedAt,
  }) : identityKeyFingerprint = Uint8List.fromList(identityKeyFingerprint);

  final String deviceId;
  final String deviceName;
  final String platform;
  final DeviceLifecycleState state;
  final int deviceListRevision;
  final Uint8List identityKeyFingerprint;
  final LocalUnlockPolicy localUnlock;
  final DateTime createdAt;
  final DateTime? verifiedAt;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;

  bool get canRevoke => state != DeviceLifecycleState.revoked;

  void validate() {
    requirePortableIdentifier(deviceId, name: 'device_id', maxLength: 128);
    if (deviceName.trim().isEmpty || deviceName.length > 120) {
      throw const FormatException('device_name is empty or too long');
    }
    if (platform.trim().isEmpty || platform.length > 64) {
      throw const FormatException('platform is empty or too long');
    }
    if (deviceListRevision < 1) {
      throw const FormatException('device_list_revision must be positive');
    }
    if (identityKeyFingerprint.isEmpty || identityKeyFingerprint.length > 128) {
      throw const FormatException('identity-key fingerprint is invalid');
    }
    localUnlock.validate();
    if (state == DeviceLifecycleState.revoked && revokedAt == null) {
      throw const FormatException('revoked devices require revoked_at');
    }
    if (state != DeviceLifecycleState.revoked && revokedAt != null) {
      throw const FormatException('only revoked devices may carry revoked_at');
    }
  }
}

bool deviceTransitionAllowed(DeviceLifecycleState from, DeviceLifecycleState to) {
  if (from == to) return true;
  return switch (from) {
    DeviceLifecycleState.pending =>
      to == DeviceLifecycleState.active ||
          to == DeviceLifecycleState.suspended ||
          to == DeviceLifecycleState.revoked,
    DeviceLifecycleState.active =>
      to == DeviceLifecycleState.suspended || to == DeviceLifecycleState.revoked,
    DeviceLifecycleState.suspended =>
      to == DeviceLifecycleState.active || to == DeviceLifecycleState.revoked,
    DeviceLifecycleState.revoked => false,
  };
}

final class RecoveryChannelSummary {
  const RecoveryChannelSummary({
    required this.channelId,
    required this.kind,
    required this.maskedDestination,
    required this.createdAt,
    this.verifiedAt,
    this.disabledAt,
  });

  final String channelId;
  final RecoveryChannelKind kind;
  final String maskedDestination;
  final DateTime createdAt;
  final DateTime? verifiedAt;
  final DateTime? disabledAt;

  bool get isVerified => verifiedAt != null && disabledAt == null;
}

final class RecoveryChallenge {
  const RecoveryChallenge({
    required this.challengeId,
    required this.channelId,
    required this.purpose,
    required this.expiresAt,
    required this.remainingAttempts,
  });

  final String challengeId;
  final String channelId;
  final RecoveryPurpose purpose;
  final DateTime expiresAt;
  final int remainingAttempts;

  void validate(DateTime now) {
    requirePortableIdentifier(challengeId, name: 'challenge_id', maxLength: 128);
    requirePortableIdentifier(channelId, name: 'channel_id', maxLength: 128);
    if (!expiresAt.isAfter(now)) {
      throw const FormatException('recovery challenge is expired');
    }
    if (remainingAttempts < 0 || remainingAttempts > 10) {
      throw const FormatException('remaining_attempts is outside supported bounds');
    }
  }
}

bool recoveryCodeIsWellFormed(String code) =>
    code.length >= 6 &&
    code.length <= 10 &&
    code.codeUnits.every((unit) => unit >= 48 && unit <= 57);

void requirePortableIdentifier(
  String value, {
  required String name,
  required int maxLength,
}) {
  if (value.isEmpty || value.length > maxLength) {
    throw FormatException('$name is empty or too long');
  }
  for (final unit in value.codeUnits) {
    final alphanumeric = (unit >= 48 && unit <= 57) ||
        (unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122);
    if (!alphanumeric && unit != 45 && unit != 46 && unit != 58 && unit != 95) {
      throw FormatException('$name must use portable ASCII characters');
    }
  }
}
