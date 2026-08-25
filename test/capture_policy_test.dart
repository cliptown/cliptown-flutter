import 'dart:typed_data';

import 'package:cliptown_app/history/capture_policy.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('detects strong secret formats and avoids vague prose matches', () {
    expect(
      isLikelySensitiveText(
        '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----',
      ),
      isTrue,
    );
    expect(
      isLikelySensitiveText('api_key = abcdefghijklmnopqrstuvwxyz'),
      isTrue,
    );
    expect(isLikelySensitiveText('123456'), isTrue);
    expect(
      isLikelySensitiveText('Random account master key design notes.'),
      isFalse,
    );
  });

  test('uses Luhn validation instead of rejecting every long number', () {
    expect(isLikelySensitiveText('4111 1111 1111 1111'), isTrue);
    expect(isLikelySensitiveText('4111 1111 1111 1112'), isFalse);
  });

  test('applies pause, source, and byte-size gates before capture', () {
    const paused = CapturePolicy(captureEnabled: false);
    expect(
      paused.evaluate(ClipboardSnapshot.text(text: 'hello')),
      CaptureRejectionReason.paused,
    );

    const excluded = CapturePolicy(
      ignoredApplications: <String>{'com.example.bank'},
    );
    expect(
      excluded.evaluate(
        ClipboardSnapshot.text(
          text: 'hello',
          sourceApplication: 'COM.EXAMPLE.BANK',
        ),
      ),
      CaptureRejectionReason.ignoredApplication,
    );

    const bounded = CapturePolicy(maxItemBytes: 4);
    expect(
      bounded.evaluate(
        ClipboardSnapshot.image(
          data: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
          mimeType: 'image/png',
        ),
      ),
      CaptureRejectionReason.tooLarge,
    );
  });
}
