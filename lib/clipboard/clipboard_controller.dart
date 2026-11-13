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

  _ClipboardObservation? _lastObservation;

  void _observe(String fingerprint, CaptureResult result) {
    _lastObservation = _ClipboardObservation(
      fingerprint: fingerprint,
      savedClipId: result.accepted ? result.item?.id : null,
      rejection: result.rejectionReason,
    );
    if (!_disposed) notifyListeners();
  }

  /// Whether "Save clipboard now" can do anything, and why not.
  ///
  /// Only trusted while automatic monitoring runs: without it the clipboard
  /// may have changed since ClipTown last looked, so saving stays available.
  ClipboardSaveStatus get saveStatus {
    final state = stateMachine.state;
    if (!state.permitsLocalWork) {
      return const ClipboardSaveStatus(ClipboardSaveAvailability.locked);
    }
    if (!state.permitsCaptureWork) {
      return const ClipboardSaveStatus(ClipboardSaveAvailability.paused);
    }
    if (busy) {
      return const ClipboardSaveStatus(ClipboardSaveAvailability.saving);
    }
    final observation = _lastObservation;
    if (!monitoring || observation == null) {
      return ClipboardSaveStatus(
        ClipboardSaveAvailability.available,
        automatic: monitoring,
      );
    }
    final savedId = observation.savedClipId;
    if (savedId != null) {
      final saved = store.clips.where((clip) => clip.id == savedId);
      if (saved.isNotEmpty &&
          saved.first.fingerprintMaterial == observation.fingerprint) {
        return const ClipboardSaveStatus(
          ClipboardSaveAvailability.alreadySaved,
          automatic: true,
        );
      }
      // The saved clip was deleted or edited: saving again is meaningful.
      return const ClipboardSaveStatus(
        ClipboardSaveAvailability.available,
        automatic: true,
      );
    }
    final rejection = observation.rejection;
    if (rejection != null &&
        rejection != CaptureRejectionReason.paused &&
        rejection != CaptureRejectionReason.vaultUnavailable) {
      // A manual save applies the same policy and would be refused again.
      return ClipboardSaveStatus(
        ClipboardSaveAvailability.rejected,
        rejection: rejection,
        automatic: true,
      );
    }
    return const ClipboardSaveStatus(
      ClipboardSaveAvailability.available,
      automatic: true,
    );
  }

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
    final result = await store.capture(clipboardSnapshot);
    _observe(clipboardSnapshot.fingerprintMaterial, result);
    return result;
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
        _observe(clipboardSnapshot.fingerprintMaterial, result);
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

@immutable
class _ClipboardObservation {
  const _ClipboardObservation({
    required this.fingerprint,
    required this.savedClipId,
    required this.rejection,
  });

  final String fingerprint;
  final String? savedClipId;
  final CaptureRejectionReason? rejection;
}

enum ClipboardSaveAvailability {
  available,
  saving,
  alreadySaved,
  rejected,
  paused,
  locked,
}

/// State of the "Save clipboard now" control: enabled only when saving would
/// add something, with a tooltip that says what it does and why it is off.
@immutable
class ClipboardSaveStatus {
  const ClipboardSaveStatus(
    this.availability, {
    this.rejection,
    this.automatic = false,
  });

  final ClipboardSaveAvailability availability;
  final CaptureRejectionReason? rejection;

  /// Automatic capture is watching the clipboard.
  final bool automatic;

  bool get enabled => availability == ClipboardSaveAvailability.available;

  String get tooltip => switch (availability) {
    ClipboardSaveAvailability.available =>
      automatic
          ? 'Save what is on your clipboard now. New copies are saved '
                'automatically; use this for something copied before ClipTown '
                'started or a clip you deleted.'
          : 'Save what is on your clipboard now into your encrypted history.',
    ClipboardSaveAvailability.saving => 'Saving your clipboard…',
    ClipboardSaveAvailability.alreadySaved =>
      'Already saved: what is on your clipboard is in your history. Copy '
          'something new and it is saved automatically.',
    ClipboardSaveAvailability.rejected => switch (rejection) {
      CaptureRejectionReason.empty =>
        'Nothing to save: the clipboard is empty or has an unsupported format.',
      CaptureRejectionReason.likelySensitive =>
        'Not saved: it looks like a password, key or code. Allow it under '
            'Privacy and capture settings.',
      CaptureRejectionReason.ignoredApplication =>
        'Not saved: it came from an excluded application (Privacy and capture '
            'settings).',
      CaptureRejectionReason.tooLarge =>
        'Not saved: it is larger than the per-item size limit.',
      _ => 'Not saved by your capture policy.',
    },
    ClipboardSaveAvailability.paused =>
      'Capture is paused. Turn capture on to save your clipboard.',
    ClipboardSaveAvailability.locked =>
      'Encrypted history is locked, so nothing can be saved.',
  };
}
