import 'dart:convert';

enum TextTransform {
  plainText,
  trimWhitespace,
  uppercase,
  lowercase,
  titleCase,
  prettyJson,
  urlEncode,
  urlDecode,
  sortUniqueLines,
}

extension TextTransformLabel on TextTransform {
  String get label => switch (this) {
    TextTransform.plainText => 'Plain text',
    TextTransform.trimWhitespace => 'Trim whitespace',
    TextTransform.uppercase => 'UPPERCASE',
    TextTransform.lowercase => 'lowercase',
    TextTransform.titleCase => 'Title Case',
    TextTransform.prettyJson => 'Pretty JSON',
    TextTransform.urlEncode => 'URL encode',
    TextTransform.urlDecode => 'URL decode',
    TextTransform.sortUniqueLines => 'Sort unique lines',
  };
}

String transformText(String input, TextTransform transform) =>
    switch (transform) {
      TextTransform.plainText => input,
      TextTransform.trimWhitespace =>
        input
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .join('\n')
            .trim(),
      TextTransform.uppercase => input.toUpperCase(),
      TextTransform.lowercase => input.toLowerCase(),
      TextTransform.titleCase => _titleCase(input),
      TextTransform.prettyJson => const JsonEncoder.withIndent(
        '  ',
      ).convert(jsonDecode(input)),
      TextTransform.urlEncode => Uri.encodeComponent(input),
      TextTransform.urlDecode => Uri.decodeComponent(input),
      TextTransform.sortUniqueLines => _sortUniqueLines(input),
    };

String _titleCase(String input) => input.replaceAllMapped(
  RegExp(r"\b[\p{L}\p{N}][\p{L}\p{N}\p{M}'’-]*", unicode: true),
  (match) {
    final word = match.group(0)!;
    return '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}';
  },
);

String _sortUniqueLines(String input) {
  final lines =
      input
          .split(RegExp(r'\r?\n'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return lines.join('\n');
}
