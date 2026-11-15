import '../history/clip_item.dart';

/// One-pass visibility projection for ClipStore. The caller memoizes the
/// resulting snapshot and the normalized text of each immutable ClipItem.
List<ClipItem> buildVisibleClipSnapshot(
  Iterable<ClipItem> clips, {
  required String query,
  required bool pinnedOnly,
  required ClipKind? kindFilter,
  required String? collectionFilter,
  required bool Function(String) semanticMatches,
  required int? Function(String) semanticRank,
  required String Function(ClipItem) normalizedSearchText,
}) {
  final normalized = query.trim().toLowerCase();
  final exactMatches = <String, bool>{};
  final result = clips.where((clip) {
    if (pinnedOnly && !clip.pinned) return false;
    if (kindFilter != null && clip.kind != kindFilter) return false;
    if (collectionFilter != null && clip.collection != collectionFilter) {
      return false;
    }
    final exact = normalized.isNotEmpty &&
        normalizedSearchText(clip).contains(normalized);
    if (normalized.isNotEmpty && !exact && !semanticMatches(clip.id)) {
      return false;
    }
    if (normalized.isNotEmpty) exactMatches[clip.id] = exact;
    return true;
  }).toList();
  result.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    if (normalized.isNotEmpty) {
      final aExact = exactMatches[a.id]!;
      final bExact = exactMatches[b.id]!;
      if (aExact != bExact) return aExact ? -1 : 1;
      final aRank = semanticRank(a.id);
      final bRank = semanticRank(b.id);
      if (aRank != null && bRank != null) {
        final relevance = aRank.compareTo(bRank);
        if (relevance != 0) return relevance;
      }
    }
    final recent = b.sortTimestamp.compareTo(a.sortTimestamp);
    // Stable ordering prevents unnecessary sliver row moves.
    return recent != 0 ? recent : a.id.compareTo(b.id);
  });
  return List<ClipItem>.unmodifiable(result);
}
