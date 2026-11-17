import '../../history/clip_item.dart';

/// Return IDs beyond the history cap, preserving pinned items. The common
/// case (history below its cap) is O(n): sorting is skipped entirely.
///
/// Only overflowing histories perform the O(n log n) recency sort. This
/// projection never changes the caller's list and avoids sorting on routine
/// mark-used, pin, search or capture operations within the configured cap.
Set<String> overflowUnpinnedClipIds(Iterable<ClipItem> clips, int limit) {
  final unpinned = clips.where((clip) => !clip.pinned).toList();
  if (unpinned.length <= limit) return const <String>{};
  unpinned.sort((a, b) {
    final byTime = b.sortTimestamp.compareTo(a.sortTimestamp);
    return byTime != 0 ? byTime : a.id.compareTo(b.id);
  });
  return unpinned.skip(limit).map((clip) => clip.id).toSet();
}
