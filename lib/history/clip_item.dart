import 'dart:convert';

import 'package:flutter/foundation.dart';

enum ClipKind { text, richText, link, email, color, code, image, files }

extension ClipKindLabel on ClipKind {
  String get label => switch (this) {
    ClipKind.text => 'Text',
    ClipKind.richText => 'Rich text',
    ClipKind.link => 'Link',
    ClipKind.email => 'Email',
    ClipKind.color => 'Color',
    ClipKind.code => 'Code',
    ClipKind.image => 'Image',
    ClipKind.files => 'Files',
  };
}

@immutable
class ClipItem {
  const ClipItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    required this.lastUsedAt,
    this.text,
    this.html,
    this.dataBase64,
    this.mimeType,
    this.fileUris = const <String>[],
    this.sourceApplication,
    this.pinned = false,
    this.collection,
    this.tags = const <String>{},
  });

  final String id;
  final ClipKind kind;
  final String title;
  final String? text;
  final String? html;
  final String? dataBase64;
  final String? mimeType;
  final List<String> fileUris;
  final String? sourceApplication;
  final DateTime createdAt;
  final DateTime lastUsedAt;
  final bool pinned;
  final String? collection;
  final Set<String> tags;

  DateTime get sortTimestamp =>
      lastUsedAt.isAfter(createdAt) ? lastUsedAt : createdAt;

  int get byteLength {
    final textBytes = utf8.encode(text ?? '').length;
    final htmlBytes = utf8.encode(html ?? '').length;
    final binaryBytes = dataBase64 == null
        ? 0
        : ((dataBase64!.length * 3) ~/ 4);
    final fileBytes = fileUris.fold<int>(
      0,
      (total, value) => total + utf8.encode(value).length,
    );
    return textBytes + htmlBytes + binaryBytes + fileBytes;
  }

  String get searchableText => <String>[
    title,
    text ?? '',
    sourceApplication ?? '',
    collection ?? '',
    kind.label,
    ...tags,
    ...fileUris,
  ].join(' ').toLowerCase();

  String get summary => switch (kind) {
    ClipKind.image => mimeType == null ? 'Image' : mimeType!,
    ClipKind.files =>
      fileUris.isEmpty ? 'Files' : fileUris.map(_fileNameFromUri).join(', '),
    _ => text ?? title,
  };

  String get fingerprintMaterial => jsonEncode(<String, Object?>{
    'kind': kind.name,
    'text': text,
    'html': html,
    'data': dataBase64,
    'files': fileUris,
  });

  ClipItem copyWith({
    String? title,
    DateTime? createdAt,
    DateTime? lastUsedAt,
    bool? pinned,
    String? collection,
    bool clearCollection = false,
    Set<String>? tags,
  }) => ClipItem(
    id: id,
    kind: kind,
    title: title ?? this.title,
    text: text,
    html: html,
    dataBase64: dataBase64,
    mimeType: mimeType,
    fileUris: fileUris,
    sourceApplication: sourceApplication,
    createdAt: createdAt ?? this.createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    pinned: pinned ?? this.pinned,
    collection: clearCollection ? null : collection ?? this.collection,
    tags: tags ?? this.tags,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'title': title,
    if (text != null) 'text': text,
    if (html != null) 'html': html,
    if (dataBase64 != null) 'data_base64': dataBase64,
    if (mimeType != null) 'mime_type': mimeType,
    if (fileUris.isNotEmpty) 'file_uris': fileUris,
    if (sourceApplication != null) 'source_application': sourceApplication,
    'created_at': createdAt.toUtc().toIso8601String(),
    'last_used_at': lastUsedAt.toUtc().toIso8601String(),
    'pinned': pinned,
    if (collection != null) 'collection': collection,
    if (tags.isNotEmpty) 'tags': tags.toList()..sort(),
  };

  factory ClipItem.fromJson(Map<String, Object?> json) {
    final kindName = _requiredString(json, 'kind');
    final kind = ClipKind.values.where((value) => value.name == kindName);
    if (kind.isEmpty) throw const FormatException('unknown clip kind');

    final item = ClipItem(
      id: _boundedString(json, 'id', maxLength: 160),
      kind: kind.single,
      title: _boundedString(json, 'title', maxLength: 512),
      text: _optionalBoundedString(json, 'text', maxLength: 1 << 20),
      html: _optionalBoundedString(json, 'html', maxLength: 1 << 20),
      dataBase64: _optionalBoundedString(
        json,
        'data_base64',
        maxLength: 12 << 20,
      ),
      mimeType: _optionalBoundedString(json, 'mime_type', maxLength: 120),
      fileUris: _stringList(json, 'file_uris', maxItems: 128),
      sourceApplication: _optionalBoundedString(
        json,
        'source_application',
        maxLength: 512,
      ),
      createdAt: _dateTime(json, 'created_at'),
      lastUsedAt: _dateTime(json, 'last_used_at'),
      pinned: json['pinned'] == true,
      collection: _optionalBoundedString(json, 'collection', maxLength: 160),
      tags: _stringList(json, 'tags', maxItems: 32).toSet(),
    );
    item.validate();
    return item;
  }

  void validate() {
    if (id.trim().isEmpty || title.trim().isEmpty) {
      throw const FormatException('clip identity fields may not be empty');
    }
    if (dataBase64 != null) {
      try {
        base64Decode(dataBase64!);
      } on FormatException {
        throw const FormatException('clip binary payload is not base64');
      }
    }
    switch (kind) {
      case ClipKind.image:
        if (dataBase64 == null || mimeType == null) {
          throw const FormatException('image clip is missing data');
        }
      case ClipKind.files:
        if (fileUris.isEmpty) {
          throw const FormatException('file clip is missing URIs');
        }
      default:
        if (text == null || text!.isEmpty) {
          throw const FormatException('textual clip is missing text');
        }
    }
  }
}

