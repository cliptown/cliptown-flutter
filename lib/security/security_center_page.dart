import 'package:flutter/material.dart';

import 'security_models.dart';
import 'security_services.dart';

final class SecurityCenterPage extends StatefulWidget {
  const SecurityCenterPage({
    super.key,
    required this.service,
    required this.onAddDevice,
    required this.onAddRecoveryChannel,
  });

  final AccountSecurityService service;
  final VoidCallback onAddDevice;
  final ValueChanged<RecoveryChannelKind> onAddRecoveryChannel;

  @override
  State<SecurityCenterPage> createState() => _SecurityCenterPageState();
}

final class _SecurityCenterPageState extends State<SecurityCenterPage> {
  late Future<
    ({
      List<DeviceSummary> devices,
      List<RecoveryChannelSummary> channels,
    })
  >
  _load;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _load = Future.wait<Object>([
      widget.service.listDevices(),
      widget.service.listRecoveryChannels(),
    ]).then(
      (values) => (
        devices: values[0] as List<DeviceSummary>,
        channels: values[1] as List<RecoveryChannelSummary>,
      ),
    );
  }

  Future<void> _revoke(DeviceSummary device) async {
    await widget.service.revokeDevice(
      device.deviceId,
      expectedRevision: device.deviceListRevision,
    );
    if (!mounted) return;
    setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security & devices')),
      body: FutureBuilder(
        future: _load,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: () => setState(_reload),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry loading security settings'),
              ),
            );
          }
          final data = snapshot.requireData;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Devices', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final device in data.devices)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text(device.deviceName),
                    subtitle: Text(
                      '${device.platform} · ${device.state.name}',
                    ),
                    trailing: device.canRevoke
                        ? IconButton(
                            tooltip: 'Revoke device',
                            onPressed: () => _revoke(device),
                            icon: const Icon(Icons.delete_outline),
                          )
                        : const Icon(Icons.block),
                  ),
                ),
              FilledButton.icon(
                onPressed: widget.onAddDevice,
                icon: const Icon(Icons.add_link),
                label: const Text('Add trusted device'),
              ),
              const SizedBox(height: 24),
              Text('Recovery', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              for (final channel in data.channels)
                ListTile(
                  leading: Icon(
                    channel.kind == RecoveryChannelKind.email
                        ? Icons.email_outlined
                        : Icons.sms_outlined,
                  ),
                  title: Text(channel.maskedDestination),
                  subtitle: Text(
                    channel.isVerified ? 'Verified' : 'Verification required',
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => widget.onAddRecoveryChannel(
                      RecoveryChannelKind.email,
                    ),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('Add backup email'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => widget.onAddRecoveryChannel(
                      RecoveryChannelKind.phone,
                    ),
                    icon: const Icon(Icons.sms_outlined),
                    label: const Text('Add phone OTP'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'Biometrics, passkeys, and a six-digit PIN unlock device-bound keys locally. '
                'They are never clipboard encryption keys and are not sent to ClipTown servers.',
              ),
            ],
          );
        },
      ),
    );
  }
}
