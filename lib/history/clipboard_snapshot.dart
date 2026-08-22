import 'dart:convert';
import 'dart:typed_data';

import 'clip_item.dart';

class ClipboardSnapshot {
  ClipboardSnapshot.text({
    required String text,
    String? html,
    this.sourceApplication,
  }) : kind = inferTextKind(text, hasHtml: html?.isNotEmpty == true),
       text = text,
       html = html,
       data = null,
       mimeType = null,
       fileUris = const <String>[];

  const ClipboardSnapshot.image({
    required this.data,
    required this.mimeType,
    this.sourceApplication,
  }) : kind = ClipKind.image,
       text = null,
       html = null,
       fileUris = const <String>[];

  const ClipboardSnapshot.files({
    required this.fileUris,
    this.sourceApplication,
  }) : kind = ClipKind.files,
       text = null,
       html = null,
       data = null,
       mimeType = null;

  final ClipKind kind;
  final String? text;
  final String? html;
  final Uint8List? data;
  final String? mimeType;
  final List<String> fileUris;
  final String? sourceApplication;

  int get byteLength =>
      utf8.encode(text ?? '').length +
      utf8.encode(html ?? '').length +
      (data?.length ?? 0) +
      fileUris.fold<int>(0, (sum, value) => sum + utf8.encode(value).length);

  String get fingerprintMaterial => jsonEncode(<String, Object?>{
    'kind': kind.name,
    'text': text,
    'html': html,
    'data': data == null ? null : base64Encode(data!),
    'files': fileUris,
  });
}
