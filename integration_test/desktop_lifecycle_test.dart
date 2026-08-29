import 'dart:io';
import 'dart:ui';

import 'package:cliptown_app/cliptown_app.dart';
import 'package:cliptown_app/desktop/desktop_lifecycle_controller.dart';
import 'package:cliptown_app/desktop/desktop_lifecycle_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final isDesktopHost =
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  testWidgets(
    'native close backgrounds and tray action restores full window',
    (tester) async {
      final host = DesktopLifecycleHost();
      final trayReady = await host.initialize();
      addTearDown(host.dispose);

      await tester.pumpWidget(ClipTownApp(desktopBackgroundEnabled: trayReady));
      await host.windowReady;
      await tester.pumpAndSettle();

      expect(await windowManager.isVisible(), isTrue);
      await _expectUsableWindowSize();

      if (trayReady) {
        await windowManager.close();
      } else {
        // Headless Linux runners may have AppIndicator libraries without a
        // status-item host. Exercise the same background transition directly.
        await host.controller.handleWindowCloseRequested();
      }
      await _waitForWindowVisibility(false);

      expect(await windowManager.isSkipTaskbar(), isTrue);
      expect(host.controller.isQuitting, isFalse);

      await host.controller.handleTrayAction(DesktopTrayAction.open);
      await _waitForWindowVisibility(true);

      expect(await windowManager.isSkipTaskbar(), isFalse);
      await _expectUsableWindowSize();
      expect(await windowManager.isFocused(), isTrue);
      await _expectCenteredOnPrimaryDisplay();
    },
    skip: !isDesktopHost,
  );
}

Future<void> _waitForWindowVisibility(bool expected) async {
  for (var attempt = 0; attempt < 30; attempt += 1) {
    if (await windowManager.isVisible() == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Window visibility never became $expected.');
}

Future<Size> _expectUsableWindowSize() async {
  final actual = await windowManager.getSize();
  // Window managers clamp a requested size to the available work area. The
  // Windows hosted runner is narrower than ClipTown's 1100 px default once
  // decorations are accounted for, so require a usable bounded result rather
  // than an impossible exact width.
  expect(
    actual.width,
    inInclusiveRange(
      minimumDesktopWindowSize.width,
      defaultDesktopWindowSize.width,
    ),
  );
  expect(
    actual.height,
    inInclusiveRange(
      minimumDesktopWindowSize.height,
      defaultDesktopWindowSize.height,
    ),
  );
  return actual;
}

Future<void> _expectCenteredOnPrimaryDisplay() async {
  final display = await screenRetriever.getPrimaryDisplay();
  final visibleOrigin = display.visiblePosition ?? Offset.zero;
  final visibleSize = display.visibleSize ?? display.size;
  final actualSize = await windowManager.getSize();
  final actual = await windowManager.getPosition();
  final expected = Offset(
    visibleOrigin.dx + (visibleSize.width - actualSize.width) / 2,
    visibleOrigin.dy + (visibleSize.height - actualSize.height) / 2,
  );

  expect(actual.dx, closeTo(expected.dx, 12));
  expect(actual.dy, closeTo(expected.dy, 12));
}
