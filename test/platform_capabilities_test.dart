import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _map(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

void main() {
  final document = _map(
    jsonDecode(File('docs/platform-capabilities.json').readAsStringSync()),
  );
  final platforms = _map(document['platforms']);
  final allowedConstraints = (document['constraint_states']! as List<Object?>)
      .cast<String>()
      .toSet();
  final allowedImplementations =
      (document['implementation_states']! as List<Object?>)
          .cast<String>()
          .toSet();

  test('declares every supported platform and stays pre-release', () {
    expect(document['schema_version'], 1);
    expect(
      platforms.keys.toSet(),
      equals(<String>{'macos', 'windows', 'linux', 'ios', 'android'}),
    );

    final releaseState = _map(document['release_state']);
    expect(releaseState['signed'], isFalse);
    expect(releaseState['store_submitted'], isFalse);
    expect(releaseState['production_downloads'], isFalse);
  });

  test('capability claims use explicit constraints and evidence', () {
    const requiredCapabilities = <String>{
      'search_and_pin',
      'clipboard_monitoring',
      'background_capture',
      'secure_storage',
      'native_build',
      'signed_distribution',
    };

    for (final platformEntry in platforms.entries) {
      final capabilities = _map(_map(platformEntry.value)['capabilities']);
      expect(
        capabilities.keys,
        containsAll(requiredCapabilities),
        reason: '${platformEntry.key} is missing a required capability claim',
      );

      for (final capabilityEntry in capabilities.entries) {
        final capability = _map(capabilityEntry.value);
        final constraint = capability['constraint'];
        final implementation = capability['implementation'];

        expect(
          allowedConstraints,
          contains(constraint),
          reason:
              '${platformEntry.key}.${capabilityEntry.key} has an unknown constraint',
        );
        expect(
          allowedImplementations,
          contains(implementation),
          reason:
              '${platformEntry.key}.${capabilityEntry.key} has an unknown implementation state',
        );

        if (constraint == 'permission_gated') {
          expect(
            (capability['permission_notes'] as String?)?.trim(),
            isNotEmpty,
            reason:
                '${platformEntry.key}.${capabilityEntry.key} must explain its permission boundary',
          );
        }
        if (constraint == 'foreground_only' || constraint == 'impossible') {
          expect(
            (capability['reason'] as String?)?.trim(),
            isNotEmpty,
            reason:
                '${platformEntry.key}.${capabilityEntry.key} must explain the platform restriction',
          );
        }
        if (implementation == 'verified') {
          expect(
            (capability['evidence'] as List<Object?>?)?.cast<String>(),
            isNotEmpty,
            reason:
                '${platformEntry.key}.${capabilityEntry.key} cannot be verified without evidence',
          );
        }
      }
    }
  });

  test('mobile platforms never claim hidden clipboard daemons', () {
    final iosCapabilities = _map(_map(platforms['ios'])['capabilities']);
    final androidCapabilities = _map(
      _map(platforms['android'])['capabilities'],
    );

    expect(
      _map(iosCapabilities['clipboard_monitoring'])['constraint'],
      'foreground_only',
    );
    expect(
      _map(iosCapabilities['background_capture'])['constraint'],
      'impossible',
    );
    expect(
      _map(androidCapabilities['clipboard_monitoring'])['constraint'],
      'foreground_only',
    );
    expect(
      _map(androidCapabilities['background_capture'])['constraint'],
      'foreground_only',
    );
  });

  test('signed distribution remains gated on every platform', () {
    for (final platformEntry in platforms.entries) {
      final capabilities = _map(_map(platformEntry.value)['capabilities']);
      final distribution = _map(capabilities['signed_distribution']);
      expect(distribution['constraint'], 'permission_gated');
      expect(distribution['implementation'], 'planned');
    }
  });
}
