import 'package:flutter/material.dart';

/// Upper bound on characters rendered for one clip. Clips can be megabytes;
/// laying all of that out inside a list row would stall the UI.
const int maxPreviewCharacters = 20000;

/// How much taller a clicked clip row grows when its text already fits.
const double expandedRowGrowth = 0.15;

/// How much taller it grows when the text is longer than the collapsed row
/// (it then becomes scrollable inside the extra room).
const double expandedOverflowRowGrowth = 0.25;

/// The text of one clip row.
///
/// Collapsed, the text is limited to [collapsedLines] (with an ellipsis when it
/// is longer). The row owner expands it by passing [extraHeight] > 0 (the
/// animated extra room, 15% of the row): the text area grows by that much and
/// becomes scrollable when the clip is longer than the space. The scrollbar is
/// shown only while the pointer is over the text and hides when it leaves.
/// Scrolling lives only inside an expanded row, so wheel scrolling over the
/// history list is never captured by a row the user is not reading.
class ClipContentPreview extends StatefulWidget {
  const ClipContentPreview({
    super.key,
    required this.text,
    this.style,
    this.collapsedLines = 3,
    this.extraHeight = 0,
    this.overflowExtraHeight = 0,
  });

  final String text;
  final TextStyle? style;
  final int collapsedLines;

  /// Extra height granted by an expanded row whose text fits; 0 collapsed.
  final double extraHeight;

  /// Extra height used instead when the text overflows the collapsed lines.
  final double overflowExtraHeight;

  @override
  State<ClipContentPreview> createState() => _ClipContentPreviewState();
}

class _ClipContentPreviewState extends State<ClipContentPreview> {
  final ScrollController _scrollController = ScrollController();
  bool _hovering = false;

  @override
  void didUpdateWidget(ClipContentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final collapsedNow =
        widget.extraHeight <= 0 &&
        widget.overflowExtraHeight <= 0 &&
        (oldWidget.extraHeight > 0 || oldWidget.overflowExtraHeight > 0);
    if ((collapsedNow || oldWidget.text != widget.text) &&
        _scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _setHovering(bool hovering) {
    if (_hovering != hovering) setState(() => _hovering = hovering);
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
        TextPainter painter({int? maxLines}) => TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: maxLines,
          ellipsis: maxLines == null ? null : '…',
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);

        final clipped = painter(maxLines: widget.collapsedLines);
        final overflows = clipped.didExceedMaxLines;
        final collapsedHeight = clipped.height;
        clipped.dispose();

        final extra = overflows
            ? widget.overflowExtraHeight
            : widget.extraHeight;
        if (extra <= 0) {
          if (!overflows) {
            return Text(
              text,
              key: const Key('clip-preview-text'),
              style: style,
            );
          }
          return Tooltip(
            message:
                'Click the row to make it taller and scroll the whole clip. '
                'Click anywhere else to shrink it.',
            child: Text(
              text,
              key: const Key('clip-preview-collapsed'),
              maxLines: widget.collapsedLines,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          );
        }

        final height = collapsedHeight + extra;
        final full = painter();
        final scrollable = full.height > height;
        full.dispose();

        return MouseRegion(
          onEnter: (_) => _setHovering(true),
          onExit: (_) => _setHovering(false),
          child: SizedBox(
            key: const Key('clip-preview-expanded'),
            // Full width, so the scrollbar sits at the right edge of the row
            // however short the lines are.
            width: double.infinity,
            height: height,
            child: ScrollConfiguration(
              // The explicit Scrollbar below is the only one shown.
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: Scrollbar(
                key: const Key('clip-preview-scrollbar'),
                controller: _scrollController,
                thumbVisibility: scrollable && _hovering,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  primary: false,
                  physics: scrollable
                      ? null
                      : const NeverScrollableScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(text, style: style),
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
