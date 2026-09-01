import 'dart:async';

import 'package:flutter/foundation.dart';

import '../history/capture_policy.dart';
import '../history/clip_item.dart';
import '../history/text_transform.dart';
import '../src/clip_store.dart';
import '../src/clipboard_snapshots.dart';
import '../state/app_state_machine.dart';
import 'clipboard_service.dart';

class ClipboardController extends ChangeNotifier {
  ClipboardController({
    required this.store,
    required this.service,
    this.automaticCaptureSupported = false,
    AppStateMachine? stateMachine,
  }) : stateMachine =
           stateMachine ??
           AppStateMachine.localReady(
             automaticCaptureSupported
                 ? AppRuntimeKind.desktop
                 : AppRuntimeKind.mobile,
             captureRequested: store.captureEnabled,
           ),
       _ownsStateMachine = stateMachine == null {
    _uiSubscription = _ui.stream.skip(1).listen((_) {
      if (!_disposed) notifyListeners();
    });
    this.stateMachine.addListener(_scheduleReconciliation);
  }

  final ClipStore store;
  final ClipClipboardService service;
  final bool automaticCaptureSupported;
  final AppStateMachine stateMachine;
  final bool _ownsStateMachine;
  final ClipboardSnapshotBus _ui = ClipboardSnapshotBus();
  StreamSubscription<ClipboardUiSnapshot>? _uiSubscription;
  Future<void> _reconciliationTail = Future<void>.value();
  bool _disposed = false;

  Stream<ClipboardUiSnapshot> get snapshots => _ui.stream;

  ClipboardUiSnapshot get snapshot => _ui.value;

  bool get monitoring => snapshot.monitoring;
  bool get busy => snapshot.busy;
  String? get errorMessage => snapshot.errorMessage;
  bool get captureRequested => stateMachine.state.captureRequested;

  void _dispatchUi(ClipboardUiEvent event) => _ui.dispatch(event);

  Future<void> initialize() async {
    if (store.vaultLocked) {
      if (stateMachine.state.captureRequested) {
        stateMachine.dispatch(AppEvent.captureDisabled);
      }
      if (stateMachine.state.vault == AppVaultState.unlocked) {
        stateMachine.dispatch(AppEvent.lockRequested);
      }
    } else if (!store.vaultLocked &&
        store.captureEnabled != stateMachine.state.captureRequested) {
      // The formal machine owns operational intent. The store persists the
      // accepted decision; it cannot independently turn capture back on.
      store.setCaptureEnabled(stateMachine.state.captureRequested);
    }
    await reconcileWithState();
  }

  Future<void> setCaptureEnabled(bool enabled) async {
    if (enabled) {
      final transition = stateMachine.state.captureRequested
          ? stateMachine.state.capture == AppCaptureState.faulted
                ? stateMachine.dispatch(AppEvent.captureRecovered)
                : null
          : stateMachine.dispatch(AppEvent.captureEnabled);
      if (transition != null && !transition.accepted) {
        store.setStatusMessage('Capture remains unavailable in this app state');
        return;
      }
      store.setCaptureEnabled(true);
    } else {
      final transition = stateMachine.dispatch(AppEvent.captureDisabled);
      if (!transition.accepted) return;
      store.setCaptureEnabled(false);
    }
    await reconcileWithState();
  }

  Future<CaptureResult> captureNow() => _run(() async {
    final authorizedRevision = _authorizedCaptureRevision();
    if (authorizedRevision == null) {
      store.setStatusMessage('Capture is not authorized in this app state');
      return const CaptureResult.rejected(CaptureRejectionReason.paused);
    }
    final clipboardSnapshot = await service.read();
    if (!_captureAuthorizationStillCurrent(authorizedRevision)) {
      store.setStatusMessage(
        'Capture was cancelled after the app state changed',
      );
      return const CaptureResult.rejected(CaptureRejectionReason.paused);
    }
    if (clipboardSnapshot == null) {
      store.setStatusMessage('No supported clipboard content found');
      return const CaptureResult.rejected(CaptureRejectionReason.empty);
    }
    return store.capture(clipboardSnapshot);
  });

