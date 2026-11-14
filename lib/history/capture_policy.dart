import 'clipboard_snapshot.dart';

enum CaptureRejectionReason {
  paused,
  empty,
  ignoredApplication,
  likelySensitive,
  tooLarge,
  vaultUnavailable,
}

class CapturePolicy {
  const CapturePolicy({
    this.captureEnabled = true,
    this.captureLikelySensitive = false,
    this.ignoredApplications = const <String>{},
    this.maxItemBytes = 8 * 1024 * 1024,
    this.maxHistoryItems = 1000,
    this.retention = const Duration(days: 30),
  });

  final bool captureEnabled;
  final bool captureLikelySensitive;
  final Set<String> ignoredApplications;
  final int maxItemBytes;
  final int maxHistoryItems;
  final Duration retention;

  CaptureRejectionReason? evaluate(ClipboardSnapshot snapshot) {
    if (!captureEnabled) return CaptureRejectionReason.paused;
    if (_isEmpty(snapshot)) return CaptureRejectionReason.empty;
    final source = snapshot.sourceApplication?.trim().toLowerCase();
    if (source != null &&
        ignoredApplications.any(
          (entry) => entry.trim().toLowerCase() == source,
        )) {
      return CaptureRejectionReason.ignoredApplication;
    }
    if (snapshot.byteLength > maxItemBytes) {
      return CaptureRejectionReason.tooLarge;
    }
    if (!captureLikelySensitive &&
        snapshot.text != null &&
        isLikelySensitiveText(snapshot.text!)) {
      return CaptureRejectionReason.likelySensitive;
    }
    return null;
  }

  CapturePolicy copyWith({
    bool? captureEnabled,
    bool? captureLikelySensitive,
    Set<String>? ignoredApplications,
    int? maxItemBytes,
    int? maxHistoryItems,
    Duration? retention,
  }) => CapturePolicy(
    captureEnabled: captureEnabled ?? this.captureEnabled,
    captureLikelySensitive:
        captureLikelySensitive ?? this.captureLikelySensitive,
    ignoredApplications: ignoredApplications ?? this.ignoredApplications,
    maxItemBytes: maxItemBytes ?? this.maxItemBytes,
    maxHistoryItems: maxHistoryItems ?? this.maxHistoryItems,
    retention: retention ?? this.retention,
  );
}

bool isLikelySensitiveText(String text) {
  final value = text.trim();
  if (value.isEmpty) return false;

  final strongSignals = <RegExp>[
    RegExp(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    RegExp(r'\b(?:gh[pousr]|github_pat)_[A-Za-z0-9_]{20,}\b'),
    RegExp(r'\bAKIA[0-9A-Z]{16}\b'),
    RegExp(r'\bBearer\s+[A-Za-z0-9._~+/=-]{16,}\b', caseSensitive: false),
    RegExp(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b'),
    RegExp(
      r'\b(?:password|passwd|secret|api[_ -]?key|access[_ -]?token|refresh[_ -]?token)\s*[:=]\s*\S{6,}',
      caseSensitive: false,
    ),
  ];
  if (strongSignals.any((signal) => signal.hasMatch(value))) return true;

  if (RegExp(r'^\d{6,8}$').hasMatch(value)) return true;
  return _looksLikePaymentCard(value);
}

bool _looksLikePaymentCard(String value) {
  final digits = value.replaceAll(RegExp(r'[ -]'), '');
  if (!RegExp(r'^\d{13,19}$').hasMatch(digits)) return false;
  var sum = 0;
  var doubleDigit = false;
  for (var index = digits.length - 1; index >= 0; index -= 1) {
    var digit = int.parse(digits[index]);
    if (doubleDigit) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    doubleDigit = !doubleDigit;
  }
  return sum % 10 == 0;
}

bool _isEmpty(ClipboardSnapshot snapshot) => switch (snapshot.kind) {
  _ when snapshot.text != null => snapshot.text!.trim().isEmpty,
  _ when snapshot.data != null => snapshot.data!.isEmpty,
  _ => snapshot.fileUris.isEmpty,
};

String captureRejectionLabel(CaptureRejectionReason reason) => switch (reason) {
  CaptureRejectionReason.paused => 'Capture is paused',
  CaptureRejectionReason.empty => 'Empty clipboard ignored',
  CaptureRejectionReason.ignoredApplication => 'Excluded application ignored',
  CaptureRejectionReason.likelySensitive => 'Likely sensitive content ignored',
  CaptureRejectionReason.tooLarge => 'Clipboard item exceeds the size limit',
  CaptureRejectionReason.vaultUnavailable => 'Encrypted history is locked',
};
