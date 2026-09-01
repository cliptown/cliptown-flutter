import 'package:cliptown_app/state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the total reducer preserves invariants for every reachable state/event',
    () {
      final queue = <AppMachineState>[
        AppMachineState.initial(AppRuntimeKind.mobile),
        AppMachineState.initial(AppRuntimeKind.desktop),
      ];
      final visited = <String>{};
      final acceptedEvents = <AppEvent>{};

      while (queue.isNotEmpty) {
        final state = queue.removeLast();
        final key = _controlStateKey(state);
        if (!visited.add(key)) continue;

        expect(state.invariantViolations(), isEmpty, reason: key);

        for (final event in AppEvent.values) {
          final transition = AppTransitionSystem.transition(state, event);
          expect(
            transition.next.invariantViolations(),
            isEmpty,
            reason: '$key + ${event.name}',
          );

          if (transition.accepted) {
            acceptedEvents.add(event);
            expect(transition.next.revision, state.revision + 1);
            queue.add(transition.next.copyWith(revision: 0));
          } else {
            expect(identical(transition.previous, transition.next), isTrue);
            expect(transition.rejectionReason, isNotEmpty);
          }
        }
      }

      expect(visited.length, greaterThan(60));
      expect(acceptedEvents, AppEvent.values.toSet());
    },
  );

  test(
    'sync cannot start until every authentication and vault guard holds',
    () {
      var state = AppMachineState.initial(AppRuntimeKind.mobile);

      AppTransition apply(AppEvent event) {
        final transition = AppTransitionSystem.transition(state, event);
        if (transition.accepted) state = transition.next;
        return transition;
      }

      expect(apply(AppEvent.syncRequested).accepted, isFalse);
      expect(apply(AppEvent.bootAuthenticated).accepted, isTrue);
      expect(apply(AppEvent.syncRequested).accepted, isFalse);
      expect(apply(AppEvent.unlockSucceeded).accepted, isTrue);
      expect(apply(AppEvent.syncRequested).accepted, isFalse);
      expect(apply(AppEvent.networkConnected).accepted, isTrue);
      expect(apply(AppEvent.syncRequested).accepted, isTrue);
      expect(state.sync, AppSyncState.running);

      expect(apply(AppEvent.authenticationExpired).accepted, isTrue);
      expect(
        state.authentication,
        AppAuthenticationState.reauthenticationRequired,
      );
      expect(state.vault, AppVaultState.locked);
      expect(state.sync, AppSyncState.disabled);
    },
  );

  test(
    'mobile background fails closed while desktop tray mode stays modeled',
    () {
      final mobile = _unlockedOnlineState(AppRuntimeKind.mobile);
      final mobileBackground = AppTransitionSystem.transition(
        mobile,
        AppEvent.backgroundRequested,
      );
      expect(mobileBackground.accepted, isTrue);
      expect(mobileBackground.next.vault, AppVaultState.locked);
      expect(mobileBackground.next.sync, AppSyncState.disabled);

      final desktop = _unlockedOnlineState(AppRuntimeKind.desktop);
      final desktopBackground = AppTransitionSystem.transition(
        desktop,
        AppEvent.backgroundRequested,
      );
      expect(desktopBackground.accepted, isTrue);
      expect(desktopBackground.next.vault, AppVaultState.unlocked);
      expect(desktopBackground.next.sync, AppSyncState.idle);
      expect(desktopBackground.next.permitsSensitiveWork, isTrue);
    },
  );

  test('offline local mode permits capture but never cloud sync', () {
    final state = AppMachineState.localReady(
      AppRuntimeKind.mobile,
      captureRequested: true,
    );

    expect(state.authentication, AppAuthenticationState.signedOut);
    expect(state.permitsLocalWork, isTrue);
    expect(state.permitsCaptureWork, isTrue);
    expect(state.permitsSensitiveWork, isFalse);
    expect(
      AppTransitionSystem.transition(state, AppEvent.syncRequested).accepted,
      isFalse,
    );
    expect(state.invariantViolations(), isEmpty);
  });

  test('capture fault denies work until an explicit valid recovery', () {
    var state = AppMachineState.localReady(
      AppRuntimeKind.desktop,
      captureRequested: true,
    );

    for (final event in <AppEvent>[
      AppEvent.captureMonitoringStarted,
      AppEvent.captureFailed,
    ]) {
      final transition = AppTransitionSystem.transition(state, event);
      expect(transition.accepted, isTrue, reason: event.name);
      state = transition.next;
    }

    expect(state.capture, AppCaptureState.faulted);
    expect(state.captureRequested, isTrue);
    expect(state.permitsCaptureWork, isFalse);
    final recovered = AppTransitionSystem.transition(
      state,
      AppEvent.captureRecovered,
    );
    expect(recovered.accepted, isTrue);
    expect(recovered.next.capture, AppCaptureState.ready);
    expect(recovered.next.permitsCaptureWork, isTrue);
  });

  test('mobile background preserves intent but requires a fresh unlock', () {
    var state = AppMachineState.localReady(
      AppRuntimeKind.mobile,
      captureRequested: true,
    );

    final background = AppTransitionSystem.transition(
      state,
      AppEvent.backgroundRequested,
    );
    expect(background.accepted, isTrue);
    state = background.next;
    expect(state.captureRequested, isTrue);
    expect(state.capture, AppCaptureState.disabled);
    expect(state.vault, AppVaultState.locked);

    final foreground = AppTransitionSystem.transition(
      state,
      AppEvent.foregroundRequested,
    );
    expect(foreground.accepted, isTrue);
    state = foreground.next;
    expect(state.permitsCaptureWork, isFalse);

    final unlocked = AppTransitionSystem.transition(
      state,
      AppEvent.unlockSucceeded,
    );
    expect(unlocked.accepted, isTrue);
    expect(unlocked.next.capture, AppCaptureState.ready);
    expect(unlocked.next.permitsCaptureWork, isTrue);
  });

  test('revocation is monotonic across every subsequently accepted event', () {
    final active = _unlockedOnlineState(AppRuntimeKind.desktop);
    final revoked = AppTransitionSystem.transition(
      active,
      AppEvent.deviceRevoked,
    ).next;

    expect(revoked.localDevice, LocalDeviceTrustState.revoked);
    expect(revoked.vault, AppVaultState.destroyed);

    for (final event in AppEvent.values) {
      final transition = AppTransitionSystem.transition(revoked, event);
      if (!transition.accepted) continue;
      expect(transition.next.localDevice, LocalDeviceTrustState.revoked);
      expect(transition.next.authentication, AppAuthenticationState.revoked);
      expect(transition.next.vault, AppVaultState.destroyed);
      expect(transition.next.sync, AppSyncState.disabled);
      expect(transition.next.revocationObserved, isTrue);
    }
  });

  test('native failures enter a controlled locked state', () {
    final running = AppTransitionSystem.transition(
      _unlockedOnlineState(AppRuntimeKind.desktop),
      AppEvent.syncRequested,
    ).next;
    final fault = AppTransitionSystem.transition(
      running,
      AppEvent.nativeFailure,
    );

    expect(fault.accepted, isTrue);
    expect(fault.next.lifecycle, AppLifecyclePhase.faulted);
    expect(fault.next.vault, AppVaultState.locked);
    expect(fault.next.sync, AppSyncState.disabled);
    expect(fault.next.windowVisible, isFalse);
    expect(fault.next.invariantViolations(), isEmpty);
  });

  test('an invalid externally constructed state cannot enter the machine', () {
    final invalid = AppMachineState.initial(
      AppRuntimeKind.mobile,
    ).copyWith(windowVisible: true);

    expect(invalid.invariantViolations(), isNotEmpty);
    expect(
      () => AppStateMachine(initialState: invalid),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('reentrant listener dispatch is rejected without a nested mutation', () {
    final machine = AppStateMachine(
      initialState: _unlockedOnlineState(AppRuntimeKind.desktop),
    );
    addTearDown(machine.dispose);
    AppTransition? nested;
    machine.addListener(() {
      nested = machine.dispatch(AppEvent.lockRequested);
    });

    final outer = machine.dispatch(AppEvent.syncRequested);

    expect(outer.accepted, isTrue);
    expect(nested?.accepted, isFalse);
    expect(nested?.rejectionReason, contains('reentrant'));
    expect(machine.state.sync, AppSyncState.running);
    expect(machine.state.vault, AppVaultState.unlocked);
  });
}

AppMachineState _unlockedOnlineState(AppRuntimeKind runtime) {
  var state = AppMachineState.initial(runtime);
  for (final event in <AppEvent>[
    AppEvent.bootAuthenticated,
    AppEvent.unlockSucceeded,
    AppEvent.networkConnected,
  ]) {
    final transition = AppTransitionSystem.transition(state, event);
    expect(transition.accepted, isTrue, reason: event.name);
    state = transition.next;
  }
  return state;
}

String _controlStateKey(AppMachineState state) {
  final projection = Map<String, Object>.of(state.toFormalProjection())
    ..remove('revision');
  return projection.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('|');
}
