import 'dart:convert';
import 'dart:io';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/encrypted_clip_repository.dart';
import 'package:cliptown_app/history/sqlite_clip_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opt-in desktop benchmark for the encrypted SQLite path:
///
/// flutter test --dart-define=CLIPTOWN_RUN_SQLITE_BENCH=true \\
///   test/performance/sqlite_clip_persistence_benchmark_test.dart
///
/// Measures the complete application-facing save(List<ClipItem>) call, including
/// full-history delta planning. No plaintext is uploaded or logged. Do not
/// use these numbers as production claims without matching hardware tests.
const bool _runBenchmark = bool.fromEnvironment(
  'CLIPTOWN_RUN_SQLITE_BENCH',
);

void main() {
  test(
    'encrypted incremental SQLite p50/p95 at 1k, 10k, 50k and 100k clips',
    () async {
      for (final count in <int>[1000, 10000, 50000, 100000]) {
        final directory = await Directory.systemTemp.createTemp(
          'cliptown-bench-$count-',
        );
        final secrets = _BenchmarkSecrets();
        final repository = SqliteClipRepository(
          path: '${directory.path}/encrypted.db',
          secretStore: secrets,
          generateLegacyEmbeddings: false,
        );
        try {
          final date = DateTime.utc(2026, 11, 14);
          final clips = List<ClipItem>.generate(
            count,
            (index) => ClipItem(
              id: 'clip-$index',
              kind: ClipKind.text,
              title: 'Note $index',
              text: 'Small reproducible search payload $index',
              createdAt: date,
              lastUsedAt: date,
            ),
          );

          final first = Stopwatch()..start();
          await repository.save(clips);
          first.stop();
          expect(repository.lastWriteStats().inserted, count);

          final pinTimes = <int>[];
          for (var iteration = 0; iteration < 15; iteration += 1) {
            final index = (iteration * 1543 + 17) % clips.length;
            final timer = Stopwatch()..start();
            final next = List<ClipItem>.of(clips);
            next[index] = next[index].copyWith(pinned: !next[index].pinned);
            await repository.save(next);
            timer.stop();
            pinTimes.add(timer.elapsedMicroseconds);
            expect(repository.lastWriteStats().changedRows, 1);
            clips[index] = next[index];
          }

          final noOpTimes = <int>[];
          for (var iteration = 0; iteration < 6; iteration += 1) {
            final timer = Stopwatch()..start();
            await repository.save(List<ClipItem>.of(clips));
            timer.stop();
            noOpTimes.add(timer.elapsedMicroseconds);
            expect(repository.lastWriteStats().changedRows, 0);
          }

          final cold = Stopwatch()..start();
          final loaded = await repository.load();
          cold.stop();
          expect(loaded, hasLength(count));
          print(jsonEncode(<String, Object?>{
            'benchmark': 'cliptown-encrypted-sqlite-incremental',
            'size': count,
            'seed_ms': first.elapsedMilliseconds,
            'pin_p50_ms': _percentile(pinTimes, 0.50),
            'pin_p95_ms': _percentile(pinTimes, 0.95),
            'noop_p50_ms': _percentile(noOpTimes, 0.50),
            'noop_p95_ms': _percentile(noOpTimes, 0.95),
            'reload_ms': cold.elapsedMilliseconds,
          }));
        } finally {
          await repository.clear();
          await directory.delete(recursive: true);
        }
      }
    },
    skip: !_runBenchmark,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

double _percentile(List<int> samples, double fraction) {
  final sorted = List<int>.of(samples)..sort();
  final index = ((sorted.length - 1) * fraction).ceil();
  return double.parse((sorted[index] / 1000).toStringAsFixed(3));
}

final class _BenchmarkSecrets implements VaultSecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}
