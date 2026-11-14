import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/replay_formal_traces.dart';

void main() {
  test('Quint ITF traces refine the production Flutter reducer', () {
    final configuredDirectory =
        Platform.environment['CLIPTOWN_FORMAL_TRACE_DIR'];
    final directory = Directory(
      configuredDirectory ?? 'test/fixtures/formal-traces',
    );
    final traces =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.itf.json'))
            .map((file) => file.path)
            .toList()
          ..sort();

    expect(
      traces,
      isNotEmpty,
      reason: 'no ITF traces found under ${directory.path}',
    );
    final summary = replayFormalTraces(traces);
    expect(summary.traces, traces.length);
    expect(summary.states, greaterThanOrEqualTo(summary.traces));
  });
}
