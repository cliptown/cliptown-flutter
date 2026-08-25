import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'clip_item.dart';
import 'clip_repository.dart';
import 'encrypted_clip_repository.dart';
import 'local_embedding.dart';

const String _databaseKeyName = 'cliptown.clip-history.sqlite.v1.key';
const int _maxClipCount = 100000;

class SqliteVectorSearchResult {
  const SqliteVectorSearchResult({
    required this.clipId,
    required this.distance,
  });

  final String clipId;
  final double distance;
}

class SqliteClipRepository implements ClipRepository, SemanticClipRepository {
  SqliteClipRepository({
    required this.path,
    required this.secretStore,
    Cipher? keyGenerator,
  }) : _keyGenerator = keyGenerator ?? AesGcm.with256bits();

  final String path;
  final VaultSecretStore secretStore;
  final Cipher _keyGenerator;
  Database? _database;

  @override
  Future<List<ClipItem>> load() async {
    final database = await _open();
    try {
      final rows = database.select(
        'SELECT clip_json FROM clips ORDER BY sort_timestamp DESC, clip_id',
      );
      if (rows.length > _maxClipCount) {
        throw const ClipRepositoryException('SQLite clip count exceeds limit');
      }
      return rows
          .map((row) {
            final encoded = row['clip_json'];
            if (encoded is! String || encoded.length > 16 * 1024 * 1024) {
              throw const FormatException('SQLite clip row is invalid');
            }
            final decoded = jsonDecode(encoded);
            if (decoded is! Map<Object?, Object?>) {
              throw const FormatException('SQLite clip JSON is invalid');
            }
            return ClipItem.fromJson(decoded.cast<String, Object?>());
          })
          .toList(growable: false);
    } on ClipRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw ClipRepositoryException(
        'encrypted SQLite vault read failed',
        error,
      );
    }
  }

  @override
  Future<void> save(List<ClipItem> clips) async {
    if (clips.length > _maxClipCount) {
      throw const ClipRepositoryException('clip count exceeds SQLite limit');
    }
    final database = await _open();
    try {
      database.execute('BEGIN IMMEDIATE');
      database.execute('DELETE FROM clip_embeddings');
      database.execute('DELETE FROM clips');
      final clipStatement = database.prepare('''
        INSERT INTO clips (
          clip_id, kind, title, search_text, clip_json, sort_timestamp, pinned
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ''');
      final embeddingStatement = database.prepare('''
        INSERT INTO clip_embeddings (
          clip_id, model_id, dimensions, embedding, created_at
        ) VALUES (?, ?, ?, ?, ?)
      ''');
      try {
        for (final clip in clips) {
          clip.validate();
          final searchText = clip.searchableText;
          clipStatement.execute(<Object?>[
            clip.id,
            clip.kind.name,
            clip.title,
            searchText,
            jsonEncode(clip.toJson()),
            clip.sortTimestamp.toUtc().toIso8601String(),
            clip.pinned ? 1 : 0,
          ]);
          if (clip.text != null && clip.text!.trim().isNotEmpty) {
            embeddingStatement.execute(<Object?>[
              clip.id,
              localEmbeddingModel,
              localEmbeddingDimensions,
              encodeLocalEmbedding(createLocalEmbedding(clip.text!)),
              DateTime.now().toUtc().toIso8601String(),
            ]);
          }
        }
      } finally {
        clipStatement.close();
        embeddingStatement.close();
      }
      database.execute('COMMIT');
    } on Object catch (error) {
      try {
        database.execute('ROLLBACK');
      } on Object {
        // Preserve the original failure and fail the vault closed.
      }
      throw ClipRepositoryException(
        'encrypted SQLite vault write failed',
        error,
      );
    }
  }

  Future<List<SqliteVectorSearchResult>> vectorSearch(
    String query, {
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 1000) {
      throw const FormatException('vector search limit is out of bounds');
    }
    final database = await _open();
    final queryEmbedding = createLocalEmbedding(query);
    final rows = database.select(
      '''
      SELECT clip_id, embedding
      FROM clip_embeddings
      WHERE model_id = ? AND dimensions = ?
      ''',
      <Object?>[localEmbeddingModel, localEmbeddingDimensions],
    );
    final results = rows
        .map(
          (row) => SqliteVectorSearchResult(
            clipId: row['clip_id'] as String,
            distance: localEmbeddingCosineDistance(
              queryEmbedding,
              decodeLocalEmbedding(row['embedding'] as Uint8List),
            ),
          ),
        )
        .toList();
    results.sort((left, right) {
      final byDistance = left.distance.compareTo(right.distance);
      return byDistance != 0 ? byDistance : left.clipId.compareTo(right.clipId);
    });
    return results.take(limit).toList(growable: false);
  }

  @override
  Future<List<String>> semanticSearchIds(String query, {int limit = 20}) async {
    final results = await vectorSearch(query, limit: limit);
    return results
        .where((result) => result.distance <= 0.72)
        .map((result) => result.clipId)
        .toList(growable: false);
  }

  Future<int> embeddingCount() async {
    final rows = (await _open()).select(
      'SELECT count(*) AS count FROM clip_embeddings',
    );
    return rows.single['count'] as int;
  }

  @override
  Future<void> clear() async {
    final database = _database;
    _database = null;
    database?.close();
    try {
      for (final suffix in <String>['', '-wal', '-shm']) {
        final file = File('$path$suffix');
        if (await file.exists()) await file.delete();
      }
      await secretStore.delete(_databaseKeyName);
    } on Object catch (error) {
      throw ClipRepositoryException(
        'encrypted SQLite vault clear failed',
        error,
      );
    }
  }

  Future<Database> _open() async {
    if (_database case final database?) return database;
    try {
      final key = await _readOrCreateKey();
      final file = File(path);
      await file.parent.create(recursive: true);
      final database = sqlite3.open(path);
      final keyHex = key
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      database.execute("PRAGMA cipher = 'sqlcipher'");
      database.execute("PRAGMA key = \"x'$keyHex'\"");
      final cipherVersion = database.select('PRAGMA cipher_version');
      final multipleCiphers = database.select('PRAGMA cipher');
      if (cipherVersion.isEmpty && multipleCiphers.isEmpty) {
        database.close();
        throw const ClipRepositoryException(
          'SQLite encryption provider is unavailable; refusing plaintext storage',
        );
      }
      database.execute('PRAGMA foreign_keys = ON');
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      database.execute('PRAGMA trusted_schema = OFF');
      database.execute('''
        CREATE TABLE IF NOT EXISTS clips (
          clip_id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          title TEXT NOT NULL,
          search_text TEXT NOT NULL,
          clip_json TEXT NOT NULL,
          sort_timestamp TEXT NOT NULL,
          pinned INTEGER NOT NULL CHECK (pinned IN (0, 1))
        ) STRICT
      ''');
      database.execute('''
        CREATE TABLE IF NOT EXISTS clip_embeddings (
          id INTEGER PRIMARY KEY,
          clip_id TEXT NOT NULL UNIQUE REFERENCES clips(clip_id) ON DELETE CASCADE,
          model_id TEXT NOT NULL,
          dimensions INTEGER NOT NULL,
          embedding BLOB NOT NULL,
          created_at TEXT NOT NULL
        ) STRICT
      ''');
      database.select('SELECT count(*) FROM clips');
      _database = database;
      return database;
    } on ClipRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw ClipRepositoryException(
        'encrypted SQLite vault could not be opened',
        error,
      );
    }
  }

  Future<List<int>> _readOrCreateKey() async {
    final existing = await secretStore.read(_databaseKeyName);
    if (existing != null) {
      final decoded = base64Decode(existing);
      if (decoded.length != 32) {
        throw const ClipRepositoryException('SQLite vault key is invalid');
      }
      return decoded;
    }
    if (await File(path).exists()) {
      throw const ClipRepositoryException(
        'SQLite vault key is missing; refusing destructive recovery',
      );
    }
    final key = await _keyGenerator.newSecretKey();
    final bytes = await key.extractBytes();
    await secretStore.write(_databaseKeyName, base64Encode(bytes));
    return bytes;
  }
}

Future<SqliteClipRepository> createPlatformSqliteClipRepository() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final path = <String>[
    supportDirectory.path,
    'ClipTown',
    'clip-history.v1.db',
  ].join(Platform.pathSeparator);
  return SqliteClipRepository(
    path: path,
    secretStore: FlutterSecureVaultSecretStore(),
  );
}