  Future<void> copy(ClipItem item, {TextTransform? transform}) =>
      _run(() async {
        _requireLocalWork('copy');
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
    _requireLocalWork('paste queue');
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

  Future<void> reconcileWithState() {
    final result = _reconciliationTail.then((_) => _reconcileNow());
    _reconciliationTail = result.catchError((Object _) {});
    return result;
  }

  void _scheduleReconciliation() {
    if (_disposed) return;
    unawaited(
      reconcileWithState().catchError((Object _) {
        if (_disposed) return;
        _dispatchUi(
          const ClipboardUiFailed(
            'Clipboard state reconciliation failed safely',
            stopMonitoring: true,
          ),
        );
      }),
    );
  }

  Future<void> _reconcileNow() async {
    if (_disposed) return;
    final state = stateMachine.state;
    final shouldMonitor =
        automaticCaptureSupported &&
        state.permitsCaptureWork &&
        (state.capture == AppCaptureState.ready ||
            state.capture == AppCaptureState.monitoring);

    if (!shouldMonitor) {
      if (service.monitoring) await service.stop();
      _dispatchUi(const ClipboardMonitoringChanged(false));
      return;
    }
    if (service.monitoring && state.capture == AppCaptureState.monitoring) {
      _dispatchUi(const ClipboardMonitoringChanged(true, clearFailure: true));
      return;
    }
    await _startMonitoring();
  }

  Future<void> _startMonitoring() async {
    final authorizedRevision = _authorizedCaptureRevision();
    if (authorizedRevision == null) return;
    try {
      await service.start((clipboardSnapshot) async {
        final callbackRevision = _authorizedCaptureRevision(
          requireMonitoring: true,
        );
        if (callbackRevision == null) {
          await service.stop();
          if (!_disposed) {
            _dispatchUi(const ClipboardMonitoringChanged(false));
          }
          return;
        }
        final result = await store.capture(clipboardSnapshot);
        if (!result.accepted &&
            result.rejectionReason == CaptureRejectionReason.vaultUnavailable) {
          stateMachine.dispatch(AppEvent.captureFailed);
          if (stateMachine.state.vault == AppVaultState.unlocked) {
            stateMachine.dispatch(AppEvent.lockRequested);
          }
          await service.stop();
          if (!_disposed) {
            _dispatchUi(const ClipboardMonitoringChanged(false));
          }
          return;
        }
        if (!_captureAuthorizationStillCurrent(
          callbackRevision,
          requireMonitoring: true,
        )) {
          return;
        }
      });
      if (!_captureAuthorizationStillCurrent(authorizedRevision)) {
        await service.stop();
        if (!_disposed) {
          _dispatchUi(const ClipboardMonitoringChanged(false));
        }
        return;
      }
      if (stateMachine.state.capture == AppCaptureState.ready) {
        final transition = stateMachine.dispatch(
          AppEvent.captureMonitoringStarted,
        );
        if (!transition.accepted) {
          await service.stop();
          if (!_disposed) {
            _dispatchUi(const ClipboardMonitoringChanged(false));
          }
          return;
        }
      }
      if (!_disposed) {
        _dispatchUi(const ClipboardMonitoringChanged(true, clearFailure: true));
      }
    } on Object {
      if (_disposed) return;
      if (stateMachine.state.permitsCaptureWork) {
        stateMachine.dispatch(AppEvent.captureFailed);
      }
      if (!_disposed) {
        _dispatchUi(
          const ClipboardUiFailed(
            'Automatic clipboard capture is unavailable',
            stopMonitoring: true,
          ),
        );
      }
    }
  }

  int? _authorizedCaptureRevision({bool requireMonitoring = false}) {
    final state = stateMachine.state;
    if (!state.permitsCaptureWork ||
        (requireMonitoring && state.capture != AppCaptureState.monitoring)) {
      return null;
    }
    return state.revision;
  }

  bool _captureAuthorizationStillCurrent(
    int revision, {
    bool requireMonitoring = false,
  }) =>
      stateMachine.state.revision == revision &&
      _authorizedCaptureRevision(requireMonitoring: requireMonitoring) != null;

  void _requireLocalWork(String operation) {
    if (!stateMachine.state.permitsLocalWork) {
      throw StateError('$operation is unavailable in the current app state');
    }
  }

  Future<T> _run<T>(Future<T> Function() operation) async {
    _dispatchUi(const ClipboardOperationStarted());
    try {
      return await operation();
    } on Object {
      _dispatchUi(
        const ClipboardUiFailed(
          'Clipboard operation failed without exposing its contents',
        ),
      );
      rethrow;
    } finally {
      if (!_disposed) {
        _dispatchUi(const ClipboardOperationFinished());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stateMachine.removeListener(_scheduleReconciliation);
    unawaited(_uiSubscription?.cancel());
    unawaited(_ui.close());
    unawaited(service.stop());
    if (_ownsStateMachine) stateMachine.dispose();
    super.dispose();
  }
}
