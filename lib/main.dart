import 'package:ores_otel_flutter/ores_otel_flutter.dart';

import 'startup/cliptown_bootstrap.dart';

void main(List<String> arguments) {
  final logger = Logger(appName: 'cliptown_app');
  runOresFlutterApp(
    appName: 'cliptown_app',
    emitToDeveloperLog: false,
    sinks: [NextLoggersStartupDiagnosticSink(logger: logger)],
    builder: (_) => ClipTownBootstrapApp(arguments: arguments),
  );
}
