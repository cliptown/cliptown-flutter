import 'dart:async';

import 'clip_item.dart';

abstract interface class ClipRepository {
  Future<List<ClipItem>> load();

  Future<void> save(List<ClipItem> clips);

  Future<void> clear();
}

abstract interface class SemanticClipRepository {
  Future<List<String>> semanticSearchIds(String query, {int limit = 20});
}

abstract interface class ClosableClipRepository {
  Future<void> close();
}

abstract interface class SemanticClipRepositoryUpdates {
  Stream<void> get indexUpdates;
}

/// Small UI-facing state, never containing clipboard text or encryption keys.
enum SemanticIndexPhase { preparing, downloading, indexing, ready, unavailable }

final class SemanticIndexProgress {
  const SemanticIndexProgress({
    required this.phase,
    required this.indexed,
    required this.total,
    this.downloadPercent,
  });

  final SemanticIndexPhase phase;
  final int indexed;
  final int total;
  final int? downloadPercent;

  bool get canRetry => phase == SemanticIndexPhase.unavailable;

  String get label => switch (phase) {
    SemanticIndexPhase.preparing => 'Preparing offline search',
    SemanticIndexPhase.downloading =>
      downloadPercent == null
          ? 'Downloading MiniLM model'
          : 'Downloading MiniLM model: $downloadPercent%',
    SemanticIndexPhase.indexing => 'Indexing $indexed of $total clips locally',
    SemanticIndexPhase.ready =>
      total == 0
          ? 'Local semantic search available'
          : 'Meaning search ready ($total clips)',
    SemanticIndexPhase.unavailable =>
      'Meaning search paused; exact search still works',
  };
}

abstract interface class SemanticIndexProgressSource {
  SemanticIndexProgress get indexProgress;
  Stream<SemanticIndexProgress> get indexProgressUpdates;
  Future<void> retrySemanticIndex();
}

class MemoryClipRepository implements ClipRepository {
  MemoryClipRepository({List<ClipItem> seed = const <ClipItem>[]})
    : _clips = List<ClipItem>.of(seed);

  List<ClipItem> _clips;

  @override
  Future<List<ClipItem>> load() async => List<ClipItem>.of(_clips);

  @override
  Future<void> save(List<ClipItem> clips) async {
    _clips = List<ClipItem>.of(clips);
  }

  @override
  Future<void> clear() async {
    _clips = <ClipItem>[];
  }
}

class ClipRepositoryException implements Exception {
  const ClipRepositoryException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'ClipRepositoryException: $message';
}
