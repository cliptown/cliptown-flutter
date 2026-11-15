import 'dart:async';

import '../clip_repository.dart';

/// Manages debounced semantic requests independently from the ClipStore UI.
///
/// Queries never block lexical filtering, and stale asynchronous responses
/// cannot overwrite a newer query (or a newer index revision).
final class SemanticSearchController {
  SemanticSearchController({
    required this.repository,
    required this.onChanged,
    this.debounce = const Duration(milliseconds: 150),
  });

  final ClipRepository repository;
  final void Function() onChanged;
  final Duration debounce;

  StreamSubscription<void>? _updates;
  Timer? _timer;
  Map<String, int> _ranks = const <String, int>{};
  String _query = '';
  int _request = 0;
  bool _disposed = false;

  bool matches(String id) => _ranks.containsKey(id);
  int? rankOf(String id) => _ranks[id];

  void activate() {
    if (repository case final SemanticClipRepositoryUpdates updates) {
      _updates = updates.indexUpdates.listen((_) {
        if (_disposed || _query.trim().length < 2) return;
        _timer?.cancel();
        unawaited(_load(_query));
      });
    }
  }

  void setQuery(String value) {
    _query = value.trim();
    _request += 1;
    _timer?.cancel();
    _ranks = const <String, int>{};
    if (_disposed ||
        _query.length < 2 ||
        repository is! SemanticClipRepository) {
      return;
    }
    // Immediate exact matches remain visible while this timer runs.
    _timer = Timer(debounce, () => unawaited(_load(_query)));
  }

  Future<void> _load(String value) async {
    if (repository case final SemanticClipRepository semantic) {
      final request = ++_request;
      try {
        final ids = await semantic.semanticSearchIds(value);
        if (_disposed || request != _request || value != _query) return;
        _ranks = <String, int>{
          for (final (index, id) in ids.indexed) id: index,
        };
        onChanged();
      } on Object {
        // The encrypted history and lexical search are always available.
      }
    }
  }

  void dispose() {
    _disposed = true;
    _request += 1;
    _timer?.cancel();
    unawaited(_updates?.cancel());
  }
}
