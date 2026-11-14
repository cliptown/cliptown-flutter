import 'dart:ui';

import 'package:cliptown_app/desktop/desktop_lifecycle_controller.dart';
import 'package:cliptown_app/desktop/desktop_lifecycle_host.dart';
import 'package:cliptown_app/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _RecordingWindow window;
  late _RecordingTray tray;
  late DesktopLifecycleController controller;

  setUp(() {
    window = _RecordingWindow();
    tray = _RecordingTray();
    controller = DesktopLifecycleController(window: window, tray: tray);
  });

  test('open action restores a normal centered and focused window', () async {
    await controller.handleTrayAction(DesktopTrayAction.open);

    expect(window.operations, <String>[
      'skipTaskbar:false',
      'minimumSize:760.0x520.0',
      'size:1100.0x760.0',
      'center',
      'show',
      'focus',
    ]);
    expect(
      controller.stateMachine.state.lifecycle,
      AppLifecyclePhase.foreground,
    );
  });

  test('window close hides to the tray instead of destroying app', () async {
    await controller.handleWindowCloseRequested();

    expect(window.operations, <String>['hide', 'skipTaskbar:true']);
    expect(tray.destroyCount, 0);
    expect(
      controller.stateMachine.state.lifecycle,
      AppLifecyclePhase.background,
    );
  });

  test('tray hide action uses the same background lifecycle', () async {
    await controller.handleTrayAction(DesktopTrayAction.hide);

    expect(window.operations, <String>['hide', 'skipTaskbar:true']);
  });

  test('quit is explicit and idempotent', () async {
    await controller.handleTrayAction(DesktopTrayAction.quit);
    await controller.handleTrayAction(DesktopTrayAction.quit);

    expect(controller.isQuitting, isTrue);
    expect(tray.destroyCount, 1);
    expect(window.operations, <String>['preventClose:false', 'destroy']);
    expect(controller.stateMachine.state.lifecycle, AppLifecyclePhase.stopped);
  });

  test('quit still destroys the application when tray cleanup fails', () async {
    tray.destroyError = StateError('tray unavailable');

    await expectLater(controller.quit(), throwsStateError);

    expect(window.operations, <String>['preventClose:false', 'destroy']);
    expect(controller.stateMachine.state.lifecycle, AppLifecyclePhase.faulted);
    expect(controller.stateMachine.state.vault, isNot(AppVaultState.unlocked));
    expect(controller.stateMachine.state.sync, AppSyncState.disabled);
  });

  test('native window failure is contained as a controlled fault', () async {
    window.hideError = StateError('native hide failed');

    await expectLater(controller.hideMainWindow(), throwsStateError);

    expect(controller.stateMachine.state.lifecycle, AppLifecyclePhase.faulted);
    expect(controller.stateMachine.state.sync, AppSyncState.disabled);
    expect(controller.stateMachine.state.windowVisible, isFalse);
  });

  test('explicit quit can finish shutdown from a controlled fault', () async {
    window.hideError = StateError('native hide failed');
    await expectLater(controller.hideMainWindow(), throwsStateError);
    window.hideError = null;

    await controller.handleTrayAction(DesktopTrayAction.quit);

    expect(controller.stateMachine.state.lifecycle, AppLifecyclePhase.stopped);
    expect(controller.stateMachine.state.invariantViolations(), isEmpty);
    expect(tray.destroyCount, 1);
    expect(window.operations, <String>[
      'hide',
      'preventClose:false',
      'destroy',
    ]);
  });

  test('tray menu keys map only to supported lifecycle actions', () {
    expect(
      desktopTrayActionForMenuKey(openClipTownMenuKey),
      DesktopTrayAction.open,
    );
    expect(
      desktopTrayActionForMenuKey(hideClipTownMenuKey),
      DesktopTrayAction.hide,
    );
    expect(
      desktopTrayActionForMenuKey(quitClipTownMenuKey),
      DesktopTrayAction.quit,
    );
    expect(desktopTrayActionForMenuKey('unknown'), isNull);
  });
}

class _RecordingWindow implements DesktopWindowPort {
  final List<String> operations = <String>[];
  Object? hideError;

  @override
  Future<void> center() async => operations.add('center');

  @override
  Future<void> destroy() async => operations.add('destroy');

  @override
  Future<void> focus() async => operations.add('focus');

  @override
  Future<void> hide() async {
    operations.add('hide');
    if (hideError case final error?) throw error;
  }

  @override
  Future<void> setMinimumSize(Size size) async =>
      operations.add('minimumSize:${size.width}x${size.height}');

  @override
  Future<void> setPreventClose(bool preventClose) async =>
      operations.add('preventClose:$preventClose');

  @override
  Future<void> setSize(Size size) async =>
      operations.add('size:${size.width}x${size.height}');

  @override
  Future<void> setSkipTaskbar(bool skipTaskbar) async =>
      operations.add('skipTaskbar:$skipTaskbar');

  @override
  Future<void> show() async => operations.add('show');
}

class _RecordingTray implements DesktopTrayPort {
  int destroyCount = 0;
  Object? destroyError;

  @override
  Future<void> destroy() async {
    destroyCount += 1;
    if (destroyError case final error?) throw error;
  }
}
