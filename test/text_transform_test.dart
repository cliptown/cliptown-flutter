import 'package:cliptown_app/history/text_transform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('safe built-in transforms are deterministic', () {
    expect(
      transformText('  beta \nalpha\nbeta\n', TextTransform.sortUniqueLines),
      'alpha\nbeta',
    );
    expect(
      transformText(' hello   \n world ', TextTransform.trimWhitespace),
      'hello\nworld',
    );
    expect(
      transformText('hello WORLD', TextTransform.titleCase),
      'Hello World',
    );
    expect(transformText('a b/c', TextTransform.urlEncode), 'a%20b%2Fc');
  });

  test('invalid JSON fails rather than silently changing content', () {
    expect(
      () => transformText('{invalid}', TextTransform.prettyJson),
      throwsFormatException,
    );
  });
}