ClipKind inferTextKind(String text, {bool hasHtml = false}) {
  final trimmed = text.trim();
  if (hasHtml) return ClipKind.richText;
  if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(trimmed)) {
    return ClipKind.link;
  }
  if (RegExp(
    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
    caseSensitive: false,
  ).hasMatch(trimmed)) {
    return ClipKind.email;
  }
  if (RegExp(
    r'^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$',
    caseSensitive: false,
  ).hasMatch(trimmed)) {
    return ClipKind.color;
  }
  if (_looksLikeCode(trimmed)) return ClipKind.code;
  return ClipKind.text;
}

String defaultClipTitle(ClipKind kind, {String? text, List<String>? fileUris}) {
  final trimmed = text?.trim() ?? '';
  if (kind == ClipKind.files) {
    final files = fileUris ?? const <String>[];
    if (files.length == 1) return _fileNameFromUri(files.single);
    return '${files.length} files';
  }
  if (kind == ClipKind.image) return 'Clipboard image';
  if (kind == ClipKind.link) {
    final uri = Uri.tryParse(trimmed);
    if (uri?.host.isNotEmpty == true) return uri!.host;
  }
  final firstLine = trimmed.split(RegExp(r'\r?\n')).first.trim();
  if (firstLine.isEmpty) return kind.label;
  return firstLine.length <= 72 ? firstLine : '${firstLine.substring(0, 69)}…';
}

bool _looksLikeCode(String value) {
  if (!value.contains('\n')) return false;
  final signals = <RegExp>[
    RegExp(r'\b(class|fn|func|function|import|const|let|var|return)\b'),
    RegExp(r'[{};]\s*$'),
    RegExp(r'^\s*(SELECT|INSERT|UPDATE|DELETE)\b', caseSensitive: false),
  ];
  return signals.any((signal) => signal.hasMatch(value));
}

String _fileNameFromUri(String value) {
  final uri = Uri.tryParse(value);
  if (uri != null && uri.pathSegments.isNotEmpty) {
    return Uri.decodeComponent(uri.pathSegments.last);
  }
  return value;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

String _boundedString(
  Map<String, Object?> json,
  String key, {
  required int maxLength,
}) {
  final value = _requiredString(json, key);
  if (value.length > maxLength) throw FormatException('$key is too large');
  return value;
}

String? _optionalBoundedString(
  Map<String, Object?> json,
  String key, {
  required int maxLength,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.length > maxLength) {
    throw FormatException('$key is invalid');
  }
  return value;
}

List<String> _stringList(
  Map<String, Object?> json,
  String key, {
  required int maxItems,
}) {
  final value = json[key];
  if (value == null) return const <String>[];
  if (value is! List<Object?> || value.length > maxItems) {
    throw FormatException('$key is invalid');
  }
  return value
      .map((entry) {
        if (entry is! String || entry.length > 2048) {
          throw FormatException('$key contains an invalid entry');
        }
        return entry;
      })
      .toList(growable: false);
}

DateTime _dateTime(Map<String, Object?> json, String key) {
  final value = _requiredString(json, key);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key is not an ISO timestamp');
  return parsed.toUtc();
}
