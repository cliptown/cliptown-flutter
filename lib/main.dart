import 'package:flutter/widgets.dart';
import 'package:ores_otel_flutter/ores_otel_flutter.dart';

import 'startup/cliptown_bootstrap.dart';

void main() {
  final logger = Logger(appName: 'cliptown_app');
  runOresFlutterApp(
    appName: 'cliptown_app',
    emitToDeveloperLog: false,
    sinks: [NextLoggersStartupDiagnosticSink(logger: logger)],
    builder: (_) => const ClipTownBootstrapApp(),
  );
}
