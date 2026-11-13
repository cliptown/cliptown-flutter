import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:tray_manager/tray_manager.dart';

import '../history/clip_item.dart';
import 'desktop_shortcuts.dart';
import 'launch_at_login.dart';

const String openClipTownMenuKey = 'open_cliptown';
const String hideClipTownMenuKey = 'hide_cliptown';
const String quitClipTownMenuKey = 'quit_cliptown';
const String toggleCaptureMenuKey = 'toggle_capture';
const String recentClipMenuKeyPrefix = 'recent_clip:';

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

/// One-line, bounded tray label for a clip. Whitespace is collapsed so
/// multi-line clips never produce multi-line native menu items.
String trayLabelForClip(ClipItem clip) {
  final source = switch (clip.kind) {
    ClipKind.image => clip.title,
    ClipKind.files => clip.summary,
    _ => (clip.text ?? clip.title),
  };
  var label = source.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (label.isEmpty) label = clip.kind.label;
  final characters = label.characters;
  if (characters.length > _trayLabelMaxCharacters) {
    label = '${characters.take(_trayLabelMaxCharacters - 1)}…';
  }
  return clip.pinned ? '★ $label' : label;
}

String? recentClipIdForMenuKey(String? key) =>
    key != null && key.startsWith(recentClipMenuKeyPrefix)
    ? key.substring(recentClipMenuKeyPrefix.length)
    : null;

Menu buildTrayMenu(DesktopTrayMenuModel model, {required bool isMacOS}) {
  final summon = summonShortcutLabel(isMacOS: isMacOS);
  final dismiss = dismissShortcutLabel(isMacOS: isMacOS);
  return Menu(
    items: <MenuItem>[
      MenuItem(key: openClipTownMenuKey, label: 'Open ClipTown   $summon'),
      MenuItem(key: hideClipTownMenuKey, label: 'Hide ClipTown   $dismiss'),
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
          label: entry.label,
        ),
      ),
      MenuItem.separator(),
      MenuItem(
        key: toggleCaptureMenuKey,
        label: model.captureOn ? 'Pause capture' : 'Resume capture',
        disabled: !model.captureAvailable,
      ),
      MenuItem.separator(),
      MenuItem(key: quitClipTownMenuKey, label: 'Quit ClipTown'),
    ],
  );
}
