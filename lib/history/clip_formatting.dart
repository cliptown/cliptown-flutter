import 'dart:ui' show Color;

/// Compact "how long ago" label for clip rows (`just now`, `5m ago`, `3h ago`,
/// `2d ago`, then an ISO date). Future timestamps (clock skew) read as now.
String relativeTimeLabel(DateTime timestamp, DateTime now) {
  final elapsed = now.toUtc().difference(timestamp.toUtc());
  if (elapsed.inSeconds < 60) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes}m ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours}h ago';
  if (elapsed.inDays < 7) return '${elapsed.inDays}d ago';
  final local = timestamp.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

/// Size label: character/line counts for text, bytes for binary payloads.
String clipSizeLabel({String? text, required int byteLength}) {
  if (text != null) {
    final characters = text.runes.length;
    final lines = '\n'.allMatches(text).length + 1;
    final chars = characters == 1 ? '1 char' : '$characters chars';
    return lines > 1 ? '$chars • $lines lines' : chars;
  }
  if (byteLength < 1024) return '$byteLength B';
  if (byteLength < 1024 * 1024) {
    return '${(byteLength / 1024).toStringAsFixed(1)} KB';
  }
  return '${(byteLength / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Parses the `#rgb`, `#rgba`, `#rrggbb` and `#rrggbbaa` forms that
/// [ClipKind.color] clips are classified from.
Color? parseHexColor(String? value) {
  final match = RegExp(
    r'^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$',
    caseSensitive: false,
  ).firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final digits = match.group(1)!;
  final hex = digits.length <= 4
      ? digits.split('').map((digit) => '$digit$digit').join()
      : digits;
  final rgb = int.parse(hex.substring(0, 6), radix: 16);
  final alpha = hex.length == 8 ? int.parse(hex.substring(6), radix: 16) : 255;
  return Color((alpha << 24) | rgb);
}
