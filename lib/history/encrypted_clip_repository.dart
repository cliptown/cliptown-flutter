import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'clip_item.dart';
import 'clip_repository.dart';

const int encryptedClipVaultSchemaVersion = 1;
const String encryptedClipVaultAlgorithm = 'AES-256-GCM';
const String _defaultVaultKeyName = 'cliptown.clip-history.v1.key';
const int _maxVaultBytes = 64 * 1024 * 1024;
const List<int> _vaultAad = <int>[
  99,
  108,
  105,
  112,
  116,
  111,
  119,
  110,
  45,
  104,
  105,
  115,
  116,
  111,
  114,
  121,
  45,
  118,
  49,
]; // "cliptown-history-v1"

abstract interface class VaultSecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

abstract interface class VaultFileStore {
  Future<Uint8List?> read();

  Future<void> writeAtomically(Uint8List bytes);

  Future<void> delete();
}

class EncryptedClipRepository implements ClipRepository {
  EncryptedClipRepository({
    required this.secretStore,
    required this.fileStore,
    Cipher? cipher,
    this.keyName = _defaultVaultKeyName,
  }) : _cipher = cipher ?? AesGcm.with256bits();

  final VaultSecretStore secretStore;
  final VaultFileStore fileStore;
  final Cipher _cipher;
  final String keyName;

  @override
  Future<List<ClipItem>> load() async {
    final encodedEnvelope = await fileStore.read();
    if (encodedEnvelope == null) return <ClipItem>[];
    if (encodedEnvelope.length > _maxVaultBytes) {
      throw const ClipRepositoryException('encrypted vault exceeds size limit');
    }

    try {
      final envelope = _decodeMap(utf8.decode(encodedEnvelope));
      _expectExactEnvelope(envelope);
      final rawKey = await _readExistingKey();
      final nonce = _decodeBytes(envelope, 'nonce', expectedLength: 12);
      final mac = _decodeBytes(envelope, 'mac', expectedLength: 16);
      final cipherText = _decodeBytes(
        envelope,
        'ciphertext',
        maxLength: _maxVaultBytes,
      );
      final clearText = await _cipher.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(rawKey),
        aad: _vaultAad,
      );
      final payload = _decodeMap(utf8.decode(clearText));
      if (payload['schema_version'] != encryptedClipVaultSchemaVersion) {
        throw const FormatException('unsupported clip payload schema');
      }
      final rawClips = payload['clips'];
      if (rawClips is! List<Object?> || rawClips.length > 5000) {
        throw const FormatException('clip payload list is invalid');
      }
      return rawClips
          .map((entry) {
            if (entry is! Map<Object?, Object?>) {
              throw const FormatException('clip payload entry is invalid');
            }
            return ClipItem.fromJson(entry.cast<String, Object?>());
          })
          .toList(growable: false);
    } on ClipRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw ClipRepositoryException(
        'encrypted vault could not be authenticated or decoded',
        error,
      );
    }
  }

  @override
  Future<void> save(List<ClipItem> clips) async {
    if (clips.length > 5000) {
      throw const ClipRepositoryException('clip count exceeds vault limit');
    }
    try {
      final keyBytes = await _readOrCreateKey();
      final payload = utf8.encode(
        jsonEncode(<String, Object?>{
          'schema_version': encryptedClipVaultSchemaVersion,
          'clips': clips.map((item) => item.toJson()).toList(growable: false),
        }),
      );
      if (payload.length > _maxVaultBytes) {
        throw const ClipRepositoryException('clip payload exceeds vault limit');
      }
      final box = await _cipher.encrypt(
        payload,
        secretKey: SecretKey(keyBytes),
        aad: _vaultAad,
      );
      final envelope = utf8.encode(
        jsonEncode(<String, Object?>{
          'schema_version': encryptedClipVaultSchemaVersion,
          'algorithm': encryptedClipVaultAlgorithm,
          'nonce': base64Encode(box.nonce),
          'ciphertext': base64Encode(box.cipherText),
          'mac': base64Encode(box.mac.bytes),
        }),
      );
      await fileStore.writeAtomically(Uint8List.fromList(envelope));
    } on ClipRepositoryException {
      rethrow;
    } on Object catch (error) {
      throw ClipRepositoryException('encrypted vault write failed', error);
    }
  }

  @override
  Future<void> clear() async {
    try {
      await fileStore.delete();
      await secretStore.delete(keyName);
    } on Object catch (error) {
      throw ClipRepositoryException('encrypted vault clear failed', error);
    }
  }

  Future<List<int>> _readExistingKey() async {
    final encoded = await secretStore.read(keyName);
    if (encoded == null) {
      throw const ClipRepositoryException(
        'encrypted vault key is unavailable; refusing plaintext recovery',
      );
    }
    final keyBytes = base64Decode(encoded);
    if (keyBytes.length != 32) {
      throw const ClipRepositoryException('encrypted vault key is invalid');
    }
    return keyBytes;
  }

  Future<List<int>> _readOrCreateKey() async {
    final existing = await secretStore.read(keyName);
    if (existing != null) {
      final decoded = base64Decode(existing);
      if (decoded.length != 32) {
        throw const ClipRepositoryException('encrypted vault key is invalid');
      }
      return decoded;
    }
    final generated = await _cipher.newSecretKey();
    final bytes = await generated.extractBytes();
    if (bytes.length != 32) {
      throw const ClipRepositoryException('cipher generated an invalid key');
    }
    await secretStore.write(keyName, base64Encode(bytes));
    return bytes;
  }
}

