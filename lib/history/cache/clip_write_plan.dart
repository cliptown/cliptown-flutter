import 'package:flutter/foundation.dart';

import '../clip_item.dart';

/// The caller supplies the complete authoritative history, but only changed
/// rows are written to the encrypted database. The unchanged clip instances
/// are retained by reference, not serialized/copied on every capture.
final class ClipWritePlan {
  const ClipWritePlan({
    required this.inserted,
    required this.updated,
    required this.deletedIds,
    required this.before,
    required this.after,
  });

  final List<ClipItem> inserted;
  final List<ClipItem> updated;
  final List<String> deletedIds;
  final Map<String, ClipItem> before;
  final Map<String, ClipItem> after;

  int get affectedRows => inserted.length + updated.length + deletedIds.length;
}

/// Build a deterministic database delta, rejecting duplicate IDs before a
/// transaction can overwrite a different clip with the same primary key.
ClipWritePlan planClipWrites(
  Map<String, ClipItem> persisted,
  List<ClipItem> desired,
) {
  final next = <String, ClipItem>{};
  final added = <ClipItem>[];
  final changed = <ClipItem>[];

  for (final clip in desired) {
    if (next.containsKey(clip.id)) {
      throw const FormatException('duplicate clip ID in history');
    }
    next[clip.id] = clip;
    final previous = persisted[clip.id];
    if (previous == null) {
      clip.validate();
      added.add(clip);
    } else if (!samePersistedClip(previous, clip)) {
      clip.validate();
      changed.add(clip);
    }
  }

  return ClipWritePlan(
    inserted: added,
    updated: changed,
    deletedIds: <String>[
      for (final id in persisted.keys)
        if (!next.containsKey(id)) id,
    ],
    before: persisted,
    after: next,
  );
}

/// A clip is annotated @immutable, and ClipStore uses copyWith for edits.
/// Identity is a constant-time fast path for its unchanged members. If a
/// caller constructed an equivalent new instance, compare all persisted
/// fields without re-encoding potentially huge clipboard binary payloads.
bool samePersistedClip(ClipItem a, ClipItem b) {
  if (identical(a, b)) return true;
  return a.id == b.id &&
      a.kind == b.kind &&
      a.title == b.title &&
      a.text == b.text &&
      a.html == b.html &&
      a.dataBase64 == b.dataBase64 &&
      a.mimeType == b.mimeType &&
      listEquals(a.fileUris, b.fileUris) &&
      a.sourceApplication == b.sourceApplication &&
      a.createdAt == b.createdAt &&
      a.lastUsedAt == b.lastUsedAt &&
      a.pinned == b.pinned &&
      a.collection == b.collection &&
      setEquals(a.tags, b.tags);
}
