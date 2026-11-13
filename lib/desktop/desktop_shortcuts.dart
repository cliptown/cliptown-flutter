import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:hotkey_manager/hotkey_manager.dart';

/// Desktop key bindings.
///
/// The summon shortcut is the only system-wide binding: Option+C on macOS and
/// Alt+C on Windows/Linux opens ClipTown from any application. Every other
/// binding is in-app only, so ClipTown never steals Option/Alt+X (or arrows,
/// Return, Escape) from the application the user is working in.
///
/// Option+C replaces the earlier Cmd/Ctrl+Shift+V binding, which collided with
/// "paste and match style" in browsers, editors, and terminals.
const String summonHotKeyIdentifier = 'cliptown.summon';

HotKey desktopSummonHotKey() => HotKey(
  identifier: summonHotKeyIdentifier,
  key: PhysicalKeyboardKey.keyC,
  modifiers: const <HotKeyModifier>[HotKeyModifier.alt],
  scope: HotKeyScope.system,
);

/// In-app: hide ClipTown back to the tray (it keeps running there).
const SingleActivator dismissActivator = SingleActivator(
  LogicalKeyboardKey.keyX,
  alt: true,
);

/// Human-readable labels shown in the status line and tray menu.
String summonShortcutLabel({required bool isMacOS}) => isMacOS ? '⌥C' : 'Alt+C';

String dismissShortcutLabel({required bool isMacOS}) =>
    isMacOS ? '⌥X' : 'Alt+X';
