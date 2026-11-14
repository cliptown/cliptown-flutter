import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'ble_proximity_transport.dart';
import 'proximity_contract.dart';

final class NearbySharePage extends StatefulWidget {
  const NearbySharePage({super.key, this.transport});

  final ClipTownBleTransport? transport;

  @override
  State<NearbySharePage> createState() => _NearbySharePageState();
}

final class _NearbySharePageState extends State<NearbySharePage>
    with WidgetsBindingObserver {
  late final ClipTownBleTransport transport =
      widget.transport ?? ClipTownBleTransport();
  late final bool ownsTransport = widget.transport == null;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    transport.addListener(_changed);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      transport.stopForBackground();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } on ProximityTransportException catch (exception) {
      if (mounted) setState(() => error = exception.code);
    } on Object {
      if (mounted) setState(() => error = 'unexpected_transport_failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _advertise() async {
    final random = Random.secure();
    final secret = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    final advertisement = await createProximityAdvertisement(
      discoverySecret: secret,
      deviceKeyId: 'unenrolled-foreground-session',
      now: DateTime.now().toUtc(),
    );
    await transport.startAdvertising(advertisement);
  }

  Future<void> _inspect(BlePeerCandidate peer) async {
    await _run(() async {
      final advertisement = await transport.connectAndReadAdvertisement(
        peer.transportId,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Nearby device found'),
          content: Text(
            'Rotating ID ${advertisement.rotatingId}. No clipboard data was '
            'transferred. Complete account device enrollment and compare the '
            'six-digit handshake code before approving any one-use offer.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      await transport.disconnect();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    transport.removeListener(_changed);
    transport.stopForBackground();
    if (ownsTransport) transport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nearby encrypted sharing')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            const Text(
              'Bluetooth is an offline transport, not an authentication '
              'factor. Discovery is foreground-only and every transfer needs '
              'a verified device, matching code, and separate consent.',
              key: Key('nearby-security-boundary'),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                FilledButton.icon(
                  key: const Key('nearby-find-devices'),
                  onPressed: busy ? null : () => _run(transport.startDiscovery),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('Find devices'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('nearby-advertise'),
                  onPressed: busy ? null : () => _run(_advertise),
                  icon: const Icon(Icons.bluetooth_connected),
                  label: const Text('Make discoverable'),
                ),
                OutlinedButton.icon(
                  key: const Key('nearby-stop'),
                  onPressed: busy
                      ? null
                      : () => _run(transport.stopForBackground),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Radio state: ${transport.state.name}'),
            if (error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                'Nearby sharing is unavailable ($error). Nothing was sent.',
                key: const Key('nearby-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            if (transport.peers.isEmpty)
              const Text('No ClipTown devices discovered yet.')
            else
              ...transport.peers.map(
                (peer) => Card(
                  child: ListTile(
                    title: Text(peer.displayName),
                    subtitle: Text(
                      peer.rssi == null
                          ? 'Signal unavailable'
                          : 'Signal ${peer.rssi} dBm',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: busy ? null : () => _inspect(peer),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            const Text(
              'Shared Auth / 3FA requests remain opaque and require the normal '
              'authenticated Shared Auth channel. If that authority is '
              'offline, step-up stays unavailable even when Bluetooth works.',
            ),
          ],
        ),
      ),
    );
  }
}
