import 'dart:io';

import 'package:flutter/widgets.dart';

import 'cliptown_app.dart';
import 'desktop/desktop_lifecycle_host.dart';
import 'state/app_state_machine.dart';

DesktopLifecycleHost? _desktopLifecycleHost;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  final stateMachine = AppStateMachine.signedOut(
    isDesktop ? AppRuntimeKind.desktop : AppRuntimeKind.mobile,
  );

  var desktopBackgroundEnabled = false;
  if (isDesktop) {
    _desktopLifecycleHost = DesktopLifecycleHost(stateMachine: stateMachine);
    desktopBackgroundEnabled = await _desktopLifecycleHost!.initialize();
  }

  runApp(
    ClipTownApp(
      stateMachine: stateMachine,
      runtimeKind: isDesktop ? AppRuntimeKind.desktop : AppRuntimeKind.mobile,
      disposeStateMachine: true,
      desktopBackgroundEnabled: desktopBackgroundEnabled,
    ),
  );
}
