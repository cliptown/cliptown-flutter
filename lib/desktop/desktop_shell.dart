import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';

import '../history/capture_policy.dart';
import '../history/clip_item.dart';
import 'desktop_shortcuts.dart';
import 'launch_at_login.dart';

const String openClipTownMenuKey = 'open_cliptown';
const String hideClipTownMenuKey = 'hide_cliptown';
const String quitClipTownMenuKey = 'quit_cliptown';
const String toggleCaptureMenuKey = 'toggle_capture';
const String recentClipMenuKeyPrefix = 'recent_clip:';

/// Titles the macOS runner matches to attach native key equivalents; keep them
/// in sync with TrayMenuKeys in macos/Runner/MainFlutterWindow.swift.
const String openClipTownMenuTitle = 'Open ClipTown';
const String hideClipTownMenuTitle = 'Hide ClipTown';
const String quitClipTownMenuTitle = 'Quit ClipTown';

/// Maximum number of recent clips listed directly in the tray menu.
const int trayRecentClipLimit = 10;
const int _trayLabelMaxCharacters = 48;

/// What the shared UI needs from the native desktop shell (tray, window and
/// global shortcut). [DesktopLifecycleHost] implements it; widget tests fake it.
abstract interface class DesktopShell {
  /// Incremented each time the user summons ClipTown (global shortcut or tray).
  ValueListenable<int> get summonCount;

  /// Hide the window back to the tray. The process keeps running.
  Future<void> dismiss();

  /// Replace the dynamic part of the tray menu.
  void updateTrayMenu(DesktopTrayMenuModel model);

  /// Wire tray menu actions that need the clip store.
  void setTrayHandlers(DesktopTrayHandlers handlers);

  /// Null when the platform has no supported login-item mechanism.
  LaunchAtLogin? get launchAtLogin;
}

@immutable
class DesktopTrayHandlers {
  const DesktopTrayHandlers({
    required this.onRecentClipSelected,
    required this.onToggleCapture,
  });

  final ValueChanged<String> onRecentClipSelected;
  final VoidCallback onToggleCapture;
}

@immutable
class DesktopTrayClipEntry {
  const DesktopTrayClipEntry({required this.id, required this.label});

  final String id;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is DesktopTrayClipEntry && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

@immutable
class DesktopTrayMenuModel {
  const DesktopTrayMenuModel({
    this.recentClips = const <DesktopTrayClipEntry>[],
    this.captureOn = false,
    this.captureAvailable = false,
  });

  factory DesktopTrayMenuModel.fromClips(
    Iterable<ClipItem> newestFirst, {
    required bool captureOn,
    required bool captureAvailable,
  }) => DesktopTrayMenuModel(
    recentClips: newestFirst
        .take(trayRecentClipLimit)
        .map(
          (clip) =>
              DesktopTrayClipEntry(id: clip.id, label: trayLabelForClip(clip)),
        )
        .toList(growable: false),
    captureOn: captureOn,
    captureAvailable: captureAvailable,
  );

  final List<DesktopTrayClipEntry> recentClips;
  final bool captureOn;
  final bool captureAvailable;

  @override
  bool operator ==(Object other) =>
      other is DesktopTrayMenuModel &&
      other.captureOn == captureOn &&
      other.captureAvailable == captureAvailable &&
      listEquals(other.recentClips, recentClips);

  @override
  int get hashCode =>
      Object.hash(captureOn, captureAvailable, Object.hashAll(recentClips));
}

/// Shown instead of the text of a clip that looks like a secret. The tray menu
/// is visible to anyone looking at (or screen-sharing) the menu bar.
const String sensitiveTrayLabel = '•••••• hidden (looks sensitive)';

/// Characters that must never reach a native menu label: C0/C1 controls and
/// the Unicode bidirectional overrides/isolates/marks that can visually
/// reorder (spoof) text.
final RegExp _unsafeLabelCharacters = RegExp(
  r'[\x00-\x1f\x7f-\x9f\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]',
);

/// One-line, bounded tray label for a clip. Whitespace is collapsed so
/// multi-line clips never produce multi-line native menu items, control and
/// bidi-override characters are removed, and likely secrets are masked.
String trayLabelForClip(ClipItem clip) {
  final text = clip.text;
  if (text != null && isLikelySensitiveText(text)) {
    return clip.pinned ? '★ $sensitiveTrayLabel' : sensitiveTrayLabel;
  }
  final source = switch (clip.kind) {
    ClipKind.image => clip.title,
    ClipKind.files => clip.summary,
    _ => (text ?? clip.title),
  };
  final collapsed = source
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(_unsafeLabelCharacters, '')
      .trim();
  final characters =
      (collapsed.isEmpty ? clip.kind.label : collapsed).characters;
  final label = characters.length > _trayLabelMaxCharacters
      ? '${characters.take(_trayLabelMaxCharacters - 1)}…'
      : characters.toString();
  return clip.pinned ? '★ $label' : label;
}

/// Windows menus treat `&` as an accelerator prefix; double it so clip text
/// renders literally.
String nativeMenuLabel(String label, {required bool isWindows}) =>
    isWindows ? label.replaceAll('&', '&&') : label;

String? recentClipIdForMenuKey(String? key) =>
    key != null && key.startsWith(recentClipMenuKeyPrefix)
    ? key.substring(recentClipMenuKeyPrefix.length)
    : null;

Menu buildTrayMenu(
  DesktopTrayMenuModel model, {
  required bool isMacOS,
  bool isWindows = false,
}) {
  // macOS shows real key equivalents (attached natively when the menu opens,
  // see TrayMenuKeys in MainFlutterWindow.swift), so titles stay plain there.
  String withShortcut(String title, String shortcut) =>
      isMacOS ? title : '$title   $shortcut';
  return Menu(
    items: <MenuItem>[
      MenuItem(
        key: openClipTownMenuKey,
        label: withShortcut(
          openClipTownMenuTitle,
          summonShortcutLabel(isMacOS: isMacOS),
        ),
      ),
      MenuItem(
        key: hideClipTownMenuKey,
        label: withShortcut(
          hideClipTownMenuTitle,
          dismissShortcutLabel(isMacOS: isMacOS),
        ),
      ),
      MenuItem(key: quitClipTownMenuKey, label: quitClipTownMenuTitle),
      MenuItem.separator(),
      MenuItem(
        label: model.recentClips.isEmpty
            ? 'No recent clips'
            : 'Recent clips — click to copy',
        disabled: true,
      ),
      ...model.recentClips.map(
        (entry) => MenuItem(
          key: '$recentClipMenuKeyPrefix${entry.id}',
          label: nativeMenuLabel(entry.label, isWindows: isWindows),
        ),
      ),
      MenuItem.separator(),
      MenuItem(
        key: toggleCaptureMenuKey,
        label: model.captureOn ? 'Pause capture' : 'Resume capture',
        disabled: !model.captureAvailable,
      ),
    ],
  );
}
