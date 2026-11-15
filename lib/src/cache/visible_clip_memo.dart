import '../../history/clip_item.dart';

/// A tiny versioned cache for immutable visible-history projections. Kept
/// separate from ClipStore so state invalidation is explicit and testable.
final class VisibleClipMemo {
  List<ClipItem>? _value;

  void invalidate() => _value = null;

  List<ClipItem> resolve(List<ClipItem> Function() compute) {
    return _value ??= compute();
  }
}
