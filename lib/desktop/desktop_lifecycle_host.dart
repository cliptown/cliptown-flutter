import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_lifecycle_controller.dart';

const String openClipTownMenuKey = 'open_cliptown';
const String hideClipTownMenuKey = 'hide_cliptown';
const String quitClipTownMenuKey = 'quit_cliptown';

DesktopTrayAction? desktopTrayActionForMenuKey(String? key) => switch (key) {
  openClipTownMenuKey => DesktopTrayAction.open,
  hideClipTownMenuKey => DesktopTrayAction.hide,
  quitClipTownMenuKey => DesktopTrayAction.quit,
  _ => null,
};

class DesktopLifecycleHost with WindowListener, TrayListener {
  DesktopLifecycleHost()
    : controller = DesktopLifecycleController(
        window: const WindowManagerPort(),
        tray: const TrayManagerPort(),
      );

  final DesktopLifecycleController controller;
  bool _trayReady = false;

  bool get trayReady => _trayReady;

  Future<bool> initialize() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    try {
      trayManager.addListener(this);
      await _configureTray();
      _trayReady = true;
    } on Object catch (error) {
      trayManager.removeListener(this);
      try {
        await trayManager.destroy();
      } on Object {
        // The tray may not have reached a destroyable state.
      }
      debugPrint('ClipTown tray integration is unavailable: $error');
    }

    // Always intercept Close. With a tray, Close hides the window; without a
    // tray, the listener explicitly quits so the process cannot be stranded.
    await windowManager.setPreventClose(true);
    const options = WindowOptions(
      size: defaultDesktopWindowSize,
      minimumSize: minimumDesktopWindowSize,
      center: true,
      skipTaskbar: false,
      title: 'ClipTown',
      titleBarStyle: TitleBarStyle.normal,
    );
    unawaited(
      windowManager.waitUntilReadyToShow(options, controller.openMainWindow),
    );
    return _trayReady;
  }

  Future<void> _configureTray() async {
    final icon = Platform.isWindows
        ? 'windows/runner/resources/app_icon.ico'
        : 'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_32.png';
    await trayManager.setIcon(icon);
    await trayManager.setToolTip('ClipTown clipboard history');
    await trayManager.setContextMenu(
      Menu(
        items: <MenuItem>[
          MenuItem(key: openClipTownMenuKey, label: 'Open ClipTown'),
          MenuItem(key: hideClipTownMenuKey, label: 'Hide ClipTown'),
          MenuItem.separator(),
          MenuItem(key: quitClipTownMenuKey, label: 'Quit ClipTown'),
        ],
      ),
    );
  }

  @override
  void onWindowClose() async {
    if (controller.isQuitting) return;

    // Match the native close guard before hiding. This avoids treating a late
    // close notification during explicit shutdown as a background request.
    if (await windowManager.isPreventClose()) {
      if (_trayReady) {
        await controller.handleWindowCloseRequested();
      } else {
        await controller.quit();
      }
    }
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(controller.openMainWindow());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final action = desktopTrayActionForMenuKey(menuItem.key);
    if (action != null) {
      unawaited(controller.handleTrayAction(action));
    }
  }
}

class WindowManagerPort implements DesktopWindowPort {
  const WindowManagerPort();

  @override
  Future<void> center() => windowManager.center();

  @override
  Future<void> destroy() => windowManager.destroy();

  @override
  Future<void> focus() => windowManager.focus();

  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> setMinimumSize(Size size) => windowManager.setMinimumSize(size);

  @override
  Future<void> setPreventClose(bool preventClose) =>
      windowManager.setPreventClose(preventClose);

  @override
  Future<void> setSize(Size size) => windowManager.setSize(size);

  @override
  Future<void> setSkipTaskbar(bool skipTaskbar) =>
      windowManager.setSkipTaskbar(skipTaskbar);

  @override
  Future<void> show() => windowManager.show();
}

class TrayManagerPort implements DesktopTrayPort {
  const TrayManagerPort();

  @override
  Future<void> destroy() => trayManager.destroy();
}
