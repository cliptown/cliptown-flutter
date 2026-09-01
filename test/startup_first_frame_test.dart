import 'dart:async';

import 'package:cliptown_app/startup/cliptown_bootstrap.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows ClipTown while the encrypted vault is pending', (
    tester,
  ) async {
    final startup = Completer<ClipTownStartupResources>();

    await tester.pumpWidget(
      ClipTownBootstrapApp(
        startup: () => startup.future,
        startupTimeout: const Duration(seconds: 30),
      ),
    );

    expect(find.text('ClipTown'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cliptown-startup-loading')),
      findsOneWidget,
    );
  });

  testWidgets('bounds vault startup and keeps retry available', (tester) async {
    var attempts = 0;

    await tester.pumpWidget(
      ClipTownBootstrapApp(
        startup: () {
          attempts += 1;
          return Completer<ClipTownStartupResources>().future;
        },
        startupTimeout: const Duration(milliseconds: 10),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('ClipTown'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('cliptown-startup-error')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('cliptown-startup-retry')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('cliptown-startup-retry')));
    await tester.pump();

    expect(attempts, 2);
    expect(
      find.byKey(const ValueKey('cliptown-startup-loading')),
      findsOneWidget,
    );
  });
}
