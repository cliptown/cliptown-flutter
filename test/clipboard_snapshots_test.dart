import 'package:cliptown_app/src/clipboard_snapshots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('duplicate clipboard UI publishes are coalesced', () async {
    final bus = ClipboardSnapshotBus();
    addTearDown(bus.close);

    final events = expectLater(
      bus.stream,
      emitsInOrder(<ClipboardUiSnapshot>[
        const ClipboardUiSnapshot(busy: false, monitoring: false),
        const ClipboardUiSnapshot(busy: true, monitoring: false),
        const ClipboardUiSnapshot(
          busy: false,
          monitoring: true,
          errorMessage: 'paused',
        ),
      ]),
    );

    bus.publish(const ClipboardUiSnapshot(busy: false, monitoring: false));
    bus.publish(const ClipboardUiSnapshot(busy: true, monitoring: false));
    bus.publish(const ClipboardUiSnapshot(busy: true, monitoring: false));
    bus.publish(
      const ClipboardUiSnapshot(
        busy: false,
        monitoring: true,
        errorMessage: 'paused',
      ),
    );

    await events;
  });
}
