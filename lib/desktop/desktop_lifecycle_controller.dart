import 'dart:ui';

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
  DesktopLifecycleController({required this.window, required this.tray});

  final DesktopWindowPort window;
  final DesktopTrayPort tray;
  bool _quitting = false;

  bool get isQuitting => _quitting;

  Future<void> openMainWindow() async {
    if (_quitting) return;

    await window.setSkipTaskbar(false);
    await window.setMinimumSize(minimumDesktopWindowSize);
    await window.setSize(defaultDesktopWindowSize);
    await window.center();
    await window.show();
    await window.focus();
  }

  Future<void> hideMainWindow() async {
    if (_quitting) return;

    await window.hide();
    await window.setSkipTaskbar(true);
  }

  Future<void> handleWindowCloseRequested() => hideMainWindow();

  Future<void> handleTrayAction(DesktopTrayAction action) => switch (action) {
    DesktopTrayAction.open => openMainWindow(),
    DesktopTrayAction.hide => hideMainWindow(),
    DesktopTrayAction.quit => quit(),
  };

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;

    try {
      await tray.destroy();
    } finally {
      try {
        await window.setPreventClose(false);
      } finally {
        await window.destroy();
      }
    }
  }
}
