import 'package:rxdart/rxdart.dart';

class ClipboardUiSnapshot {
  const ClipboardUiSnapshot({
    required this.busy,
    required this.monitoring,
    this.errorMessage,
  });

  final bool busy;
  final bool monitoring;
  final String? errorMessage;

  static const Object _unset = Object();

  ClipboardUiSnapshot copyWith({
    bool? busy,
    bool? monitoring,
    Object? errorMessage = _unset,
  }) {
    return ClipboardUiSnapshot(
      busy: busy ?? this.busy,
      monitoring: monitoring ?? this.monitoring,
      errorMessage: identical(errorMessage, _unset)
          ? this.errorMessage
          : errorMessage as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ClipboardUiSnapshot &&
      busy == other.busy &&
      monitoring == other.monitoring &&
      errorMessage == other.errorMessage;

  @override
  int get hashCode => Object.hash(busy, monitoring, errorMessage);
}

/// One replaceable UI snapshot at the effect boundary.
class ClipboardSnapshotBus {
  ClipboardSnapshotBus([
    ClipboardUiSnapshot seed = const ClipboardUiSnapshot(
      busy: false,
      monitoring: false,
    ),
  ]) : _subject = BehaviorSubject<ClipboardUiSnapshot>.seeded(seed);

  final BehaviorSubject<ClipboardUiSnapshot> _subject;

  ClipboardUiSnapshot get value => _subject.value;

  Stream<ClipboardUiSnapshot> get stream => _subject.stream.distinct();

  void publish(ClipboardUiSnapshot next) {
    if (_subject.isClosed) return;
    _subject.add(next);
  }

  Future<void> close() => _subject.close();
}