class FlutterSecureVaultSecretStore implements VaultSecretStore {
  FlutterSecureVaultSecretStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: false),
            // Ad-hoc debug signatures cannot claim the restricted macOS
            // keychain access-group entitlement. Debug/profile builds still
            // use the encrypted login Keychain; signed releases opt into the
            // data-protection Keychain with provisioned entitlements.
            mOptions: MacOsOptions(usesDataProtectionKeychain: kReleaseMode),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class FileVaultFileStore implements VaultFileStore {
  FileVaultFileStore(this.path);

  final String path;

  @override
  Future<Uint8List?> read() async {
    final primary = File(path);
    final backup = File('$path.backup');
    final source = await primary.exists()
        ? primary
        : await backup.exists()
        ? backup
        : null;
    if (source == null) return null;
    final length = await source.length();
    if (length > _maxVaultBytes) {
      throw const ClipRepositoryException('encrypted vault exceeds size limit');
    }
    return source.readAsBytes();
  }

  @override
  Future<void> writeAtomically(Uint8List bytes) async {
    if (bytes.length > _maxVaultBytes) {
      throw const ClipRepositoryException('encrypted vault exceeds size limit');
    }
    final destination = File(path);
    await destination.parent.create(recursive: true);
    final next = File('$path.next');
    final backup = File('$path.backup');
    if (await next.exists()) await next.delete();
    await next.writeAsBytes(bytes, flush: true);

    if (await backup.exists()) await backup.delete();
    if (await destination.exists()) await destination.rename(backup.path);
    try {
      await next.rename(destination.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (!await destination.exists() && await backup.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    }
  }

  @override
  Future<void> delete() async {
    for (final candidate in <File>[
      File(path),
      File('$path.next'),
      File('$path.backup'),
    ]) {
      if (await candidate.exists()) await candidate.delete();
    }
  }
}

Future<EncryptedClipRepository> createPlatformClipRepository() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final separator = Platform.pathSeparator;
  final path =
      '${supportDirectory.path}${separator}ClipTown${separator}clip-history.v1.json';
  return EncryptedClipRepository(
    secretStore: FlutterSecureVaultSecretStore(),
    fileStore: FileVaultFileStore(path),
  );
}

Map<String, Object?> _decodeMap(String encoded) {
  final value = jsonDecode(encoded);
  if (value is! Map<Object?, Object?>) {
    throw const FormatException('JSON object expected');
  }
  return value.cast<String, Object?>();
}

void _expectExactEnvelope(Map<String, Object?> value) {
  const expectedKeys = <String>{
    'schema_version',
    'algorithm',
    'nonce',
    'ciphertext',
    'mac',
  };
  if (value.keys.toSet().difference(expectedKeys).isNotEmpty ||
      expectedKeys.difference(value.keys.toSet()).isNotEmpty ||
      value['schema_version'] != encryptedClipVaultSchemaVersion ||
      value['algorithm'] != encryptedClipVaultAlgorithm) {
    throw const FormatException('encrypted vault envelope is invalid');
  }
}

List<int> _decodeBytes(
  Map<String, Object?> value,
  String key, {
  int? expectedLength,
  int? maxLength,
}) {
  final encoded = value[key];
  if (encoded is! String) throw FormatException('$key must be base64 text');
  final decoded = base64Decode(encoded);
  if (expectedLength != null && decoded.length != expectedLength) {
    throw FormatException('$key has an invalid length');
  }
  if (maxLength != null && decoded.length > maxLength) {
    throw FormatException('$key exceeds the size limit');
  }
  return decoded;
}
