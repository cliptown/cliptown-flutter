import 'dart:convert';
import 'dart:io';

import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/encrypted_clip_repository.dart';
import 'package:cliptown_app/history/sqlite_clip_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  late Directory temporaryDirectory;
  late String databasePath;
  late _MemorySecretStore secrets;
  late SqliteClipRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'cliptown-sqlite-test-',
    );
    databasePath = '${temporaryDirectory.path}/history.db';
    secrets = _MemorySecretStore();
    repository = SqliteClipRepository(path: databasePath, secretStore: secrets);
  });

  tearDown(() async {
    try {
      await repository.clear();
    } on Object {
      // The fail-closed tests intentionally make the key unavailable.
    }
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('round trips rich clips and persists text vectors in SQLite', () async {
    final clips = demoClipItems();
    await repository.save(clips);

    expect(
      (await repository.load()).map((item) => item.toJson()),
      clips.map((item) => item.toJson()),
    );
    expect(await repository.embeddingCount(), 2);

    final results = await repository.vectorSearch('kubectl deployment');
    expect(results, isNotEmpty);
    expect(results.first.clipId, 'deploy-command');
  });

  test('encrypts the SQLite file and never stores plaintext content', () async {
    await repository.save(demoClipItems());
    final bytes = await File(databasePath).readAsBytes();
    final sqliteHeader = utf8.encode('SQLite format 3\u0000');

    expect(bytes.take(sqliteHeader.length), isNot(orderedEquals(sqliteHeader)));
    expect(
      utf8.decode(bytes, allowMalformed: true),
      isNot(contains('kubectl')),
    );
    expect(secrets.values, hasLength(1));
  });

  test(
    'missing key fails closed instead of replacing an existing vault',
    () async {
      await repository.save(demoClipItems());
      secrets.values.clear();
      final secondRepository = SqliteClipRepository(
        path: databasePath,
        secretStore: secrets,
      );

      await expectLater(
        secondRepository.load(),
        throwsA(
          isA<ClipRepositoryException>().having(
            (error) => error.message,
            'message',
            contains('key is missing'),
          ),
        ),
      );
    },
  );
}

class _MemorySecretStore implements VaultSecretStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}
