import 'dart:async';

import 'package:rxdart/rxdart.dart';

import '../src/clip_store.dart';

/// Background, asynchronous text de-duplication.
///
/// Capture already folds a new copy into its verbatim duplicates, so this
/// worker is the safety net for duplicates that arrive any other way (older
/// histories, restores, other devices). It runs once shortly after start and
/// again after the history has been quiet for [quietPeriod]:
///
///   store changes ─▶ startWith ─▶ debounceTime ─▶ exhaustMap(sweep)
///
/// `exhaustMap` never overlaps sweeps; a sweep's own write is just one more
/// change and the follow-up sweep finds nothing, so the loop converges.
/// Failures are swallowed: de-duplication must never disturb the app.
class TextDedupeWorker {
  TextDedupeWorker(this.store, {this.quietPeriod = const Duration(seconds: 2)});

  final ClipStore store;
  final Duration quietPeriod;
  final PublishSubject<void> _changes = PublishSubject<void>();
  StreamSubscription<int>? _subscription;

  void start() {
    if (_subscription != null) return;
    store.addListener(_onStoreChanged);
    _subscription = _changes
        .startWith(null)
        .debounceTime(quietPeriod)
        .exhaustMap((_) => Stream<int>.fromFuture(_sweep()))
        .listen(null);
  }

  void _onStoreChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<int> _sweep() async {
    try {
      return await store.dedupeText();
    } on Object {
      return 0;
    }
  }

  Future<void> dispose() async {
    store.removeListener(_onStoreChanged);
    await _subscription?.cancel();
    await _changes.close();
  }
}
