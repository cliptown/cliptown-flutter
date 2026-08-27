import 'dart:async';

import 'package:flutter/foundation.dart';

import '../history/capture_policy.dart';
import '../history/clip_item.dart';
import '../history/text_transform.dart';
import '../src/clip_store.dart';
import '../src/clipboard_snapshots.dart';
import 'clipboard_service.dart';

class ClipboardController extends ChangeNotifier {
  ClipboardController({
    required this.store,
    required this.service,
    this.automaticCaptureSupported = false,
  }) {
    _uiSubscription = _ui.stream.skip(1).listen((_) {
      if (!_disposed) notifyListeners();
    });
  }

  final ClipStore store;
  final ClipClipboardService service;
  final bool automaticCaptureSupported;
  final ClipboardSnapshotBus _ui = ClipboardSnapshotBus();
  StreamSubscription<ClipboardUiSnapshot>? _uiSubscription;
  bool _disposed = false;

  Stream<ClipboardUiSnapshot> get snapshots => _ui.stream;

  ClipboardUiSnapshot get snapshot => _ui.value;

  bool get monitoring => snapshot.monitoring;
  bool get busy => snapshot.busy;
  String? get errorMessage => snapshot.errorMessage;

  void _publish(ClipboardUiSnapshot next) => _ui.publish(next);

  Future<void> initialize() async {
    if (automaticCaptureSupported && store.captureEnabled) {
      await _startMonitoring();
    }
  }

  Future<void> setCaptureEnabled(bool enabled) async {
    if (store.vaultLocked) return;
    store.setCaptureEnabled(enabled);
    if (!automaticCaptureSupported) {
      return;
    }
    if (enabled) {
      await _startMonitoring();
    } else {
      await service.stop();
      _publish(snapshot.copyWith(monitoring: false));
    }
  }

  Future<CaptureResult> captureNow() => _run(() async {
    final snapshot = await service.read();
    if (snapshot == null) {
      store.setStatusMessage('No supported clipboard content found');
      return const CaptureResult.rejected(CaptureRejectionReason.empty);
    }
    return store.capture(snapshot);
  });

  Future<void> copy(ClipItem item, {TextTransform? transform}) =>
      _run(() async {
        String? override;
        if (transform != null) {
          final text = item.text;
          if (text == null) throw const FormatException('clip is not textual');
          override = transformText(text, transform);
        }
        await service.write(item, textOverride: override);
        await store.markUsed(item.id);
        store.setStatusMessage(
          transform == null
              ? 'Copied to the system clipboard'
              : '${transform.label} copied',
        );
      });

  Future<bool> copyNextQueued() => _run(() async {
    final item = store.takeNextQueued();
    if (item == null) {
      store.setStatusMessage('Paste queue is empty');
      return false;
    }
    await service.write(item);
    await store.markUsed(item.id);
    store.setStatusMessage('Copied next queued item');
    return true;
  });

  Future<void> _startMonitoring() async {
    try {
      await service.start((clipboardSnapshot) async {
        final result = await store.capture(clipboardSnapshot);
        if (!result.accepted &&
            result.rejectionReason == CaptureRejectionReason.vaultUnavailable) {
          await service.stop();
          _publish(snapshot.copyWith(monitoring: false));
        }
      });
      _publish(snapshot.copyWith(monitoring: true, errorMessage: null));
    } on Object {
      store.setCaptureEnabled(false);
      _publish(
        snapshot.copyWith(
          monitoring: false,
          errorMessage: 'Automatic clipboard capture is unavailable',
        ),
      );
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    _publish(snapshot.copyWith(busy: true, errorMessage: null));
    try {
      return await operation();
    } on Object {
      _publish(
        snapshot.copyWith(
          errorMessage:
              'Clipboard operation failed without exposing its contents',
        ),
      );
      rethrow;
    } finally {
      if (!_disposed) {
        _publish(snapshot.copyWith(busy: false));
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_uiSubscription?.cancel());
    unawaited(_ui.close());
    unawaited(service.stop());
    super.dispose();
  }
}
