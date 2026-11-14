import 'clip_item.dart';
import 'clipboard_snapshot.dart';

/// Text de-duplication rules.
///
/// Two text clips are duplicates only when their text is *verbatim* equal,
/// whitespace and case included. Images and file lists are never treated as
/// text duplicates. When duplicates exist the youngest (most recently copied
/// or used) wins; metadata the user set on the older copies (pin, tags,
/// collection) is carried over so de-duplication never loses a choice they
/// made.

/// Maximum tags a clip may carry (mirrors ClipStore.setTags).
const int maxClipTags = 32;

/// The de-duplication key of a clip, or null when the clip is not text.
String? textDedupeKey(ClipKind kind, String? text) =>
    kind == ClipKind.image || kind == ClipKind.files ? null : text;

String? clipTextKey(ClipItem clip) => textDedupeKey(clip.kind, clip.text);

String? snapshotTextKey(ClipboardSnapshot snapshot) =>
    textDedupeKey(snapshot.kind, snapshot.text);

/// Whether two consecutive clipboard snapshots carry the same content: text
/// verbatim for text, the full fingerprint for images and files.
bool sameClipboardContent(ClipboardSnapshot a, ClipboardSnapshot b) {
  final keyA = snapshotTextKey(a);
  final keyB = snapshotTextKey(b);
  if (keyA != null || keyB != null) return keyA == keyB;
  return a.fingerprintMaterial == b.fingerprintMaterial;
}

/// Orders clips youngest first: most recent copy/use, then creation, then id
/// (a stable tie-break so the plan is deterministic).
int compareYoungestFirst(ClipItem a, ClipItem b) {
  final bySort = b.sortTimestamp.compareTo(a.sortTimestamp);
  if (bySort != 0) return bySort;
  final byCreated = b.createdAt.compareTo(a.createdAt);
  if (byCreated != 0) return byCreated;
  return b.id.compareTo(a.id);
}

/// Folds the user metadata of [older] copies into [keeper].
ClipItem mergeDuplicateMetadata(ClipItem keeper, Iterable<ClipItem> older) {
  final olderYoungestFirst = older.toList()..sort(compareYoungestFirst);
  final tags = <String>{...keeper.tags};
  for (final clip in olderYoungestFirst) {
    for (final tag in clip.tags) {
      if (tags.length >= maxClipTags) break;
      tags.add(tag);
    }
  }
  final collection =
      keeper.collection ??
      olderYoungestFirst
          .map((clip) => clip.collection)
          .whereType<String>()
          .where((value) => value.isNotEmpty)
          .firstOrNull;
  return keeper.copyWith(
    pinned: keeper.pinned || olderYoungestFirst.any((clip) => clip.pinned),
    tags: tags,
    collection: collection,
  );
}

/// What a de-duplication sweep must change.
class TextDedupePlan {
  const TextDedupePlan({required this.keepers, required this.removedIds});

  /// Surviving clip (by id) with merged metadata.
  final Map<String, ClipItem> keepers;

  /// Older duplicates to delete.
  final Set<String> removedIds;

  bool get isEmpty => removedIds.isEmpty;
}

/// Groups text clips by verbatim text and keeps the youngest of each group.
TextDedupePlan planTextDedupe(Iterable<ClipItem> clips) {
  final groups = <String, List<ClipItem>>{};
  for (final clip in clips) {
    final key = clipTextKey(clip);
    if (key != null) (groups[key] ??= <ClipItem>[]).add(clip);
  }
  final keepers = <String, ClipItem>{};
  final removed = <String>{};
  for (final group in groups.values.where((group) => group.length > 1)) {
    final ordered = group.toList()..sort(compareYoungestFirst);
    final keeper = ordered.first;
    final older = ordered.skip(1);
    keepers[keeper.id] = mergeDuplicateMetadata(keeper, older);
    removed.addAll(older.map((clip) => clip.id));
  }
  return TextDedupePlan(keepers: keepers, removedIds: removed);
}
