import 'dart:io';

import 'package:flutter/widgets.dart';

import 'clipboard/clipboard_controller.dart';
import 'clipboard/clipboard_service.dart';
import 'cliptown_app.dart';
import 'desktop/desktop_lifecycle_host.dart';
import 'history/clip_item.dart';
import 'history/clip_repository.dart';
import 'history/sqlite_clip_repository.dart';
import 'src/clip_store.dart';

DesktopLifecycleHost? _desktopLifecycleHost;
ClipboardController? _clipboardController;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ClipRepository repository;
  try {
    repository = await createPlatformSqliteClipRepository();
  } on Object {
    repository = const _UnavailableClipRepository();
  }
  final store = ClipStore(repository: repository);
  await store.initialize();

  var desktopBackgroundEnabled = false;
  var desktopHotKeyEnabled = false;
  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  if (isDesktop) {
    _desktopLifecycleHost = DesktopLifecycleHost();
    desktopBackgroundEnabled = await _desktopLifecycleHost!.initialize();
    desktopHotKeyEnabled = _desktopLifecycleHost!.hotKeyReady;
  }

  _clipboardController = ClipboardController(
    store: store,
    service: SystemClipClipboardService(),
    automaticCaptureSupported: isDesktop,
  );
  await _clipboardController!.initialize();

  runApp(
    ClipTownApp(
      store: store,
      clipboardController: _clipboardController,
      desktopBackgroundEnabled: desktopBackgroundEnabled,
      desktopHotKeyEnabled: desktopHotKeyEnabled,
    ),
  );
}

class _UnavailableClipRepository implements ClipRepository {
  const _UnavailableClipRepository();

  @override
  Future<void> clear() =>
      Future<void>.error(const ClipRepositoryException('vault unavailable'));

  @override
  Future<List<ClipItem>> load() => Future<List<ClipItem>>.error(
    const ClipRepositoryException('vault unavailable'),
  );

  @override
  Future<void> save(List<ClipItem> clips) =>
      Future<void>.error(const ClipRepositoryException('vault unavailable'));
}
