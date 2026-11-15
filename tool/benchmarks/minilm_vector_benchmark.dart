import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cliptown_app/history/cache/bounded_vector_search.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:sqlite3/sqlite3.dart';

/// Synthetic, reproducible local index benchmark; excludes neural inference.
Future<void> main(List<String> args) async {
  final output = args
      .where((arg) => arg.startsWith('--output='))
      .map((arg) => arg.substring('--output='.length))
      .firstOrNull;
  final small = await _runCase(10000);
  final large = await _runCase(100000);
  final report = <String, Object>{
    'benchmark': 'cliptown-offline-minilm-derived-vector-index',
    'native_model_inference_included': false,
    'dimensions': localEmbeddingDimensions,
    'search_top_k': 20,
    'samples_per_case': 5,
    'cases': <Map<String, Object>>[small, large],
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
    final palette = _makePalette();
    final writeClock = Stopwatch()..start();
    _insertRows(db, count, palette);
    writeClock.stop();
    db.execute('PRAGMA wal_checkpoint(TRUNCATE)');

    final query = List<double>.generate(
      localEmbeddingDimensions,
      (index) => (index % 29 + 1) / 30,
      growable: false,
    );
    final magnitude = validEmbeddingMagnitude(query)!;
    final samples = await _measureQueries(db, query, magnitude, 5);
    return <String, Object>{
      'vector_count': count,
      'index_insert_ms': writeClock.elapsedMicroseconds / 1000,
      'query_p50_ms': _medianOfFive(samples),
      'query_p95_ms': samples.reduce((a, b) => a > b ? a : b),
      'sqlite_file_bytes': File(path).lengthSync(),
      'process_rss_bytes': ProcessInfo.currentRss,
    };
  } finally {
    db.close();
    await temporary.delete(recursive: true);
  }
}

List<Uint8List> _makePalette() {
  final random = math.Random(23117);
  return List<Uint8List>.generate(256, (_) {
    final vector = List<double>.generate(
      localEmbeddingDimensions,
      (_) => random.nextDouble() * 2 - 1,
      growable: false,
    );
    return encodeLocalEmbedding(vector);
  });
}

void _insertRows(Database db, int count, List<Uint8List> palette) {
  final insert = db.prepare('''
    INSERT INTO vectors(clip_id, model_id, dimensions, embedding)
    VALUES (?, ?, ?, ?)
  ''');
  db.execute('BEGIN IMMEDIATE');
  try {
    for (final i in Iterable<int>.generate(count)) {
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
}

Future<List<double>> _measureQueries(
  Database db,
  List<double> query,
  double magnitude,
  int remaining,
) async {
  if (remaining == 0) return const <double>[];
  final timer = Stopwatch()..start();
  final matches = await _scanPage(
    db,
    query,
    magnitude,
    0,
    BoundedVectorSearch(20),
  );
  timer.stop();
  if (matches.retainedCount() != 20) {
    return Future<List<double>>.error(
      StateError('Expected exactly 20 ranked search results'),
    );
  }
  final more = await _measureQueries(db, query, magnitude, remaining - 1);
  return <double>[timer.elapsedMicroseconds / 1000, ...more];
}

double _medianOfFive(List<double> values) {
  // Select the middle order statistic without mutating the sample list.
  return values.firstWhere((value) {
    final below = values.where((sample) => sample < value).length;
    final upTo = values.where((sample) => sample <= value).length;
    return below <= 2 && upTo >= 3;
  });
}

Future<BoundedVectorSearch> _scanPage(
  Database db,
  List<double> query,
  double magnitude,
  int lastRowId,
  BoundedVectorSearch matches,
) async {
  const pageSize = 256;
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
  if (rows.isEmpty) return matches;
  for (final row in rows) {
    final distance = encodedCosineDistance(
      query,
      magnitude,
      row['embedding'] as Uint8List,
    );
    if (distance != null) {
      matches.offer(row['clip_id'] as String, distance);
    }
  }
  if (rows.length < pageSize) return matches;
  await Future<void>.delayed(Duration.zero);
  return _scanPage(db, query, magnitude, rows.last['rowid'] as int, matches);
}
