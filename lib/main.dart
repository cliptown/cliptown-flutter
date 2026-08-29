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
import 'state/app_state_machine.dart';

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

  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  final runtime = isDesktop ? AppRuntimeKind.desktop : AppRuntimeKind.mobile;
  final stateMachine = AppStateMachine.signedOut(runtime);

  var desktopBackgroundEnabled = false;
  var desktopHotKeyEnabled = false;
  DesktopLifecycleHost? desktopLifecycleHost;
  if (isDesktop) {
    desktopLifecycleHost = DesktopLifecycleHost(stateMachine: stateMachine);
    desktopBackgroundEnabled = await desktopLifecycleHost.initialize();
    desktopHotKeyEnabled = desktopLifecycleHost.hotKeyReady;
  }

  final clipboardController = ClipboardController(
    store: store,
    service: SystemClipClipboardService(),
    automaticCaptureSupported: isDesktop,
  );
  await clipboardController.initialize();

  runApp(
    ClipTownApp(
      store: store,
      stateMachine: stateMachine,
      runtimeKind: runtime,
      disposeStateMachine: true,
      clipboardController: clipboardController,
      desktopLifecycleHost: desktopLifecycleHost,
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
