import 'package:rxdart/rxdart.dart';

/// Events accepted by the clipboard presentation reducer.
///
/// Operational permission remains owned by `AppStateMachine`. These events
/// describe only presentation facts produced at the effect boundary, so the
/// RxDart stream cannot become a second lifecycle authority.
sealed class ClipboardUiEvent {
  const ClipboardUiEvent();
}

final class ClipboardOperationStarted extends ClipboardUiEvent {
  const ClipboardOperationStarted();
}

final class ClipboardOperationFinished extends ClipboardUiEvent {
  const ClipboardOperationFinished();
}

final class ClipboardMonitoringChanged extends ClipboardUiEvent {
  const ClipboardMonitoringChanged(
    this.monitoring, {
    this.clearFailure = false,
  });

  final bool monitoring;
  final bool clearFailure;
}

final class ClipboardUiFailed extends ClipboardUiEvent {
  const ClipboardUiFailed(this.message, {this.stopMonitoring = false});

  final String message;
  final bool stopMonitoring;
}

final class ClipboardUiFailureCleared extends ClipboardUiEvent {
  const ClipboardUiFailureCleared();
}

/// An immutable, valid-by-construction presentation snapshot.
///
/// Busy state is derived from the number of active operations. This prevents
/// one completed operation from publishing `busy: false` while another
/// operation is still running.
final class ClipboardUiSnapshot {
  const ClipboardUiSnapshot._({
    required this.activeOperations,
    required this.monitoring,
    required this.errorMessage,
  }) : assert(activeOperations >= 0);

  const ClipboardUiSnapshot.idle()
    : this._(activeOperations: 0, monitoring: false, errorMessage: null);

  final int activeOperations;
  final bool monitoring;
  final String? errorMessage;

  bool get busy => activeOperations > 0;

  ClipboardUiSnapshot _evolve({
    int? activeOperations,
    bool? monitoring,
    Object? errorMessage = _unset,
  }) => ClipboardUiSnapshot._(
    activeOperations: activeOperations ?? this.activeOperations,
    monitoring: monitoring ?? this.monitoring,
    errorMessage: identical(errorMessage, _unset)
        ? this.errorMessage
        : errorMessage as String?,
  );

  static const Object _unset = Object();

  @override
  bool operator ==(Object other) =>
      other is ClipboardUiSnapshot &&
      activeOperations == other.activeOperations &&
      monitoring == other.monitoring &&
      errorMessage == other.errorMessage;

  @override
  int get hashCode => Object.hash(activeOperations, monitoring, errorMessage);
}

/// Total, side-effect-free transition function for clipboard presentation.
ClipboardUiSnapshot reduceClipboardUiSnapshot(
  ClipboardUiSnapshot state,
  ClipboardUiEvent event,
) => switch (event) {
  ClipboardOperationStarted() => state._evolve(
    activeOperations: state.activeOperations + 1,
    errorMessage: null,
  ),
  ClipboardOperationFinished() =>
    state.activeOperations == 0
        ? state
        : state._evolve(activeOperations: state.activeOperations - 1),
  ClipboardMonitoringChanged(:final monitoring, :final clearFailure) =>
    state._evolve(
      monitoring: monitoring,
      errorMessage: clearFailure ? null : state.errorMessage,
    ),
  ClipboardUiFailed(:final message, :final stopMonitoring) => state._evolve(
    monitoring: stopMonitoring ? false : state.monitoring,
    errorMessage: message,
  ),
  ClipboardUiFailureCleared() => state._evolve(errorMessage: null),
};

/// One replaying, deduplicated UI snapshot at the effect boundary.
///
/// Callers dispatch typed events; only [reduceClipboardUiSnapshot] constructs
/// subsequent snapshots. RxDart supplies replay and selector composition, not
/// an additional mutable state store.
final class ClipboardSnapshotBus {
  ClipboardSnapshotBus([
    ClipboardUiSnapshot seed = const ClipboardUiSnapshot.idle(),
  ]) : _subject = BehaviorSubject<ClipboardUiSnapshot>.seeded(seed);

  final BehaviorSubject<ClipboardUiSnapshot> _subject;

  ClipboardUiSnapshot get value => _subject.value;

  Stream<ClipboardUiSnapshot> get stream => _subject.stream.distinct();

  Stream<bool> get busyChanges =>
      stream.map((snapshot) => snapshot.busy).distinct();

  Stream<bool> get monitoringChanges =>
      stream.map((snapshot) => snapshot.monitoring).distinct();

  void dispatch(ClipboardUiEvent event) {
    if (_subject.isClosed) return;
    _subject.add(reduceClipboardUiSnapshot(_subject.value, event));
  }

  Future<void> close() => _subject.close();
}
