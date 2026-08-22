import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cliptown_app/history/capture_policy.dart';
import 'package:cliptown_app/history/clipboard_snapshot.dart';
import 'package:cliptown_app/history/encrypted_clip_repository.dart';
import 'package:cliptown_app/history/local_embedding.dart';
import 'package:cliptown_app/history/sqlite_clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shared local-history fixture passes the Flutter implementation',
    () async {
      final fixturePath =
          Platform.environment['CLIPTOWN_TANDEM_FIXTURE'] ??
          'test/fixtures/local_history_v1.json';
      final fixture =
          (jsonDecode(await File(fixturePath).readAsString())
                  as Map<Object?, Object?>)
              .cast<String, Object?>();
      expect(fixture['contract'], 'cliptown.local-history.v1');
      expect(fixture['embedding_dimensions'], localEmbeddingDimensions);

      final directory = await Directory.systemTemp.createTemp(
        'cliptown-tandem-contract-',
      );
      final repository = SqliteClipRepository(
        path: '${directory.path}/history.db',
        secretStore: _MemorySecretStore(),
      );
      final store = ClipStore(
        repository: repository,
        policy: CapturePolicy(
          maxHistoryItems: fixture['history_limit']! as int,
        ),
      );
      addTearDown(() async {
        store.dispose();
        await repository.clear();
        await directory.delete(recursive: true);
      });
      await store.initialize();

      for (final encodedClip in fixture['clips']! as List<Object?>) {
        final clip = (encodedClip! as Map<Object?, Object?>)
            .cast<String, Object?>();
        switch (clip['kind']) {
          case 'text':
            final result = await store.capture(
              ClipboardSnapshot.text(
                text: clip['text']! as String,
                html: clip['html'] as String?,
              ),
            );
            if (clip['pinned'] == true) {
              await store.togglePinned(result.item!.id);
            }
          case 'image_png':
            await store.capture(
              ClipboardSnapshot.image(
                data: Uint8List.fromList(
                  base64Decode(clip['base64']! as String),
                ),
                mimeType: 'image/png',
              ),
            );
          case 'files':
            await store.capture(
              ClipboardSnapshot.files(
                fileUris: (clip['uris']! as List<Object?>).cast<String>(),
              ),
            );
          default:
            fail('unknown tandem fixture clip kind');
        }
      }

      final expected = (fixture['expected']! as Map<Object?, Object?>)
          .cast<String, Object?>();
      store.setQuery(fixture['lexical_query']! as String);
      expect(store.clips, hasLength(expected['stored_items']! as int));
      expect(
        store.clips.where((clip) => clip.pinned),
        hasLength(expected['pinned_items']! as int),
      );
      expect(store.visibleClips, hasLength(expected['lexical_hits']! as int));
      expect(
        await repository.semanticSearchIds(fixture['vector_query']! as String),
        hasLength(expected['vector_hits']! as int),
      );
      expect(
        await repository.embeddingCount(),
        expected['embedding_rows']! as int,
      );
    },
  );
}

class _MemorySecretStore implements VaultSecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
