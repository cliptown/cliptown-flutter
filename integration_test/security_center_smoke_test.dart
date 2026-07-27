import 'dart:typed_data';

import 'package:cliptown_app/security.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final class _DeviceSecurityService implements AccountSecurityService {
  var revoked = false;

  @override
  Future<List<DeviceSummary>> listDevices() async => [
        DeviceSummary(
          deviceId: 'device-mobile-smoke',
          deviceName: 'Mobile smoke device',
          platform: 'mobile',
          state: revoked
              ? DeviceLifecycleState.revoked
              : DeviceLifecycleState.active,
          deviceListRevision: 7,
          identityKeyFingerprint: Uint8List(32),
          localUnlock: const LocalUnlockPolicy(
            pinEnabled: true,
            biometricEnabled: true,
            passkeyEnabled: true,
            pinKdf: PinKdfPolicy(
              algorithm: 'argon2id-v1',
              memoryKib: 65536,
              iterations: 3,
              parallelism: 1,
              maxAttempts: 5,
              lockoutSeconds: 300,
            ),
          ),
          createdAt: DateTime.utc(2026, 7, 27),
          revokedAt: revoked ? DateTime.utc(2026, 7, 27, 1) : null,
        ),
      ];

  @override
  Future<List<RecoveryChannelSummary>> listRecoveryChannels() async => [
        RecoveryChannelSummary(
          channelId: 'channel-mobile-smoke',
          kind: RecoveryChannelKind.email,
          maskedDestination: 'a***@example.com',
          createdAt: DateTime.utc(2026, 7, 27),
          verifiedAt: DateTime.utc(2026, 7, 27),
        ),
      ];

  @override
  Future<void> revokeDevice(
    String deviceId, {
    required int expectedRevision,
  }) async {
    expect(deviceId, 'device-mobile-smoke');
    expect(expectedRevision, 7);
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders and revokes a trusted device on mobile', (tester) async {
    final service = _DeviceSecurityService();

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

    expect(find.text('Mobile smoke device'), findsOneWidget);
    expect(find.text('a***@example.com'), findsOneWidget);
    expect(find.textContaining('six-digit PIN'), findsOneWidget);

    await tester.tap(find.byTooltip('Revoke device'));
    await tester.pumpAndSettle();

    expect(service.revoked, isTrue);
    expect(find.byIcon(Icons.block), findsOneWidget);
  });
}
