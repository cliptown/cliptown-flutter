import 'dart:io';

import 'package:cliptown_app/clipboard/clipboard_controller.dart';
import 'package:cliptown_app/clipboard/clipboard_service.dart';
import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/history/clip_repository.dart';
import 'package:cliptown_app/src/clip_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final isDesktopHost =
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  testWidgets(
    'native clipboard capture, search, queue, and copy round trip',
    (tester) async {
      final store = ClipStore(repository: MemoryClipRepository());
      await store.initialize();
      final clipboard = SystemClipClipboardService();
      final controller = ClipboardController(
        store: store,
        service: clipboard,
        automaticCaptureSupported: true,
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.monitoring, isTrue);

      const capturedText = 'ClipTown native clipboard acceptance marker';
      await Clipboard.setData(const ClipboardData(text: capturedText));
      await _waitFor(
        () => store.clips.any((item) => item.text == capturedText),
        because: 'the native clipboard watcher did not capture new text',
      );

      await tester.pumpWidget(
        ClipTownApp(store: store, clipboardController: controller),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('clip-search')),
        'acceptance',
      );
      await tester.pumpAndSettle();
      expect(find.text(capturedText), findsWidgets);

      final item = store.clips.singleWhere(
        (entry) => entry.text == capturedText,
      );
      await tester.tap(find.byKey(Key('queue-${item.id}')));
      await tester.pumpAndSettle();
      expect(store.queueLength, 1);
      await tester.tap(find.byKey(const Key('copy-next-queued')));
      await tester.pumpAndSettle();

      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      expect(clipboardData?.text, capturedText);
      expect(store.queueLength, 0);
    },
    skip: !isDesktopHost,
  );
}

Future<void> _waitFor(
  bool Function() predicate, {
  required String because,
}) async {
  for (var attempt = 0; attempt < 150; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail(because);
}
