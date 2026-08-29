import 'dart:convert';
import 'dart:typed_data';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('infers useful text types deterministically', () {
    expect(inferTextKind('https://cliptown.example/a'), ClipKind.link);
    expect(inferTextKind('hello@cliptown.example'), ClipKind.email);
    expect(inferTextKind('#42d3ff'), ClipKind.color);
    expect(inferTextKind('class Clip {\n  return value;\n}'), ClipKind.code);
    expect(inferTextKind('ordinary note'), ClipKind.text);
    expect(inferTextKind('ordinary note', hasHtml: true), ClipKind.richText);
  });

  test('JSON round trip validates image data and bounds', () {
    final now = DateTime.utc(2026, 8, 22);
    final item = ClipItem(
      id: 'image-1',
      kind: ClipKind.image,
      title: 'Screenshot',
      dataBase64: base64Encode(<int>[1, 2, 3]),
      mimeType: 'image/png',
      createdAt: now,
      lastUsedAt: now,
      tags: const <String>{'design'},
    );

    final decoded = ClipItem.fromJson(item.toJson());
    expect(decoded.toJson(), item.toJson());
    expect(decoded.byteLength, 3);

    final invalid = Map<String, Object?>.of(item.toJson())
      ..['data_base64'] = 'not base64';
    expect(() => ClipItem.fromJson(invalid), throwsFormatException);
  });

  test('snapshot and persisted fingerprints agree', () {
    final snapshot = ClipboardSnapshot.image(
      data: Uint8List.fromList(<int>[1, 2, 3]),
      mimeType: 'image/png',
    );
    final now = DateTime.utc(2026, 8, 22);
    final item = ClipItem(
      id: 'image-1',
      kind: ClipKind.image,
      title: 'Image',
      dataBase64: base64Encode(snapshot.data!),
      mimeType: 'image/png',
      createdAt: now,
      lastUsedAt: now,
    );
    expect(item.fingerprintMaterial, snapshot.fingerprintMaterial);
  });
}
