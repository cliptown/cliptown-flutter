import 'clip_item.dart';

abstract interface class ClipRepository {
  Future<List<ClipItem>> load();

  Future<void> save(List<ClipItem> clips);

  Future<void> clear();
}

abstract interface class SemanticClipRepository {
  Future<List<String>> semanticSearchIds(String query, {int limit = 20});
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
