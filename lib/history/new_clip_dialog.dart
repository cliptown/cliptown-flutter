import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'clip_drop.dart';
import 'clipboard_snapshot.dart';

/// What the user chose in the New clip dialog.
sealed class NewClipRequest {
  const NewClipRequest();
}

final class NewTextClip extends NewClipRequest {
  const NewTextClip(this.text);
  final String text;
}

/// Save whatever is on the system clipboard now (text, rich text, image or
/// files), whether or not automatic capture is on.
final class NewClipFromClipboard extends NewClipRequest {
  const NewClipFromClipboard();
}

final class NewImageClip extends NewClipRequest {
  const NewImageClip();
}

final class NewFilesClip extends NewClipRequest {
  const NewFilesClip();
}

/// Images, files or text dropped onto the dialog.
final class NewDroppedClips extends NewClipRequest {
  const NewDroppedClips(this.snapshots);
  final List<ClipboardSnapshot> snapshots;
}

/// Images the picker offers; anything the engine can decode is re-encoded as
/// PNG, the format ClipTown writes to the clipboard.
const XTypeGroup pickableImages = XTypeGroup(
  label: 'Images',
  extensions: <String>['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
  uniformTypeIdentifiers: <String>['public.image'],
);

Future<NewClipRequest?> showNewClipDialog(BuildContext context) {
  var text = '';
  return showDialog<NewClipRequest>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('New clip'),
      content: SizedBox(
        width: 520,
        child: ClipDropZone(
          onDropped: (snapshots) =>
              Navigator.pop(context, NewDroppedClips(snapshots)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              TextFormField(
                key: const Key('manual-clip-text'),
                autofocus: true,
                minLines: 3,
                maxLines: 10,
                onChanged: (value) => text = value,
                decoration: const InputDecoration(
                  labelText: 'Text',
                  helperText: 'Stored only in your encrypted local history.',
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Or add something else',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Tooltip(
                    message:
                        'Save what is on your clipboard right now: text, rich '
                        'text, an image or copied files',
                    child: OutlinedButton.icon(
                      key: const Key('new-clip-from-clipboard'),
                      onPressed: () =>
                          Navigator.pop(context, const NewClipFromClipboard()),
                      icon: const Icon(Icons.content_paste, size: 18),
                      label: const Text('From clipboard'),
                    ),
                  ),
                  Tooltip(
                    message: 'Choose a PNG, JPEG, GIF, WebP or BMP image',
                    child: OutlinedButton.icon(
                      key: const Key('new-clip-image'),
                      onPressed: () =>
                          Navigator.pop(context, const NewImageClip()),
                      icon: const Icon(Icons.image_outlined, size: 18),
                      label: const Text('Image…'),
                    ),
                  ),
                  Tooltip(
                    message:
                        'Choose one or more files; pasting the clip pastes '
                        'those files',
                    child: OutlinedButton.icon(
                      key: const Key('new-clip-files'),
                      onPressed: () =>
                          Navigator.pop(context, const NewFilesClip()),
                      icon: const Icon(Icons.attach_file, size: 18),
                      label: const Text('Files…'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Tip: drag an image, files or text onto this dialog '
                '(or anywhere on the ClipTown window) to add it.',
                key: const Key('new-clip-drop-hint'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('save-manual-clip'),
          onPressed: () => Navigator.pop(context, NewTextClip(text)),
          child: const Text('Save text'),
        ),
      ],
    ),
  );
}

/// Opens the image picker and returns a PNG snapshot, or null if cancelled
/// or the file is not a decodable image.
Future<ClipboardSnapshot?> pickImageSnapshot() async {
  final file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[pickableImages],
  );
  if (file == null) return null;
  final png = await encodeAsPng(await file.readAsBytes());
  return png == null
      ? null
      : ClipboardSnapshot.image(data: png, mimeType: 'image/png');
}

/// Opens the file picker and returns a file-list snapshot, or null.
Future<ClipboardSnapshot?> pickFilesSnapshot() async {
  final files = await openFiles();
  if (files.isEmpty) return null;
  return ClipboardSnapshot.files(
    fileUris: <String>[
      for (final file in files) Uri.file(file.path).toString(),
    ],
  );
}

/// Decodes any engine-supported image and re-encodes it as PNG; null when the
/// bytes are not an image.
Future<Uint8List?> encodeAsPng(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    return data?.buffer.asUint8List();
  } on Object {
    return null;
  }
}
