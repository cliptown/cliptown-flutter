import 'dart:async';

import 'package:flutter/foundation.dart';

import '../history/capture_policy.dart';
import '../history/clip_item.dart';
import '../history/text_transform.dart';
import '../src/clip_store.dart';
import 'clipboard_service.dart';

class ClipboardController extends ChangeNotifier {
  ClipboardController({
    required this.store,
    required this.service,
    this.automaticCaptureSupported = false,
  });

  final ClipStore store;
  final ClipClipboardService service;
  final bool automaticCaptureSupported;
  bool _disposed = false;
  bool _busy = false;
  String? _errorMessage;

  bool get monitoring => service.monitoring;
  bool get busy => _busy;
  String? get errorMessage => _errorMessage;

  Future<void> initialize() async {
    if (automaticCaptureSupported && store.captureEnabled) {
      await _startMonitoring();
    }
  }

  Future<void> setCaptureEnabled(bool enabled) async {
    if (store.vaultLocked) return;
    store.setCaptureEnabled(enabled);
    if (!automaticCaptureSupported) {
      notifyListeners();
      return;
    }
    if (enabled) {
      await _startMonitoring();
    } else {
      await service.stop();
      notifyListeners();
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
      await service.start((snapshot) async {
        final result = await store.capture(snapshot);
        if (!result.accepted &&
            result.rejectionReason == CaptureRejectionReason.vaultUnavailable) {
          await service.stop();
        }
      });
      _errorMessage = null;
    } on Object {
      store.setCaptureEnabled(false);
      _errorMessage = 'Automatic clipboard capture is unavailable';
    }
    notifyListeners();
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      return await operation();
    } on Object {
      _errorMessage =
          'Clipboard operation failed without exposing its contents';
      notifyListeners();
      rethrow;
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(service.stop());
    super.dispose();
  }
}
