import 'dart:typed_data';

import 'package:cliptown_app/history/clip_drop.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/new_clip_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a drop becomes one clip per image, one file-list clip, and text '
      'clips', () {
    final snapshots = snapshotsFromDrop(
      pngImages: <Uint8List>[
        Uint8List.fromList(<int>[1]),
        Uint8List.fromList(<int>[2]),
      ],
      fileUris: <Uri>[Uri.file('/tmp/a.pdf'), Uri.file('/tmp/b.txt')],
      texts: <String>['hello', '   '],
    );
    expect(snapshots.map((s) => s.kind), <ClipKind>[
      ClipKind.image,
      ClipKind.image,
      ClipKind.files,
      ClipKind.text,
    ]);
    expect(snapshots[2].fileUris, <String>[
      'file:///tmp/a.pdf',
      'file:///tmp/b.txt',
    ]);
    expect(snapshotsFromDrop(texts: <String>[' \n']), isEmpty);
  });

  test('images, file URIs and text are the accepted drop formats', () {
    expect(droppableFormats.length, droppableImageFormats.length + 2);
  });

  testWidgets('non-images are not turned into image clips', (tester) async {
    final png = await tester.runAsync(
      () => encodeAsPng(Uint8List.fromList(<int>[1, 2, 3, 4])),
    );
    expect(png, isNull);
  });
}
