import 'dart:convert';
import 'dart:typed_data';

import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/history/encrypted_clip_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  late _MemorySecretStore secrets;
  late _MemoryFileStore file;
  late EncryptedClipRepository repository;

  setUp(() {
    secrets = _MemorySecretStore();
    file = _MemoryFileStore();
    repository = EncryptedClipRepository(secretStore: secrets, fileStore: file);
  });

  test('round trips clips without writing plaintext content', () async {
    final clips = demoClipItems();
    await repository.save(clips);

    final envelope = utf8.decode(file.bytes!);
    expect(envelope, isNot(contains('kubectl rollout status')));
    expect(envelope, isNot(contains('Random account master key')));
    expect(envelope, contains(encryptedClipVaultAlgorithm));
    expect(secrets.values, hasLength(1));

    final loaded = await repository.load();
    expect(
      loaded.map((item) => item.toJson()),
      clips.map((item) => item.toJson()),
    );
  });

  test('tampered ciphertext is rejected instead of reset or exposed', () async {
    await repository.save(demoClipItems());
    final envelope =
        (jsonDecode(utf8.decode(file.bytes!)) as Map<Object?, Object?>)
            .cast<String, Object?>();
    final cipherText = base64Decode(envelope['ciphertext']! as String);
    cipherText[0] ^= 0xff;
    envelope['ciphertext'] = base64Encode(cipherText);
    file.bytes = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));

    await expectLater(
      repository.load(),
      throwsA(isA<ClipRepositoryException>()),
    );
  });

  test('missing secure key fails closed when a vault exists', () async {
    await repository.save(demoClipItems());
    secrets.values.clear();

    await expectLater(
      repository.load(),
      throwsA(
        isA<ClipRepositoryException>().having(
          (error) => error.message,
          'message',
          contains('key is unavailable'),
        ),
      ),
    );
  });

  test('clear removes encrypted data and wrapping key', () async {
    await repository.save(demoClipItems());
    await repository.clear();

    expect(file.bytes, isNull);
    expect(secrets.values, isEmpty);
    expect(await repository.load(), isEmpty);
  });
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

class _MemoryFileStore implements VaultFileStore {
  Uint8List? bytes;

  @override
  Future<void> delete() async => bytes = null;

  @override
  Future<Uint8List?> read() async =>
      bytes == null ? null : Uint8List.fromList(bytes!);

  @override
  Future<void> writeAtomically(Uint8List value) async {
    bytes = Uint8List.fromList(value);
  }
}
