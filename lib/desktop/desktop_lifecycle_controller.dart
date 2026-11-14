import 'dart:ui';

import '../state/app_state_machine.dart';

const Size defaultDesktopWindowSize = Size(1100, 760);
const Size minimumDesktopWindowSize = Size(760, 520);

enum DesktopTrayAction { open, hide, quit }

abstract interface class DesktopWindowPort {
  Future<void> setPreventClose(bool preventClose);

  Future<void> setSkipTaskbar(bool skipTaskbar);

  Future<void> setMinimumSize(Size size);

  Future<void> setSize(Size size);

  Future<void> center();

  Future<void> show();

  Future<void> focus();

  Future<void> hide();

  Future<void> destroy();
}

abstract interface class DesktopTrayPort {
  Future<void> destroy();
}

class DesktopLifecycleController {
  DesktopLifecycleController({
    required this.window,
    required this.tray,
    AppStateMachine? stateMachine,
  }) : stateMachine =
           stateMachine ?? AppStateMachine.signedOut(AppRuntimeKind.desktop);

  final DesktopWindowPort window;
  final DesktopTrayPort tray;
  final AppStateMachine stateMachine;

  bool get isQuitting => stateMachine.state.isTerminating;

  Future<void> openMainWindow() async {
    if (isQuitting) return;

    try {
      await window.setSkipTaskbar(false);
      await window.setMinimumSize(minimumDesktopWindowSize);
      await window.setSize(defaultDesktopWindowSize);
      await window.center();
      await window.show();
      await window.focus();
      stateMachine.dispatch(AppEvent.foregroundRequested);
    } on Object {
      stateMachine.dispatch(AppEvent.nativeFailure);
      rethrow;
    }
  }

  Future<void> hideMainWindow() async {
    if (isQuitting) return;

    try {
      await window.hide();
      await window.setSkipTaskbar(true);
      stateMachine.dispatch(AppEvent.backgroundRequested);
    } on Object {
      stateMachine.dispatch(AppEvent.nativeFailure);
      rethrow;
    }
  }

  Future<void> handleWindowCloseRequested() => hideMainWindow();

  Future<void> handleTrayAction(DesktopTrayAction action) => switch (action) {
    DesktopTrayAction.open => openMainWindow(),
    DesktopTrayAction.hide => hideMainWindow(),
    DesktopTrayAction.quit => quit(),
  };

  Future<void> quit() async {
    final lifecycle = stateMachine.state.lifecycle;
    if (lifecycle == AppLifecyclePhase.stopping ||
        lifecycle == AppLifecyclePhase.stopped) {
      return;
    }
    final shutdown = stateMachine.dispatch(AppEvent.shutdownRequested);
    if (!shutdown.accepted) return;

    try {
      try {
        await tray.destroy();
      } finally {
        try {
          await window.setPreventClose(false);
        } finally {
          await window.destroy();
        }
      }
      stateMachine.dispatch(AppEvent.shutdownCompleted);
    } on Object {
      stateMachine.dispatch(AppEvent.nativeFailure);
      rethrow;
    }
  }
}
