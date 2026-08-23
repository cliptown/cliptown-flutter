import 'dart:io';

import 'package:cliptown_app/history/clip_item.dart';
import 'package:cliptown_app/history/encrypted_clip_repository.dart';
import 'package:cliptown_app/history/sqlite_clip_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'macOS debug vault persists through the login Keychain',
    (_) async {
      final directory = await Directory.systemTemp.createTemp(
        'cliptown-macos-vault-e2e-',
      );
      final path = '${directory.path}/history.db';
      final first = SqliteClipRepository(
        path: path,
        secretStore: FlutterSecureVaultSecretStore(),
      );
      final second = SqliteClipRepository(
        path: path,
        secretStore: FlutterSecureVaultSecretStore(),
      );
      addTearDown(() async {
        for (final repository in <SqliteClipRepository>[second, first]) {
          try {
            await repository.clear();
          } on Object {
            // Preserve the assertion failure if cleanup finds a closed vault.
          }
        }
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      });

      final timestamp = DateTime.utc(2026, 8, 22);
      const marker = 'ClipTown macOS Keychain persistence marker';
      await first.save(<ClipItem>[
        ClipItem(
          id: 'macos-keychain-marker',
          kind: ClipKind.text,
          title: marker,
          text: marker,
          createdAt: timestamp,
          lastUsedAt: timestamp,
        ),
      ]);

      final loaded = await second.load();
      expect(loaded, hasLength(1));
      expect(loaded.single.text, marker);
      expect(await second.embeddingCount(), 1);
    },
    skip: !Platform.isMacOS,
  );
}
