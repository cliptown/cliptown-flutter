import 'dart:io';

import 'package:flutter/widgets.dart';

import 'cliptown_app.dart';
import 'desktop/desktop_lifecycle_host.dart';

DesktopLifecycleHost? _desktopLifecycleHost;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  var desktopBackgroundEnabled = false;
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    _desktopLifecycleHost = DesktopLifecycleHost();
    desktopBackgroundEnabled = await _desktopLifecycleHost!.initialize();
  }

  runApp(ClipTownApp(desktopBackgroundEnabled: desktopBackgroundEnabled));
}
