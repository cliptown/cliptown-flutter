import 'dart:typed_data';

import 'package:cliptown_app/security.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class FakeSecurityService implements AccountSecurityService {
  var revoked = false;

  @override
  Future<List<DeviceSummary>> listDevices() async => [
    DeviceSummary(
      deviceId: 'device-a',
      deviceName: 'Alex phone',
      platform: 'android',
      state: revoked
          ? DeviceLifecycleState.revoked
          : DeviceLifecycleState.active,
      deviceListRevision: 3,
      identityKeyFingerprint: Uint8List(32),
      localUnlock: const LocalUnlockPolicy(
        pinEnabled: false,
        biometricEnabled: true,
        passkeyEnabled: true,
      ),
      createdAt: DateTime.utc(2026, 1, 1),
      revokedAt: revoked ? DateTime.utc(2026, 1, 2) : null,
    ),
  ];

  @override
  Future<List<RecoveryChannelSummary>> listRecoveryChannels() async => [
    RecoveryChannelSummary(
      channelId: 'channel-a',
      kind: RecoveryChannelKind.email,
      maskedDestination: 'a***@example.com',
      createdAt: DateTime.utc(2026, 1, 1),
      verifiedAt: DateTime.utc(2026, 1, 1),
    ),
  ];

  @override
  Future<void> revokeDevice(
    String deviceId, {
    required int expectedRevision,
  }) async {
    expect(deviceId, 'device-a');
    expect(expectedRevision, 3);
    revoked = true;
  }

  @override
  Future<void> approveDevice(
    String deviceId, {
    required int expectedRevision,
  }) async {}

  @override
  Future<void> beginTrustedDeviceEnrollment({
    required String deviceName,
    required String platform,
    required Uint8List publicPreKeyBundle,
    required LocalUnlockPolicy localUnlock,
  }) async {}

  @override
  Future<RecoveryChannelSummary> addRecoveryChannel({
    required RecoveryChannelKind kind,
    required String destination,
  }) => throw UnimplementedError();

  @override
  Future<void> removeRecoveryChannel(String channelId) async {}

  @override
  Future<RecoveryChallenge> requestChallenge(
    String channelId,
    RecoveryPurpose purpose,
  ) => throw UnimplementedError();

  @override
  Future<void> suspendDevice(
    String deviceId, {
    required int expectedRevision,
  }) async {}

  @override
  Future<void> verifyChallenge(String challengeId, String code) async {}
}

void main() {
  testWidgets('security center lists and revokes devices', (tester) async {
    final service = FakeSecurityService();
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityCenterPage(
          service: service,
          onAddDevice: () {},
          onAddRecoveryChannel: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alex phone'), findsOneWidget);
    expect(find.text('a***@example.com'), findsOneWidget);
    await tester.tap(find.byTooltip('Revoke device'));
    await tester.pumpAndSettle();
    expect(service.revoked, isTrue);
    expect(find.byIcon(Icons.block), findsOneWidget);
  });
}
