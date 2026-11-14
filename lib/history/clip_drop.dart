import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart' show DataReader;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import 'clipboard_snapshot.dart';
import 'new_clip_dialog.dart' show encodeAsPng;

/// Image formats accepted from a drop; decoded and stored as PNG.
const List<FileFormat> droppableImageFormats = <FileFormat>[
  Formats.png,
  Formats.jpeg,
  Formats.gif,
  Formats.webp,
  Formats.bmp,
  Formats.tiff,
];

const List<DataFormat> droppableFormats = <DataFormat>[
  ...droppableImageFormats,
  Formats.fileUri,
  Formats.plainText,
];

/// What one drop contained, in clip form: every image becomes its own clip,
/// all dropped files become one file-list clip, and text becomes a text clip.
List<ClipboardSnapshot> snapshotsFromDrop({
  List<Uint8List> pngImages = const <Uint8List>[],
  List<Uri> fileUris = const <Uri>[],
  List<String> texts = const <String>[],
}) => <ClipboardSnapshot>[
  for (final png in pngImages)
    ClipboardSnapshot.image(data: png, mimeType: 'image/png'),
  if (fileUris.isNotEmpty)
    ClipboardSnapshot.files(
      fileUris: <String>[for (final uri in fileUris) uri.toString()],
    ),
  for (final text in texts)
    if (text.trim().isNotEmpty) ClipboardSnapshot.text(text: text),
];

/// Drop images, files or text anywhere on [child] to add them as clips.
///
/// While something droppable is over the area a highlighted overlay explains
/// what will happen. Unsupported drags are refused (no copy cursor).
class ClipDropZone extends StatefulWidget {
  const ClipDropZone({
    super.key,
    required this.child,
    required this.onDropped,
    this.enabled = true,
  });

  final Widget child;
  final ValueChanged<List<ClipboardSnapshot>> onDropped;
  final bool enabled;

  @override
  State<ClipDropZone> createState() => _ClipDropZoneState();
}

class _ClipDropZoneState extends State<ClipDropZone> {
  bool _hovering = false;

  void _setHovering(bool hovering) {
    if (mounted && _hovering != hovering) {
      setState(() => _hovering = hovering);
    }
  }

  DropOperation _onDropOver(DropOverEvent event) {
    final supported =
        widget.enabled &&
        event.session.items.any(
          (item) => droppableFormats.any(item.canProvide),
        );
    return supported ? DropOperation.copy : DropOperation.none;
  }

  Future<void> _onPerformDrop(PerformDropEvent event) async {
    _setHovering(false);
    final images = <Uint8List>[];
    final files = <Uri>[];
    final texts = <String>[];
    for (final item in event.session.items) {
      final reader = item.dataReader;
      if (reader == null) continue;
      final image = await _readImage(reader);
      if (image != null) {
        images.add(image);
        continue;
      }
      final file = await _readValue(reader, Formats.fileUri);
      if (file != null) {
        files.add(file);
        continue;
      }
      final text = await _readValue(reader, Formats.plainText);
      if (text != null) texts.add(text);
    }
    final snapshots = snapshotsFromDrop(
      pngImages: images,
      fileUris: files,
      texts: texts,
    );
    if (snapshots.isNotEmpty) widget.onDropped(snapshots);
  }

  /// A dropped image (or image file), re-encoded as PNG; null otherwise.
  static Future<Uint8List?> _readImage(DataReader reader) async {
    for (final format in droppableImageFormats) {
      if (!reader.canProvide(format)) continue;
      final completer = Completer<Uint8List?>();
      final progress = reader.getFile(
        format,
        (file) async {
          try {
            completer.complete(await encodeAsPng(await file.readAll()));
          } on Object {
            completer.complete(null);
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      if (progress == null) continue;
      final png = await completer.future;
      if (png != null) return png;
    }
    return null;
  }

  static Future<T?> _readValue<T extends Object>(
    DataReader reader,
    ValueFormat<T> format,
  ) async {
    if (!reader.canProvide(format)) return null;
    final completer = Completer<T?>();
    final progress = reader.getValue<T>(
      format,
      (value) async => completer.complete(value),
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    return progress == null ? null : completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DropRegion(
      formats: droppableFormats,
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: _onDropOver,
      onDropEnter: (_) => _setHovering(true),
      onDropLeave: (_) => _setHovering(false),
      onDropEnded: (_) => _setHovering(false),
      onPerformDrop: _onPerformDrop,
      child: Stack(
        children: <Widget>[
          widget.child,
          if (_hovering)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const Key('clip-drop-overlay'),
                  decoration: BoxDecoration(
                    color: colors.primary.withValues(alpha: 0.12),
                    border: Border.all(color: colors.primary, width: 2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Center(
                    child: Text(
                      'Drop to add as a clip — images, files or text',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
