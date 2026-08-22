import 'dart:convert';
import 'dart:io';

import 'package:cliptown_app/state.dart';

const _actionField = 'mbt::actionTaken';

final _eventsByFormalAction = <String, AppEvent>{
  'boot_signed_out': AppEvent.bootSignedOut,
  'boot_authenticated': AppEvent.bootAuthenticated,
  'sign_in_succeeded': AppEvent.signInSucceeded,
  'device_approved': AppEvent.deviceApproved,
  'device_resumed': AppEvent.deviceResumed,
  'unlock_succeeded': AppEvent.unlockSucceeded,
  'lock_requested': AppEvent.lockRequested,
  'authentication_expired': AppEvent.authenticationExpired,
  'sign_out_requested': AppEvent.signOutRequested,
  'device_suspended': AppEvent.deviceSuspended,
  'device_revoked': AppEvent.deviceRevoked,
  'network_connected': AppEvent.networkConnected,
  'network_disconnected': AppEvent.networkDisconnected,
  'sync_requested': AppEvent.syncRequested,
  'sync_succeeded': AppEvent.syncSucceeded,
  'sync_failed': AppEvent.syncFailed,
  'retry_requested': AppEvent.retryRequested,
  'foreground_requested': AppEvent.foregroundRequested,
  'background_requested': AppEvent.backgroundRequested,
  'shutdown_requested': AppEvent.shutdownRequested,
  'shutdown_completed': AppEvent.shutdownCompleted,
  'native_failure': AppEvent.nativeFailure,
};

final class FormalReplaySummary {
  const FormalReplaySummary({required this.traces, required this.states});

  final int traces;
  final int states;
}

FormalReplaySummary replayFormalTraces(Iterable<String> tracePaths) {
  final paths = tracePaths.toList()..sort();
  var traces = 0;
  var states = 0;
  for (final path in paths) {
    states += _replayTrace(path);
    traces += 1;
  }
  return FormalReplaySummary(traces: traces, states: states);
}

int _replayTrace(String path) {
  final document = _object(
    jsonDecode(File(path).readAsStringSync()),
    '$path document',
  );
  final states = _array(document['states'], '$path states');
  if (states.isEmpty) {
    throw FormatException('$path contains no formal states');
  }

  AppMachineState? actual;
  for (var index = 0; index < states.length; index += 1) {
    final encoded = _object(states[index], '$path state $index');
    final action = encoded[_actionField];
    if (action is! String || action.isEmpty) {
      throw FormatException('$path state $index has no model action');
    }
    final expected = _decodeFormalState(encoded['s'], path, index);

    if (action == 'init' ||
        action == 'init_mobile' ||
        action == 'init_desktop') {
      final runtimeIndex = expected['runtime']! as int;
      if (runtimeIndex < 0 || runtimeIndex >= AppRuntimeKind.values.length) {
        throw FormatException('$path state $index has unknown runtime');
      }
      actual = AppMachineState.initial(AppRuntimeKind.values[runtimeIndex]);
    } else if (action != 'idle') {
      final event = _eventsByFormalAction[action];
      if (event == null) {
        throw FormatException(
          '$path state $index has unknown action `$action`',
        );
      }
      if (actual == null) {
        throw FormatException('$path state $index appears before init');
      }
      final transition = AppTransitionSystem.transition(actual, event);
      if (!transition.accepted) {
        throw StateError(
          '$path state $index action `$action` was rejected by Dart: '
          '${transition.rejectionReason}',
        );
      }
      actual = transition.next;
    }

    if (actual == null) {
      throw FormatException('$path state $index did not initialize Dart state');
    }
    _compareProjection(
      path,
      index,
      action,
      expected,
      actual.toFormalProjection(),
    );
  }
  return states.length;
}

Map<String, Object> _decodeFormalState(Object? raw, String path, int index) {
  final state = _object(raw, '$path state $index projection');
  const integerFields = <String>[
    'runtime',
    'lifecycle',
    'authentication',
    'local_device',
    'vault',
    'sync',
    'revision',
  ];
  const booleanFields = <String>[
    'online',
    'window_visible',
    'revocation_observed',
  ];
  final result = <String, Object>{};
  for (final field in integerFields) {
    result[field] = _integer(state[field], '$path state $index `$field`');
  }
  for (final field in booleanFields) {
    final value = state[field];
    if (value is! bool) {
      throw FormatException('$path state $index `$field` is not boolean');
    }
    result[field] = value;
  }
  return result;
}

void _compareProjection(
  String path,
  int index,
  String action,
  Map<String, Object> expected,
  Map<String, Object> actual,
) {
  for (final field in expected.keys) {
    if (actual[field] != expected[field]) {
      throw StateError(
        '$path state $index after `$action` diverged at `$field`: '
        'expected ${expected[field]}, actual ${actual[field]}',
      );
    }
  }
}

int _integer(Object? raw, String context) {
  if (raw is int) return raw;
  if (raw is Map) {
    final object = _object(raw, context);
    final encoded = object['#bigint'];
    if (encoded is String && RegExp(r'^(?:0|[1-9]\d*)$').hasMatch(encoded)) {
      return int.parse(encoded);
    }
  }
  throw FormatException('$context is not a canonical non-negative integer');
}

Map<String, dynamic> _object(Object? raw, String context) {
  if (raw is! Map) throw FormatException('$context is not an object');
  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) {
      throw FormatException('$context contains a non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<dynamic> _array(Object? raw, String context) {
  if (raw is! List) throw FormatException('$context is not an array');
  return raw;
}
