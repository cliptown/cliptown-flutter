import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../clip_item.dart';
import '../clip_repository.dart';
import '../local_embedding.dart';
import 'bounded_vector_search.dart';
import 'minilm_embedder.dart';

/// A disposable local derivative index. Clipboard history and its encryption
/// remain owned by [history]. Only clip IDs, SHA-256s and vectors are stored
/// here; deleting history also erases the derived index.
final class MiniLmSemanticClipRepository
    implements
        ClipRepository,
        SemanticClipRepository,
        SemanticClipRepositoryUpdates,
        SemanticIndexProgressSource,
        ClosableClipRepository {
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
  final StreamController<SemanticIndexProgress> _progressChanges =
      StreamController<SemanticIndexProgress>.broadcast();
  SemanticIndexProgress _progress = const SemanticIndexProgress(
    phase: SemanticIndexPhase.preparing,
    indexed: 0,
    total: 0,
  );
  int _totalVectors = 0;
  int _indexedVectors = 0;
  // Reuse query embeddings while the backfill changes index revisions.
  // Bounded LRU: query text must not grow indefinitely in process memory.
  final LinkedHashMap<String, Future<List<double>>> _queryEmbeddings =
      LinkedHashMap<String, Future<List<double>>>();
  Database? _database;
  Future<void>? _indexing;
  Future<void>? _closing;
  int _generation = 0;
  bool _indexAvailable = true;
  Map<String, (String, String)> _lastDesired = const {};
  bool _hasIndexedSnapshot = false;
  bool _needsRecovery = false;

  /// Notification allows an already-visible query to refresh as indexing
  /// progresses, instead of requiring the user to retype it.
  @override
  Stream<void> get indexUpdates => _changes.stream;

  @override
  SemanticIndexProgress get indexProgress => _progress;

  @override
  Stream<SemanticIndexProgress> get indexProgressUpdates =>
      _progressChanges.stream;

  void _publishProgress(SemanticIndexProgress next) {
    final current = _progress;
    if (current.phase == next.phase &&
        current.indexed == next.indexed &&
        current.total == next.total &&
        current.downloadPercent == next.downloadPercent) {
      return;
    }
    _progress = next;
    if (!_progressChanges.isClosed) _progressChanges.add(next);
  }

  void _reportIndexProgress() {
    _publishProgress(SemanticIndexProgress(
      phase: _indexedVectors >= _totalVectors
          ? SemanticIndexPhase.ready
          : SemanticIndexPhase.indexing,
      indexed: _indexedVectors,
      total: _totalVectors,
    ));
  }

  /// Called only by the local native model's weight download callback.
  void reportModelDownloadProgress(int bytes, int? expectedBytes) {
    if (!_indexAvailable || _closing != null) return;
    final percent = expectedBytes != null && expectedBytes > 0
        ? (100 * bytes ~/ expectedBytes).clamp(0, 100).toInt()
        : null;
    _publishProgress(SemanticIndexProgress(
      phase: SemanticIndexPhase.downloading,
      indexed: _indexedVectors,
      total: _totalVectors,
      downloadPercent: percent,
    ));
  }

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
      _lastDesired = const {};
      _hasIndexedSnapshot = false;
      _database?.close();
      _database = null;
      _publishProgress(SemanticIndexProgress(
        phase: SemanticIndexPhase.unavailable,
        indexed: _indexedVectors,
        total: _totalVectors,
      ));
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
        CREATE INDEX IF NOT EXISTS idx_vectors_corrupt_embedding
        ON vectors (clip_id)
        WHERE embedding IS NOT NULL AND length(embedding) != 1536
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
    final desired = <String, (String, String)>{};
    for (final clip in clips) {
      if (clip.text case final text?) {
        if (text.trim().isNotEmpty) {
          final previous = _lastDesired[clip.id];
          desired[clip.id] = (
            text,
            previous != null && previous.$1 == text
                ? previous.$2
                : sha256.convert(utf8.encode(text)).toString(),
          );
        }
      }
    }
    var changed = !_hasIndexedSnapshot || desired.length != _lastDesired.length;
    if (!changed) {
      for (final entry in desired.entries) {
        if (_lastDesired[entry.key]?.$2 != entry.value.$2) {
          changed = true;
          break;
        }
      }
    }
    // Pinning and mark-used saves never rebuild a 100k-row SQLite index.
    // A sparse partial index makes externally truncated blobs detectable
    // without scanning every healthy vector on each save.
    if (!changed && !_needsRecovery) {
      final corrupt = _open().select(
        'SELECT clip_id FROM vectors '
        'WHERE embedding IS NOT NULL AND length(embedding) != 1536 '
        'LIMIT 1',
      );
      if (corrupt.isEmpty) {
        _startIndexing();
        return;
      }
    }
    final db = _open();
    db.execute('BEGIN IMMEDIATE');
    try {
      _applyDesiredIndex(db, desired);
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
    _lastDesired = desired;
    _hasIndexedSnapshot = true;
    _needsRecovery = false;
    _totalVectors = desired.length;
    _indexedVectors = desired.length - _pending.length;
    _reportIndexProgress();
    // Invalidate query and indexing work started against an older clip set.
    _generation += 1;
    _startIndexing();
  }

  void _applyDesiredIndex(Database db, Map<String, (String, String)> desired) {
    final active = db.prepare(
      'INSERT INTO _active_clip_ids (clip_id) VALUES (?)',
    );
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
    try {
      db.execute('DELETE FROM _active_clip_ids');
      for (final id in desired.keys) {
        active.execute(<Object?>[id]);
      }
      db.execute(
        'DELETE FROM vectors WHERE clip_id NOT IN '
        '(SELECT clip_id FROM _active_clip_ids)',
      );
      // Rebuild truncated/corrupt blobs even if the clip text was unchanged.
      db.execute(
        'UPDATE vectors SET embedding = NULL, indexed_at = NULL '
        'WHERE embedding IS NOT NULL AND length(embedding) != ?',
        <Object?>[localEmbeddingDimensions * Float32List.bytesPerElement],
      );
      _pending.clear();
      for (final entry in desired.entries) {
        upsert.execute(<Object?>[
          entry.key,
          entry.value.$2,
          model.modelId,
          localEmbeddingDimensions,
        ]);
      }
      // One query replaces a SELECT per clip, keeping 100k-item vaults viable.
      final missingIds = db
          .select('SELECT clip_id FROM vectors WHERE embedding IS NULL')
          .map((row) => row['clip_id'] as String)
          .toSet();
      for (final entry in desired.entries) {
        if (missingIds.contains(entry.key)) {
          _pending[entry.key] = entry.value;
        }
      }
    } finally {
      active.close();
      upsert.close();
    }
  }

  void _startIndexing() {
    if (_indexing != null || _pending.isEmpty || !_indexAvailable) return;
    final work = _drain();
    _indexing = work;
    unawaited(
      work.whenComplete(() {
        _indexing = null;
        if (_pending.isNotEmpty) _startIndexing();
      }),
    );
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
        _database?.execute(
          '''
          UPDATE vectors SET embedding = ?, indexed_at = ?
          WHERE clip_id = ? AND source_hash = ?
            AND model_id = ? AND embedding IS NULL
        ''',
          <Object?>[
            encodeLocalEmbedding(embedding),
            DateTime.now().toUtc().toIso8601String(),
            entry.key,
            entry.value.$2,
            model.modelId,
          ],
        );
        indexed += 1;
        _indexedVectors += 1;
        if (indexed % 8 == 0 || _pending.isEmpty) _reportIndexProgress();
        if (indexed % 8 == 0 && !_changes.isClosed) _changes.add(null);
      } on Object {
        // Model unavailable/offline: leave rows pending for restart or the
        // next mutation. Never replace semantic results with hash embeddings.
        _needsRecovery = true;
        _pending.clear();
        _publishProgress(SemanticIndexProgress(
          phase: SemanticIndexPhase.unavailable,
          indexed: _indexedVectors,
          total: _totalVectors,
        ));
        break;
      }
    }
    if (indexed > 0 && !_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> retrySemanticIndex() async {
    if (!_indexAvailable || _closing != null) return;
    _needsRecovery = true;
    _tryReconcile(await history.load());
  }

  /// Test seam: await the current backfill without performing network I/O
  /// when a fake embedding model is injected.
  Future<void> waitForIndexing() async {
    while (_indexing != null) {
      await _indexing;
    }
  }

  /// A successful query can recover an earlier offline-first backfill.
  /// Read plaintext only from the already-unlocked authoritative vault.
  Future<void> _resumeUnindexedAfterRecovery(int generation) async {
    if (!_indexAvailable || _indexing != null || _pending.isNotEmpty) return;
    final db = _database;
    if (db == null ||
        db
            .select('SELECT 1 FROM vectors WHERE embedding IS NULL LIMIT 1')
            .isEmpty) {
      return;
    }
    final clips = await history.load();
    if (generation != _generation ||
        !_indexAvailable ||
        _indexing != null ||
        _pending.isNotEmpty) {
      return;
    }
    _tryReconcile(clips);
  }

  Future<List<double>> _embedQuery(String query) {
    final cached = _queryEmbeddings.remove(query);
    if (cached != null) {
      _queryEmbeddings[query] = cached;
      return cached;
    }
    final pending = model.embed(query);
    _queryEmbeddings[query] = pending;
    if (_queryEmbeddings.length > 6) {
      _queryEmbeddings.remove(_queryEmbeddings.keys.first);
    }
    // Do not cache failed/offline model loads: a subsequent search must retry.
    unawaited(
      pending.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_queryEmbeddings[query], pending)) {
            _queryEmbeddings.remove(query);
          }
        },
      ),
    );
    return pending;
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
    final queryVector = await _embedQuery(query);
    if (generation != _generation) return const [];
    await _resumeUnindexedAfterRecovery(generation);
    if (generation != _generation || !_indexAvailable) return const [];
    final magnitude = validEmbeddingMagnitude(queryVector);
    if (magnitude == null) return const [];
    final topK = BoundedVectorSearch(limit);
    // SQLite rowid pagination keeps memory bounded even for 100k 384-float
    // vectors. Yield between batches so rendering and input remain responsive.
    var lastRowId = 0;
    const batchSize = 256;
    while (true) {
      if (generation != _generation || !_indexAvailable) return const [];
      final rows = _open().select(
        'SELECT rowid, clip_id, embedding FROM vectors '
        'WHERE rowid > ? AND model_id = ? AND dimensions = ? '
        'AND embedding IS NOT NULL ORDER BY rowid LIMIT ?',
        <Object?>[
          lastRowId,
          model.modelId,
          localEmbeddingDimensions,
          batchSize,
        ],
      );
      if (rows.isEmpty) break;
      for (final row in rows) {
        lastRowId = row['rowid'] as int;
        final distance = encodedCosineDistance(
          queryVector,
          magnitude,
          row['embedding'] as Uint8List,
        );
        if (distance != null) {
          topK.offer(row['clip_id'] as String, distance);
        }
      }
      if (rows.length < batchSize) break;
      await Future<void>.delayed(Duration.zero);
    }
    if (generation != _generation || !_indexAvailable) return const [];
    return topK
        .sorted()
        .map(
          (match) => SqliteMiniLmSearchResult(
            clipId: match.clipId,
            distance: match.distance,
          ),
        )
        .toList(growable: false);
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
  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    _indexAvailable = false;
    _generation += 1;
    _pending.clear();
    _queryEmbeddings.clear();
    await _indexing;
    _database?.close();
    _database = null;
    await _changes.close();
    await _progressChanges.close();
    if (model case final DisposableLocalTextEmbeddingModel disposable) {
      await disposable.dispose();
    }
  }

  Future<int> embeddingCount() async =>
      (_open()
              .select(
                'SELECT count(*) AS count FROM vectors WHERE embedding IS NOT NULL',
              )
              .single['count']
          as int);

  @override
  Future<void> clear() async {
    if (_closing case final pending?) await pending;
    await history.clear();
    _generation += 1;
    _pending.clear();
    _lastDesired = const {};
    _hasIndexedSnapshot = false;
    _needsRecovery = false;
    _queryEmbeddings.clear();
    _database?.close();
    _database = null;
    for (final suffix in <String>['', '-wal', '-shm']) {
      final file = File('$indexPath$suffix');
      if (await file.exists()) await file.delete();
    }
    _totalVectors = 0;
    _indexedVectors = 0;
    _reportIndexProgress();
    if (!_changes.isClosed) _changes.add(null);
  }
}

Future<MiniLmSemanticClipRepository> createPlatformMiniLmRepository(
  ClipRepository history,
) async {
  final support = await getApplicationSupportDirectory();
  final root = Directory('${support.path}${Platform.pathSeparator}ClipTown');
  late final MiniLmSemanticClipRepository repository;
  final embedder = MiniLmOnDeviceEmbedder(
    modelDirectory: Directory(
      '${root.path}${Platform.pathSeparator}models'
      '${Platform.pathSeparator}minilm-l6-v2-q4',
    ),
    onDownloadProgress: (bytes, expected) =>
        repository.reportModelDownloadProgress(bytes, expected),
  );
  repository = MiniLmSemanticClipRepository(
    history: history,
    indexPath: '${root.path}${Platform.pathSeparator}semantic-minilm-v1.db',
    model: embedder,
  );
  return repository;
}

final class SqliteMiniLmSearchResult {
  const SqliteMiniLmSearchResult({
    required this.clipId,
    required this.distance,
  });

  final String clipId;
  final double distance;
}
