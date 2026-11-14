import '../history/capture_policy.dart';
import '../history/clip_item.dart';

class CaptureResult {
  const CaptureResult._({
    required this.accepted,
    this.item,
    this.rejectionReason,
    this.refreshedExisting = false,
  });

  const CaptureResult.accepted(ClipItem item, {bool refreshedExisting = false})
    : this._(accepted: true, item: item, refreshedExisting: refreshedExisting);

  const CaptureResult.rejected(CaptureRejectionReason reason)
    : this._(accepted: false, rejectionReason: reason);

  final bool accepted;
  final ClipItem? item;
  final CaptureRejectionReason? rejectionReason;
  final bool refreshedExisting;
}

/// A rejected user edit whose [message] is safe to show: it is a fixed string
/// and never contains clipboard content (unlike e.g. a JSON decode error).
class ClipInputException extends FormatException {
  const ClipInputException(super.message);
}

/// The [limit] most recently used of [clips], newest first, in one pass and
/// without sorting or copying the whole history.
List<ClipItem> mostRecentOf(Iterable<ClipItem> clips, int limit) {
  final top = <ClipItem>[];
  for (final clip in clips) {
    var index = top.length;
    while (index > 0 &&
        top[index - 1].sortTimestamp.isBefore(clip.sortTimestamp)) {
      index -= 1;
    }
    if (index < limit) {
      top.insert(index, clip);
      if (top.length > limit) top.removeLast();
    }
  }
  return top;
}
