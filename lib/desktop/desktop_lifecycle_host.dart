import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_lifecycle_controller.dart';
import 'desktop_shell.dart';
import 'desktop_shortcuts.dart';
import 'launch_at_login.dart';
import 'tray_icon.dart';
import '../state/app_state_machine.dart';

export 'desktop_shell.dart'
    show
        hideClipTownMenuKey,
        openClipTownMenuKey,
        quitClipTownMenuKey,
        toggleCaptureMenuKey;

DesktopTrayAction? desktopTrayActionForMenuKey(String? key) => switch (key) {
  openClipTownMenuKey => DesktopTrayAction.open,
  hideClipTownMenuKey => DesktopTrayAction.hide,
  quitClipTownMenuKey => DesktopTrayAction.quit,
  _ => null,
};

class DesktopLifecycleHost
    with WindowListener, TrayListener
    implements DesktopShell {
  DesktopLifecycleHost({
    AppStateMachine? stateMachine,
    this.startHidden = false,
    LaunchAtLogin? launchAtLogin,
  }) : controller = DesktopLifecycleController(
         window: const WindowManagerPort(),
         tray: const TrayManagerPort(),
         stateMachine: stateMachine,
       ),
       launchAtLogin = launchAtLogin ?? platformLaunchAtLogin();

  final DesktopLifecycleController controller;

  /// Keep the window hidden after startup (login-item launch).
  final bool startHidden;

  @override
  final LaunchAtLogin? launchAtLogin;

  late final TrayIconFlasher _flasher = TrayIconFlasher(
    _PlatformTrayIconPort(),
  );
  final ValueNotifier<int> _summonCount = ValueNotifier<int>(0);
  bool _trayReady = false;
  bool _hotKeyReady = false;
  HotKey? _summonHotKey;
  DesktopTrayMenuModel _trayMenu = const DesktopTrayMenuModel();
  DesktopTrayHandlers? _trayHandlers;
  Future<void> _windowReady = Future<void>.value();

  bool get trayReady => _trayReady;
  bool get hotKeyReady => _hotKeyReady;
  Future<void> get windowReady => _windowReady;

  @override
  ValueListenable<int> get summonCount => _summonCount;

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
    // A hidden start is only safe when the tray can bring the window back.
    final hideOnStart = startHidden && _trayReady;
    _windowReady = windowManager.waitUntilReadyToShow(
      options,
      hideOnStart ? controller.hideMainWindow : controller.openMainWindow,
    );
    unawaited(_windowReady);
    await _configureSummonHotKey();
    return _trayReady;
  }

  Future<void> dispose() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _flasher.cancel();

    final trayWasReady = _trayReady;
    _trayReady = false;
    final summonHotKey = _summonHotKey;
    _summonHotKey = null;
    _hotKeyReady = false;
    try {
      if (summonHotKey != null) {
        await hotKeyManager.unregister(summonHotKey);
      }
      if (trayWasReady) await trayManager.destroy();
    } finally {
      await windowManager.setPreventClose(false);
    }
  }

  /// Open (or re-focus) the main window and tell the UI to focus search.
  Future<void> summon({bool flashTray = false}) async {
    if (controller.isQuitting) return;
    if (flashTray && _trayReady) unawaited(_flasher.flash());
    await controller.openMainWindow();
    _summonCount.value += 1;
  }

  @override
  Future<void> dismiss() async {
    if (!_trayReady) return;
    await controller.hideMainWindow();
  }

  @override
  void setTrayHandlers(DesktopTrayHandlers handlers) {
    _trayHandlers = handlers;
  }

  @override
  void updateTrayMenu(DesktopTrayMenuModel model) {
    if (model == _trayMenu) return;
    _trayMenu = model;
    if (_trayReady) unawaited(_applyTrayMenu());
  }

  Future<void> _applyTrayMenu() async {
    try {
      await trayManager.setContextMenu(
        buildTrayMenu(_trayMenu, isMacOS: Platform.isMacOS),
      );
    } on Object {
      // The previous menu stays in place; the next store change retries.
    }
  }

  Future<void> _configureSummonHotKey() async {
    final hotKey = desktopSummonHotKey();
    try {
      // Clears registrations left behind by a hot restart.
      await hotKeyManager.unregisterAll();
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) => unawaited(summon(flashTray: true)),
      );
      _summonHotKey = hotKey;
      _hotKeyReady = true;
    } on Object catch (error) {
      _summonHotKey = null;
      _hotKeyReady = false;
      debugPrint('ClipTown global summon shortcut is unavailable: $error');
    }
  }

  Future<void> _configureTray() async {
    await _PlatformTrayIconPort().setIcon(TrayIconVariant.normal);
    await trayManager.setToolTip(
      'ClipTown clipboard history (${summonShortcutLabel(isMacOS: Platform.isMacOS)})',
    );
    await trayManager.setContextMenu(
      buildTrayMenu(_trayMenu, isMacOS: Platform.isMacOS),
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
    unawaited(summon());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key;
    final action = desktopTrayActionForMenuKey(key);
    if (action == DesktopTrayAction.open) {
      unawaited(summon());
      return;
    }
    if (action != null) {
      unawaited(controller.handleTrayAction(action));
      return;
    }
    final handlers = _trayHandlers;
    if (handlers == null) return;
    if (key == toggleCaptureMenuKey) {
      handlers.onToggleCapture();
      return;
    }
    final clipId = recentClipIdForMenuKey(key);
    if (clipId != null) {
      handlers.onRecentClipSelected(clipId);
      unawaited(_flasher.flash());
    }
  }
}

class _PlatformTrayIconPort implements TrayIconPort {
  @override
  Future<void> setIcon(TrayIconVariant variant) {
    final asset = trayIconAsset(variant, platform: defaultTargetPlatform);
    return trayManager.setIcon(asset.path, isTemplate: asset.isTemplate);
  }
}

class WindowManagerPort implements DesktopWindowPort {
  const WindowManagerPort();

  @override
  Future<void> center() => windowManager.center();

  @override
  Future<void> destroy() => windowManager.destroy();

  static const MethodChannel _macOSWindowChannel = MethodChannel(
    'cliptown/window',
  );

  @override
  Future<void> focus() async {
    await windowManager.focus();
    if (!Platform.isMacOS) return;
    try {
      // window_manager activates cooperatively; a summon from another app
      // needs an explicit activation for the search field to get keys.
      await _macOSWindowChannel.invokeMethod<void>('activate');
    } on MissingPluginException {
      // Older runner without the channel: window_manager focus stands.
    }
  }

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
