import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:hotkey_manager/hotkey_manager.dart';

import '../state/app_state_machine.dart';

/// Desktop key bindings.
///
/// - Option+C / Alt+C (system-wide): open ClipTown with search focused.
/// - Option+O / Alt+O (system-wide): open the tray menu (recent clips).
/// - Option+X / Alt+X: hide ClipTown back to the tray. It is system-wide only
///   while the window is showing, and is an in-app key otherwise, so other
///   apps keep Option+X (≈) whenever ClipTown is hidden. Inside the open tray
///   menu, Option+X is the native key equivalent of "Hide ClipTown", which
///   closes the menu and hides the app.
///
/// These replace the earlier Cmd/Ctrl+Shift+V binding, which collided with
/// "paste and match style" in browsers, editors, and terminals.
const String summonHotKeyIdentifier = 'cliptown.summon';
const String trayHotKeyIdentifier = 'cliptown.tray';
const String dismissHotKeyIdentifier = 'cliptown.dismiss';

HotKey desktopSummonHotKey() => HotKey(
  identifier: summonHotKeyIdentifier,
  key: PhysicalKeyboardKey.keyC,
  modifiers: const <HotKeyModifier>[HotKeyModifier.alt],
  scope: HotKeyScope.system,
);

HotKey desktopTrayHotKey() => HotKey(
  identifier: trayHotKeyIdentifier,
  key: PhysicalKeyboardKey.keyO,
  modifiers: const <HotKeyModifier>[HotKeyModifier.alt],
  scope: HotKeyScope.system,
);

HotKey desktopDismissHotKey() => HotKey(
  identifier: dismissHotKeyIdentifier,
  key: PhysicalKeyboardKey.keyX,
  modifiers: const <HotKeyModifier>[HotKeyModifier.alt],
  scope: HotKeyScope.system,
);

/// Whether the system-wide Option/Alt+X should be held: only while the
/// ClipTown window is in the foreground (showing).
bool dismissHotKeyWanted(AppMachineState state) =>
    state.lifecycle == AppLifecyclePhase.foreground;

/// In-app fallback: hide ClipTown back to the tray (it keeps running there).
const SingleActivator dismissActivator = SingleActivator(
  LogicalKeyboardKey.keyX,
  alt: true,
);

/// Human-readable labels shown in the status line and tray menu.
String summonShortcutLabel({required bool isMacOS}) => isMacOS ? '⌥C' : 'Alt+C';

String trayShortcutLabel({required bool isMacOS}) => isMacOS ? '⌥O' : 'Alt+O';

String dismissShortcutLabel({required bool isMacOS}) =>
    isMacOS ? '⌥X' : 'Alt+X';
