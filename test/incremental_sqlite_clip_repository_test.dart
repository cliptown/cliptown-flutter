import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cliptown_app/history/cache/clip_write_plan.dart';
import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/encrypted_clip_repository.dart';
import 'package:cliptown_app/history/sqlite_clip_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'test_support.dart';

void main() {
  late Directory directory;
  late String path;
  late _TestSecrets secrets;
  late SqliteClipRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'cliptown-incremental-test-',
    );
    path = '${directory.path}/history.db';
    secrets = _TestSecrets();
    repository = SqliteClipRepository(path: path, secretStore: secrets);
  });

  tearDown(() async {
    await repository.clear();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  test('a pin or rename updates one row without rebuilding embeddings', () async {
    final clips = demoClipItems();
    await repository.save(clips);
    expect(repository.lastWriteStats().inserted, clips.length);
    expect(repository.lastWriteStats().embeddingsRebuilt, 2);

    final db = _openEncrypted(path, secrets);
    final before = db.select(
      'SELECT id, embedding, created_at FROM clip_embeddings '
      "WHERE clip_id = 'deploy-command'",
    ).single;
    final id = before['id'] as int;
    final embedded = Uint8List.fromList(before['embedding'] as Uint8List);
    final createdAt = before['created_at'] as String;

    final updated = <ClipItem>[
      clips.first.copyWith(pinned: false, title: 'Deployment link'),
      ...clips.skip(1),
    ];
    await repository.save(updated);
    final stats = repository.lastWriteStats();
    expect(stats.inserted, 0);
    expect(stats.updated, 1);
    expect(stats.deleted, 0);
    expect(stats.embeddingsRebuilt, 0);
    final after = db.select(
      'SELECT id, embedding, created_at FROM clip_embeddings '
      "WHERE clip_id = 'deploy-command'",
    ).single;
    expect(after['id'], id);
    expect(after['embedding'] as Uint8List, orderedEquals(embedded));
    expect(after['created_at'], createdAt);

    await repository.save(updated);
    expect(repository.lastWriteStats().changedRows, 0);
    expect(repository.lastWriteStats().embeddingsRebuilt, 0);

    // Equivalent-but-distinct immutable instances must also be no-ops.
    await repository.save(<ClipItem>[
      ClipItem.fromJson(updated.first.toJson()),
      ...updated.skip(1),
    ]);
    expect(repository.lastWriteStats().changedRows, 0);
    db.close();
  });

  test('text edits rebuild only the edited embedding and persist new text', () async {
    final clips = demoClipItems();
    await repository.save(clips);
    final existing = clips.first;
    final edited = ClipItem(
      id: existing.id,
      kind: existing.kind,
      title: existing.title,
      text: 'systemctl restart cliptown-worker',
      createdAt: existing.createdAt,
      lastUsedAt: existing.lastUsedAt,
      pinned: existing.pinned,
      tags: existing.tags,
      collection: existing.collection,
    );
    await repository.save(<ClipItem>[edited, ...clips.skip(1)]);

    expect(repository.lastWriteStats().updated, 1);
    expect(repository.lastWriteStats().embeddingsRebuilt, 1);
    expect(await repository.embeddingCount(), 2);
    expect(
      (await repository.load()).first.text,
      'systemctl restart cliptown-worker',
    );
    expect(
      utf8.decode(await File(path).readAsBytes(), allowMalformed: true),
      isNot(contains('systemctl restart')),
    );
  });

  test('deletions cascade to embeddings without rewriting the survivors', () async {
    final clips = demoClipItems();
    await repository.save(clips);
    await repository.save(clips.where((clip) =>
        clip.id != 'security-notes').toList());

    expect(repository.lastWriteStats().deleted, 1);
    expect(repository.lastWriteStats().updated, 0);
    expect(repository.lastWriteStats().inserted, 0);
    expect(await repository.embeddingCount(), 1);
    expect((await repository.load()).map((clip) => clip.id),
        isNot(contains('security-notes')));
  });

  test('a duplicate ID rejects the entire replacement without data loss', () async {
    final clips = demoClipItems();
    await repository.save(clips);
    await expectLater(
      repository.save(<ClipItem>[...clips, clips.first]),
      throwsA(isA<ClipRepositoryException>()),
    );
    expect(
      (await repository.load()).map((clip) => clip.toJson()),
      clips.map((clip) => clip.toJson()),
    );
    await repository.save(clips);
    expect(repository.lastWriteStats().changedRows, 0);
  });

  test('a failure after a successful SQL UPDATE rolls back atomically', () async {
    final clips = demoClipItems();
    await repository.save(clips);
    final db = _openEncrypted(path, secrets);
    db.execute('''
      CREATE TRIGGER forbid_second_clip
      BEFORE UPDATE ON clips
      WHEN NEW.clip_id = 'design-reference'
      BEGIN SELECT RAISE(FAIL, 'blocked for rollback test'); END
    ''');
    await expectLater(
      repository.save(<ClipItem>[
        clips.first.copyWith(title: 'should never commit'),
        clips[1].copyWith(title: 'trigger failure'),
        clips.last,
      ]),
      throwsA(isA<ClipRepositoryException>()),
    );

    expect(
      (await repository.load()).map((clip) => clip.toJson()),
      clips.map((clip) => clip.toJson()),
      reason: 'earlier changed rows must roll back with the failed statement',
    );
    db.execute('DROP TRIGGER forbid_second_clip');
    db.close();
    await repository.save(<ClipItem>[
      clips.first.copyWith(title: 'valid after rollback'),
      ...clips.skip(1),
    ]);
    expect(repository.lastWriteStats().updated, 1);
  });

  test('an external database update invalidates a cached snapshot', () async {
    final clips = demoClipItems();
    await repository.save(clips);
    final db = _openEncrypted(path, secrets);
    db.execute(
      "UPDATE clips SET title = 'external title' "
      "WHERE clip_id = 'deploy-command'",
    );
    db.close();

    // Complete in-memory history is authoritative. A data_version mismatch
    // must re-read existing rows and restore the originally requested title.
    await repository.save(clips);
    expect(repository.lastWriteStats().updated, 1);
    expect((await repository.load()).first.title, clips.first.title);
  });

  test('desktop mode drops obsolete legacy vector rows on first save', () async {
    await repository.save(demoClipItems());
    expect(await repository.embeddingCount(), 2);

    final desktop = SqliteClipRepository(
      path: path,
      secretStore: secrets,
      generateLegacyEmbeddings: false,
    );
    await desktop.save(demoClipItems());
    expect(await desktop.embeddingCount(), 0);
    // The underlying history stays encrypted and readable.
    expect(await desktop.load(), hasLength(3));
  });

  test('planner accepts equivalent immutable clips and detects metadata edits', () {
    final clips = demoClipItems();
    final before = <String, ClipItem>{for (final clip in clips) clip.id: clip};
    final equivalent = clips.map((clip) => ClipItem.fromJson(clip.toJson())).toList();
    expect(planClipWrites(before, equivalent).affectedRows, 0);
    final edited = <ClipItem>[
      clips.first.copyWith(collection: 'New group'),
      clips.last,
    ];
    final plan = planClipWrites(before, edited);
    expect(plan.inserted, isEmpty);
    expect(plan.updated.map((clip) => clip.id), <String>['deploy-command']);
    expect(plan.deletedIds, <String>['design-reference']);
  });
}

Database _openEncrypted(String path, _TestSecrets secrets) {
  final key = base64Decode(secrets.values.values.single);
  final keyHex = key.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final db = sqlite3.open(path);
  db.execute("PRAGMA cipher = 'sqlcipher'");
  db.execute('PRAGMA key = "x\'$keyHex\'"');
  db.execute('PRAGMA foreign_keys = ON');
  return db;
}

final class _TestSecrets implements VaultSecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
