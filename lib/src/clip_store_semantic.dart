part of 'clip_store.dart';

/// Search-status presentation stays separate from ClipStore's clip mutations.
extension ClipStoreSemanticProgress on ClipStore {
  SemanticIndexProgress? get semanticIndexProgress {
    if (_repository case final SemanticIndexProgressSource provider) {
      return provider.indexProgress;
    }
    return null;
  }

  StreamSubscription<SemanticIndexProgress>? _watchSemanticProgress() {
    if (_repository case final SemanticIndexProgressSource provider) {
      return provider.indexProgressUpdates.listen((_) => _notifySemanticProgress());
    }
    return null;
  }

  Future<void> retrySemanticIndex() async {
    if (_repository case final SemanticIndexProgressSource provider) {
      await provider.retrySemanticIndex();
    }
  }
}
