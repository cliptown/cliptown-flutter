import 'dart:async';

import 'package:flutter/foundation.dart';

enum TrayIconVariant { normal, highlight }

/// A bundled tray image and how the native tray should render it.
@immutable
class TrayIconAsset {
  const TrayIconAsset(this.path, {this.isTemplate = false});

  final String path;

  /// macOS only: template images are tinted by the system so the glyph stays
  /// legible on light and dark menu bars.
  final bool isTemplate;

  @override
  bool operator ==(Object other) =>
      other is TrayIconAsset &&
      other.path == path &&
      other.isTemplate == isTemplate;

  @override
  int get hashCode => Object.hash(path, isTemplate);

  @override
  String toString() => 'TrayIconAsset($path, isTemplate: $isTemplate)';
}

/// Resolves the bundled tray image for a platform. Windows trays need `.ico`;
/// the macOS resting icon is a monochrome template; the highlight variant is
/// always full colour so the flash is visible on every menu bar and panel.
TrayIconAsset trayIconAsset(
  TrayIconVariant variant, {
  required TargetPlatform platform,
}) {
  final highlight = variant == TrayIconVariant.highlight;
  return switch (platform) {
    TargetPlatform.windows => TrayIconAsset(
      highlight
          ? 'assets/tray/tray_highlight.ico'
          : 'assets/tray/tray_color.ico',
    ),
    TargetPlatform.macOS =>
      highlight
          ? const TrayIconAsset('assets/tray/tray_highlight.png')
          : const TrayIconAsset(
              'assets/tray/tray_template.png',
              isTemplate: true,
            ),
    _ => TrayIconAsset(
      highlight
          ? 'assets/tray/tray_highlight.png'
          : 'assets/tray/tray_color.png',
    ),
  };
}

abstract interface class TrayIconPort {
  Future<void> setIcon(TrayIconVariant variant);
}

typedef DelayFunction = Future<void> Function(Duration duration);

Future<void> _realDelay(Duration duration) => Future<void>.delayed(duration);

/// Briefly pulses the tray icon so the user can see where ClipTown lives when
/// the summon shortcut fires.
///
/// A newer flash supersedes an in-flight one; the newest flash always finishes
/// on [TrayIconVariant.normal]. Native tray failures are swallowed: the flash
/// is feedback only and must never break summoning the window.
class TrayIconFlasher {
  TrayIconFlasher(
    this.port, {
    this.pulses = 2,
    this.onDuration = const Duration(milliseconds: 150),
    this.offDuration = const Duration(milliseconds: 110),
    DelayFunction? delay,
  }) : assert(pulses > 0),
       _delay = delay ?? _realDelay;

  final TrayIconPort port;
  final int pulses;
  final Duration onDuration;
  final Duration offDuration;
  final DelayFunction _delay;
  int _generation = 0;

  bool get flashing => _active > 0;
  int _active = 0;

  Future<void> flash() async {
    final generation = ++_generation;
    _active += 1;
    try {
      for (var pulse = 0; pulse < pulses; pulse += 1) {
        if (generation != _generation) return;
        await port.setIcon(TrayIconVariant.highlight);
        await _delay(onDuration);
        if (generation != _generation) return;
        await port.setIcon(TrayIconVariant.normal);
        if (pulse < pulses - 1) await _delay(offDuration);
      }
    } on Object {
      // Feedback only: a failed flash must never surface to the user.
      if (generation == _generation) {
        try {
          await port.setIcon(TrayIconVariant.normal);
        } on Object {
          // The tray may already be destroyed.
        }
      }
    } finally {
      _active -= 1;
    }
  }

  /// Invalidates any in-flight flash (used on shutdown).
  void cancel() => _generation += 1;
}
