import '../clip_item.dart';

/// Counts successful encrypted SQL row changes, not O(n) planning work.
/// Exposed for regression tests and deterministic benchmark assertions.
final class ClipWriteStats {
  const ClipWriteStats({
    required this.inserted,
    required this.updated,
    required this.deleted,
    required this.embeddingsRebuilt,
  });

  final int inserted;
  final int updated;
  final int deleted;
  final int embeddingsRebuilt;

  int get changedRows => inserted + updated + deleted;
}

/// Tracks the last *committed* content and external-connection data version.
/// A failed transaction must never change the versioned in-memory snapshot.
final class ClipPersistenceState {
  Map<String, ClipItem>? _persisted;
  int? _dataVersion;
  ClipWriteStats _stats = const ClipWriteStats(
    inserted: 0,
    updated: 0,
    deleted: 0,
    embeddingsRebuilt: 0,
  );

  Map<String, ClipItem>? forVersion(int dataVersion) =>
      _dataVersion == dataVersion ? _persisted : null;

  ClipWriteStats lastStats() => _stats;

  void recordLoad(List<ClipItem> clips, int version) {
    _persisted = <String, ClipItem>{for (final clip in clips) clip.id: clip};
    _dataVersion = version;
  }

  void recordSave(
    Map<String, ClipItem> saved,
    int version,
    ClipWriteStats stats,
  ) {
    _persisted = saved;
    _dataVersion = version;
    _stats = stats;
  }

  void invalidate() {
    _persisted = null;
    _dataVersion = null;
  }
}
