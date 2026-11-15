import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'clip_item.dart';
import 'clip_repository.dart';
import 'local_embedding.dart';
import 'minilm_embedder.dart';

/// A disposable local derivative index. Clipboard history and its encryption
/// remain owned by [history]. Only clip IDs, SHA-256s and vectors are stored
/// here; deleting history also erases the derived index.
final class MiniLmSemanticClipRepository
    implements ClipRepository, SemanticClipRepository, SemanticClipRepositoryUpdates {
  MiniLmSemanticClipRepository({
    required this.history,
    required this.indexPath,
    required this.model,
  });

  final ClipRepository history;
  final String indexPath;
  final LocalTextEmbeddingModel model;

  final LinkedHashMap<String, (String, String)> _pending =
      LinkedHashMap<String, (String, String)>();
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Database? _database;
  Future<void>? _indexing;
  int _generation = 0;
  bool _indexAvailable = true;

  /// Notification allows an already-visible query to refresh as indexing
  /// progresses, instead of requiring the user to retype it.
  @override
  Stream<void> get indexUpdates => _changes.stream;

  @override
  Future<List<ClipItem>> load() async {
    final clips = await history.load();
    _tryReconcile(clips);
    return clips;
  }

  @override
  Future<void> save(List<ClipItem> clips) async {
    // History is authoritative: an optional search index must never make
    // clipboard capture fail or downgrade the existing encrypted vault.
    await history.save(clips);
    _tryReconcile(clips);
  }

  void _tryReconcile(List<ClipItem> clips) {
    if (!_indexAvailable) return;
    try {
      _reconcile(clips);
    } on Object {
      _indexAvailable = false;
      _pending.clear();
      _database?.close();
      _database = null;
    }
  }

  Database _open() {
    if (_database case final database?) return database;
    final parent = Directory(File(indexPath).parent.path);
    parent.createSync(recursive: true);
    final database = sqlite3.open(indexPath);
    try {
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA trusted_schema = OFF');
      database.execute('''
        CREATE TABLE IF NOT EXISTS vectors (
          clip_id TEXT PRIMARY KEY,
          source_hash TEXT NOT NULL,
          model_id TEXT NOT NULL,
          dimensions INTEGER NOT NULL CHECK (dimensions = 384),
          embedding BLOB,
          indexed_at TEXT
        ) STRICT
      ''');
      database.execute('''
        CREATE TEMP TABLE IF NOT EXISTS _active_clip_ids (
          clip_id TEXT PRIMARY KEY
        )
      ''');
    } on Object {
      database.close();
      rethrow;
    }
    _database = database;
    return database;
  }

  void _reconcile(List<ClipItem> clips) {
    final db = _open();
    final desired = LinkedHashMap<String, (String, String)>();
    final ids = <String>{};
    for (final clip in clips) {
      ids.add(clip.id);
      if (clip.text case final text?) {
        if (text.trim().isNotEmpty) {
          desired[clip.id] = (text, sha256.convert(utf8.encode(text)).toString());
        }
      }
    }

    db.execute('BEGIN IMMEDIATE');
    final active = db.prepare('INSERT INTO _active_clip_ids (clip_id) VALUES (?)');
    final upsert = db.prepare('''
      INSERT INTO vectors (
        clip_id, source_hash, model_id, dimensions, embedding, indexed_at
      ) VALUES (?, ?, ?, ?, NULL, NULL)
      ON CONFLICT(clip_id) DO UPDATE SET
        source_hash = excluded.source_hash,
        model_id = excluded.model_id,
        dimensions = excluded.dimensions,
        embedding = NULL,
        indexed_at = NULL
      WHERE vectors.source_hash != excluded.source_hash
         OR vectors.model_id != excluded.model_id
         OR vectors.dimensions != excluded.dimensions
    ''');
    final missing = db.prepare(
      'SELECT embedding IS NULL AS missing FROM vectors WHERE clip_id = ?',
    );
    try {
      db.execute('DELETE FROM _active_clip_ids');
      for (final id in ids) {
        active.execute(<Object?>[id]);
      }
      db.execute('DELETE FROM vectors WHERE clip_id NOT IN '
          '(SELECT clip_id FROM _active_clip_ids)');
      _pending.clear();
      for (final entry in desired.entries) {
        upsert.execute(<Object?>[
          entry.key,
          entry.value.$2,
          model.modelId,
          localEmbeddingDimensions,
        ]);
        if (missing.select(<Object?>[entry.key]).single['missing'] == 1) {
          _pending[entry.key] = entry.value;
        }
      }
      // Clips that cease to have text must not retain older text vectors.
      // The desired set is smaller than active IDs when images/files exist.
      for (final id in ids.difference(desired.keys.toSet())) {
        db.execute('DELETE FROM vectors WHERE clip_id = ?', <Object?>[id]);
      }
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    } finally {
      active.close();
      upsert.close();
      missing.close();
    }
    _startIndexing();
  }

  void _startIndexing() {
    if (_indexing != null || _pending.isEmpty || !_indexAvailable) return;
    final work = _drain();
    _indexing = work;
    unawaited(work.whenComplete(() {
      _indexing = null;
      if (_pending.isNotEmpty) _startIndexing();
    }));
  }

  Future<void> _drain() async {
    final generation = _generation;
    var indexed = 0;
    while (_pending.isNotEmpty && generation == _generation) {
      final entry = _pending.entries.first;
      _pending.remove(entry.key);
      try {
        final embedding = await model.embed(entry.value.$1);
        if (generation != _generation || !_indexAvailable) break;
        _database?.execute('''
          UPDATE vectors SET embedding = ?, indexed_at = ?
          WHERE clip_id = ? AND source_hash = ?
            AND model_id = ? AND embedding IS NULL
        ''', <Object?>[
          encodeLocalEmbedding(embedding),
          DateTime.now().toUtc().toIso8601String(),
          entry.key,
          entry.value.$2,
          model.modelId,
        ]);
        indexed += 1;
        if (indexed % 8 == 0 && !_changes.isClosed) _changes.add(null);
      } on Object {
        // Model unavailable/offline: leave rows pending for restart or the
        // next mutation. Never replace semantic results with hash embeddings.
        _pending.clear();
        break;
      }
    }
    if (indexed > 0 && !_changes.isClosed) _changes.add(null);
  }

  /// Test seam: await the current backfill without performing network I/O
  /// when a fake embedding model is injected.
  Future<void> waitForIndexing() async {
    while (_indexing case final pending?) {
      await pending;
    }
  }

  Future<List<SqliteMiniLmSearchResult>> vectorSearch(
    String query, {
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 1000) {
      throw const FormatException('vector search limit is out of bounds');
    }
    if (!_indexAvailable || query.trim().isEmpty) return const [];
    final generation = _generation;
    final queryVector = await model.embed(query);
    if (generation != _generation) return const [];
    final rows = _open().select(
      'SELECT clip_id, embedding FROM vectors '
      'WHERE model_id = ? AND dimensions = ? AND embedding IS NOT NULL',
      <Object?>[model.modelId, localEmbeddingDimensions],
    );
    final matches = <SqliteMiniLmSearchResult>[];
    for (final row in rows) {
      try {
        matches.add(SqliteMiniLmSearchResult(
          clipId: row['clip_id'] as String,
          distance: localEmbeddingCosineDistance(
            queryVector,
            decodeLocalEmbedding(row['embedding'] as Uint8List),
          ),
        ));
      } on FormatException {
        // A damaged derived vector never blocks the encrypted history.
      }
    }
    matches.sort((a, b) {
      final distance = a.distance.compareTo(b.distance);
      return distance != 0 ? distance : a.clipId.compareTo(b.clipId);
    });
    return matches.take(limit).toList(growable: false);
  }

  @override
  Future<List<String>> semanticSearchIds(String query, {int limit = 20}) async {
    final matches = await vectorSearch(query, limit: limit);
    // Conservative threshold; tune with evaluation fixtures, not token hashes.
    return matches
        .where((match) => match.distance <= 0.54)
        .map((match) => match.clipId)
        .toList(growable: false);
  }

  /// Close native SQLite resources without erasing the persisted index.
  Future<void> close() async {
    _generation += 1;
    _pending.clear();
    await _indexing;
    _database?.close();
    _database = null;
    await _changes.close();
  }

  Future<int> embeddingCount() async => (_open().select(
    'SELECT count(*) AS count FROM vectors WHERE embedding IS NOT NULL',
  ).single['count'] as int);

  @override
  Future<void> clear() async {
    await history.clear();
    _generation += 1;
    _pending.clear();
    _database?.close();
    _database = null;
    for (final suffix in <String>['', '-wal', '-shm']) {
      final file = File('$indexPath$suffix');
      if (await file.exists()) await file.delete();
    }
    if (!_changes.isClosed) _changes.add(null);
  }
}

Future<MiniLmSemanticClipRepository> createPlatformMiniLmRepository(
  ClipRepository history,
) async {
  final support = await getApplicationSupportDirectory();
  final root = Directory(
    '${support.path}${Platform.pathSeparator}ClipTown',
  );
  return MiniLmSemanticClipRepository(
    history: history,
    indexPath: '${root.path}${Platform.pathSeparator}semantic-minilm-v1.db',
    model: MiniLmOnDeviceEmbedder(
      modelDirectory: Directory(
        '${root.path}${Platform.pathSeparator}models'
        '${Platform.pathSeparator}minilm-l6-v2-q4',
      ),
    ),
  );
}

final class SqliteMiniLmSearchResult {
  const SqliteMiniLmSearchResult({
    required this.clipId,
    required this.distance,
  });

  final String clipId;
  final double distance;
}
