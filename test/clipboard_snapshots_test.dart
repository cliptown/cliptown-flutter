import 'package:cliptown_app/src/clipboard_snapshots.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pure reducer counts concurrent operations without an early idle', () {
    const initial = ClipboardUiSnapshot.idle();

    final oneRunning = reduceClipboardUiSnapshot(
      initial,
      const ClipboardOperationStarted(),
    );
    final twoRunning = reduceClipboardUiSnapshot(
      oneRunning,
      const ClipboardOperationStarted(),
    );
    final oneFinished = reduceClipboardUiSnapshot(
      twoRunning,
      const ClipboardOperationFinished(),
    );

    expect(initial.busy, isFalse);
    expect(twoRunning.activeOperations, 2);
    expect(oneFinished.activeOperations, 1);
    expect(oneFinished.busy, isTrue);
    expect(
      reduceClipboardUiSnapshot(
        oneFinished,
        const ClipboardOperationFinished(),
      ).busy,
      isFalse,
    );
    expect(initial, const ClipboardUiSnapshot.idle());
  });

  test(
    'finishing while idle is idempotent and cannot create invalid state',
    () {
      const initial = ClipboardUiSnapshot.idle();

      expect(
        identical(
          reduceClipboardUiSnapshot(
            initial,
            const ClipboardOperationFinished(),
          ),
          initial,
        ),
        isTrue,
      );
    },
  );

  test('failure transitions can fail closed without lifecycle mutation', () {
    final monitoring = reduceClipboardUiSnapshot(
      const ClipboardUiSnapshot.idle(),
      const ClipboardMonitoringChanged(true),
    );
    final failed = reduceClipboardUiSnapshot(
      monitoring,
      const ClipboardUiFailed('native watcher failed', stopMonitoring: true),
    );

    expect(failed.monitoring, isFalse);
    expect(failed.errorMessage, 'native watcher failed');
  });

  test('RxDart bus replays and coalesces reducer snapshots', () async {
    final bus = ClipboardSnapshotBus();
    addTearDown(bus.close);

    final running = reduceClipboardUiSnapshot(
      const ClipboardUiSnapshot.idle(),
      const ClipboardOperationStarted(),
    );
    final monitoring = reduceClipboardUiSnapshot(
      running,
      const ClipboardMonitoringChanged(true),
    );
    final events = expectLater(
      bus.stream,
      emitsInOrder(<ClipboardUiSnapshot>[
        const ClipboardUiSnapshot.idle(),
        running,
        monitoring,
      ]),
    );

    bus.dispatch(const ClipboardOperationStarted());
    bus.dispatch(const ClipboardMonitoringChanged(false));
    bus.dispatch(const ClipboardMonitoringChanged(true));

    await events;
  });

  test('RxDart selectors emit only distinct derived values', () async {
    final bus = ClipboardSnapshotBus();
    addTearDown(bus.close);

    final busyValues = expectLater(
      bus.busyChanges,
      emitsInOrder(<bool>[false, true, false]),
    );

    bus.dispatch(const ClipboardMonitoringChanged(true));
    bus.dispatch(const ClipboardOperationStarted());
    bus.dispatch(const ClipboardMonitoringChanged(false));
    bus.dispatch(const ClipboardOperationFinished());

    await busyValues;
  });
}
