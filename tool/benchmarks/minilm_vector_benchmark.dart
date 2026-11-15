import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cliptown_app/history/cache/bounded_vector_search.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:sqlite3/sqlite3.dart';

/// Measures local derived-index SQLite writes and exact top-K retrieval.
/// This is a synthetic benchmark: native MiniLM encoding latency is excluded.
///
/// dart run tool/benchmarks/minilm_vector_benchmark.dart
/// dart run tool/benchmarks/minilm_vector_benchmark.dart --output=build/benchmarks/minilm.json
Future<void> main(List<String> args) async {
  final output = args
      .where((arg) => arg.startsWith('--output='))
      .map((arg) => arg.substring('--output='.length))
      .firstOrNull;
  final cases = <Map<String, Object>>[];
  for (final count in <int>[10000, 100000]) {
    cases.add(await _runCase(count));
  }
  final report = <String, Object>{
    'benchmark': 'cliptown-offline-minilm-derived-vector-index',
    'native_model_inference_included': false,
    'dimensions': localEmbeddingDimensions,
    'search_top_k': 20,
    'samples_per_case': 5,
    'cases': cases,
  };
  final json = const JsonEncoder.withIndent('  ').convert(report);
  stdout.writeln(json);
  if (output != null) {
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString('$json\n');
  }
}

Future<Map<String, Object>> _runCase(int count) async {
  final temporary = await Directory.systemTemp.createTemp(
    'cliptown-minilm-vector-benchmark-',
  );
  final path = '${temporary.path}${Platform.pathSeparator}vectors.db';
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('''
      CREATE TABLE vectors (
        clip_id TEXT PRIMARY KEY,
        model_id TEXT NOT NULL,
        dimensions INTEGER NOT NULL,
        embedding BLOB NOT NULL
      ) STRICT
    ''');
    final random = math.Random(23117);
    // Reuse a deterministic palette of weight-like Float32 values to avoid
    // benchmarking synthetic-vector generation instead of index performance.
    final palette = List<Uint8List>.generate(256, (_) {
      final vector = List<double>.generate(
        localEmbeddingDimensions,
        (_) => random.nextDouble() * 2 - 1,
        growable: false,
      );
      return encodeLocalEmbedding(vector);
    });
    final insert = db.prepare('''
      INSERT INTO vectors(clip_id, model_id, dimensions, embedding)
      VALUES (?, ?, ?, ?)
    ''');
    final writeClock = Stopwatch()..start();
    db.execute('BEGIN IMMEDIATE');
    try {
      for (var i = 0; i < count; i += 1) {
        insert.execute(<Object?>[
          'clip-${i.toString().padLeft(6, '0')}',
          'synthetic-minilm',
          localEmbeddingDimensions,
          palette[i % palette.length],
        ]);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      insert.close();
    }
    writeClock.stop();
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');

    final query = List<double>.generate(
      localEmbeddingDimensions,
      (index) => (index % 29 + 1) / 30,
      growable: false,
    );
    final magnitude = validEmbeddingMagnitude(query)!;
    final measurements = <double>[];
    for (var i = 0; i < 5; i += 1) {
      final timer = Stopwatch()..start();
      final matches = await _scan(db, query, magnitude);
      timer.stop();
      if (matches.length != 20) {
        throw StateError('Expected 20 search results; got ${matches.length}');
      }
      measurements.add(timer.elapsedMicroseconds / 1000);
    }
    measurements.sort();
    return <String, Object>{
      'vector_count': count,
      'index_insert_ms': writeClock.elapsedMicroseconds / 1000,
      'query_p50_ms': measurements[measurements.length ~/ 2],
      'query_p95_ms': measurements.last,
      'sqlite_file_bytes': File(path).lengthSync(),
      'process_rss_bytes': ProcessInfo.currentRss,
    };
  } finally {
    db.close();
    await temporary.delete(recursive: true);
  }
}

Future<List<ClipVectorMatch>> _scan(
  Database db,
  List<double> query,
  double magnitude,
) async {
  const pageSize = 256;
  final matches = BoundedVectorSearch(20);
  var lastRowId = 0;
  while (true) {
    final rows = db.select(
      'SELECT rowid, clip_id, embedding FROM vectors '
      'WHERE rowid > ? AND model_id = ? AND dimensions = ? '
      'AND embedding IS NOT NULL ORDER BY rowid LIMIT ?',
      <Object?>[
        lastRowId,
        'synthetic-minilm',
        localEmbeddingDimensions,
        pageSize,
      ],
    );
    if (rows.isEmpty) break;
    for (final row in rows) {
      lastRowId = row['rowid'] as int;
      final distance = encodedCosineDistance(
        query,
        magnitude,
        row['embedding'] as Uint8List,
      );
      if (distance != null) {
        matches.offer(row['clip_id'] as String, distance);
      }
    }
    if (rows.length < pageSize) break;
    await Future<void>.delayed(Duration.zero);
  }
  return matches.sorted();
}
