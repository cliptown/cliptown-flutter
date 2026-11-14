import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Upper bound on characters rendered for one clip. Clips can be megabytes;
/// laying all of that out inside a list row would stall the UI.
const int maxPreviewCharacters = 20000;

/// Clip text that keeps a fixed row height.
///
/// Content that fits is plain text. Content taller than [collapsedLines] is
/// clipped with an ellipsis; clicking it turns the same fixed-height area into
/// a scroll view with a visible scrollbar. When the mouse pointer leaves (or,
/// on touch screens, the user taps elsewhere) it collapses again and the
/// scrollbar disappears, so wheel scrolling over the history list is never
/// captured by a row the user is not reading.
class ClipContentPreview extends StatefulWidget {
  const ClipContentPreview({
    super.key,
    required this.text,
    this.style,
    this.collapsedLines = 3,
  });

  final String text;
  final TextStyle? style;
  final int collapsedLines;

  @override
  State<ClipContentPreview> createState() => _ClipContentPreviewState();
}

class _ClipContentPreviewState extends State<ClipContentPreview> {
  final ScrollController _scrollController = ScrollController();
  bool _expanded = false;

  @override
  void didUpdateWidget(ClipContentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _expanded = false;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _expand() {
    if (_expanded) return;
    setState(() => _expanded = true);
  }

  void _collapse() {
    if (!_expanded) return;
    setState(() => _expanded = false);
  }

  String get _displayText {
    final text = widget.text;
    if (text.length <= maxPreviewCharacters) return text;
    final cut = safePreviewCut(text, maxPreviewCharacters);
    final hidden = text.length - cut;
    return '${text.substring(0, cut)}\n… $hidden more characters (copy the clip to get all of it)';
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final text = _displayText;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: widget.collapsedLines,
          ellipsis: '…',
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        final collapsedHeight = painter.height;
        painter.dispose();

        if (!overflows) {
          return Text(text, key: const Key('clip-preview-text'), style: style);
        }

        if (!_expanded) {
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Tooltip(
              message:
                  'Click to scroll the whole clip here. Move the pointer '
                  'away to collapse it again.',
              child: GestureDetector(
                key: const Key('clip-preview-collapsed'),
                behavior: HitTestBehavior.opaque,
                onTap: _expand,
                child: Semantics(
                  button: true,
                  onTapHint: 'scroll the full clip',
                  child: Text(
                    text,
                    maxLines: widget.collapsedLines,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ),
            ),
          );
        }

        return MouseRegion(
          onExit: (event) {
            // Only real pointers leave; ignore synthetic exits on rebuild.
            if (event.kind == PointerDeviceKind.mouse ||
                event.kind == PointerDeviceKind.trackpad) {
              _collapse();
            }
          },
          child: TapRegion(
            onTapOutside: (_) => _collapse(),
            child: SizedBox(
              key: const Key('clip-preview-expanded'),
              height: collapsedHeight,
              child: ScrollConfiguration(
                // The explicit Scrollbar below is the only one shown.
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: Scrollbar(
                  key: const Key('clip-preview-scrollbar'),
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    primary: false,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Text(text, style: style),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A cut index at or below [limit] that never splits a UTF-16 surrogate pair:
/// a lone surrogate is malformed text that the engine may refuse to lay out.
int safePreviewCut(String text, int limit) {
  if (text.length <= limit) return text.length;
  final last = text.codeUnitAt(limit - 1);
  final isHighSurrogate = last >= 0xD800 && last <= 0xDBFF;
  return isHighSurrogate ? limit - 1 : limit;
}
