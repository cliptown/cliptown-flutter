import 'package:flutter/foundation.dart';

/// The runtime family changes the security rule for background execution.
/// Mobile clients lock on background; desktop clients may remain unlocked while
/// hidden in the tray so reviewed background clipboard work can continue.
enum AppRuntimeKind { mobile, desktop }

enum AppLifecyclePhase {
  starting,
  foreground,
  background,
  stopping,
  stopped,
  faulted,
}

enum AppAuthenticationState {
  signedOut,
  authenticated,
  reauthenticationRequired,
  revoked,
}

enum LocalDeviceTrustState { pending, active, suspended, revoked }

enum AppVaultState { unavailable, locked, unlocked, destroyed }

enum AppSyncState { disabled, idle, running, backoff }

/// Every control-plane input is represented here. The reducer below switches
/// exhaustively over this enum, so adding an event is a compile-time change to
/// the transition relation rather than an unreviewed callback path.
enum AppEvent {
  bootSignedOut,
  bootAuthenticated,
  signInSucceeded,
  deviceApproved,
  deviceResumed,
  unlockSucceeded,
  lockRequested,
  authenticationExpired,
  signOutRequested,
  deviceSuspended,
  deviceRevoked,
  networkConnected,
  networkDisconnected,
  syncRequested,
  syncSucceeded,
  syncFailed,
  retryRequested,
  foregroundRequested,
  backgroundRequested,
  shutdownRequested,
  shutdownCompleted,
  nativeFailure,
}

@immutable
final class AppMachineState {
  const AppMachineState({
    required this.runtime,
    required this.lifecycle,
    required this.authentication,
    required this.localDevice,
    required this.vault,
    required this.sync,
    required this.online,
    required this.windowVisible,
    required this.revocationObserved,
    required this.revision,
  });

  factory AppMachineState.initial(AppRuntimeKind runtime) => AppMachineState(
    runtime: runtime,
    lifecycle: AppLifecyclePhase.starting,
    authentication: AppAuthenticationState.signedOut,
    localDevice: LocalDeviceTrustState.pending,
    vault: AppVaultState.unavailable,
    sync: AppSyncState.disabled,
    online: false,
    windowVisible: false,
    revocationObserved: false,
    revision: 0,
  );

  factory AppMachineState.signedOut(AppRuntimeKind runtime) => AppMachineState(
    runtime: runtime,
    lifecycle: AppLifecyclePhase.foreground,
    authentication: AppAuthenticationState.signedOut,
    localDevice: LocalDeviceTrustState.pending,
    vault: AppVaultState.unavailable,
    sync: AppSyncState.disabled,
    online: false,
    windowVisible: true,
    revocationObserved: false,
    revision: 1,
  );

  final AppRuntimeKind runtime;
  final AppLifecyclePhase lifecycle;
  final AppAuthenticationState authentication;
  final LocalDeviceTrustState localDevice;
  final AppVaultState vault;
  final AppSyncState sync;
  final bool online;
  final bool windowVisible;
  final bool revocationObserved;
  final int revision;

  bool get isTerminating =>
      lifecycle == AppLifecyclePhase.stopping ||
      lifecycle == AppLifecyclePhase.stopped ||
      lifecycle == AppLifecyclePhase.faulted;

  bool get permitsSensitiveWork =>
      authentication == AppAuthenticationState.authenticated &&
      localDevice == LocalDeviceTrustState.active &&
      vault == AppVaultState.unlocked &&
      (lifecycle == AppLifecyclePhase.foreground ||
          (runtime == AppRuntimeKind.desktop &&
              lifecycle == AppLifecyclePhase.background));

  AppMachineState copyWith({
    AppRuntimeKind? runtime,
    AppLifecyclePhase? lifecycle,
    AppAuthenticationState? authentication,
    LocalDeviceTrustState? localDevice,
    AppVaultState? vault,
    AppSyncState? sync,
    bool? online,
    bool? windowVisible,
    bool? revocationObserved,
    int? revision,
  }) => AppMachineState(
    runtime: runtime ?? this.runtime,
    lifecycle: lifecycle ?? this.lifecycle,
    authentication: authentication ?? this.authentication,
    localDevice: localDevice ?? this.localDevice,
    vault: vault ?? this.vault,
    sync: sync ?? this.sync,
    online: online ?? this.online,
    windowVisible: windowVisible ?? this.windowVisible,
    revocationObserved: revocationObserved ?? this.revocationObserved,
    revision: revision ?? this.revision,
  );

  /// Returns every violated safety property. An empty result means the state
  /// belongs to the valid control-state space.
  List<String> invariantViolations() {
    final violations = <String>[];

    if (revision < 0) {
      violations.add('revision must be non-negative');
    }

    final shouldShowWindow = lifecycle == AppLifecyclePhase.foreground;
    if (windowVisible != shouldShowWindow) {
      violations.add('the window is visible exactly in foreground state');
    }

    if (authentication != AppAuthenticationState.authenticated &&
        (vault == AppVaultState.unlocked || sync != AppSyncState.disabled)) {
      violations.add('unauthenticated sessions are locked and sync-disabled');
    }

    if (localDevice != LocalDeviceTrustState.active &&
        (vault == AppVaultState.unlocked || sync != AppSyncState.disabled)) {
      violations.add('untrusted local devices are locked and sync-disabled');
    }

    if (vault != AppVaultState.unlocked && sync != AppSyncState.disabled) {
      violations.add('sync is disabled whenever the vault is not unlocked');
    }

    if (sync == AppSyncState.running && (!online || !permitsSensitiveWork)) {
      violations.add('running sync requires every sensitive-work guard');
    }

    if (runtime == AppRuntimeKind.mobile &&
        lifecycle == AppLifecyclePhase.background &&
        (vault == AppVaultState.unlocked || sync != AppSyncState.disabled)) {
      violations.add('mobile background state is locked and sync-disabled');
    }

    if ({
          AppLifecyclePhase.starting,
          AppLifecyclePhase.stopping,
          AppLifecyclePhase.stopped,
          AppLifecyclePhase.faulted,
        }.contains(lifecycle) &&
        (vault == AppVaultState.unlocked || sync != AppSyncState.disabled)) {
      violations.add('non-operational lifecycle states fail closed');
    }

    if (localDevice == LocalDeviceTrustState.revoked) {
      if (authentication != AppAuthenticationState.revoked ||
          vault != AppVaultState.destroyed ||
          sync != AppSyncState.disabled ||
          !revocationObserved) {
        violations.add(
          'revoked devices have revoked auth, destroyed keys, and disabled sync',
        );
      }
    } else if (revocationObserved) {
      violations.add('device revocation is monotonic');
    }

    if (vault == AppVaultState.destroyed &&
        localDevice != LocalDeviceTrustState.revoked) {
      violations.add('only a revoked device may have a destroyed vault');
    }

    return List<String>.unmodifiable(violations);
  }

  /// Stable projection used by model-generated trace replay. Numeric values are
  /// deliberately aligned with the constants in formal/app_lifecycle.qnt.
  Map<String, Object> toFormalProjection() => <String, Object>{
    'runtime': runtime.index,
    'lifecycle': lifecycle.index,
    'authentication': authentication.index,
    'local_device': localDevice.index,
    'vault': vault.index,
    'sync': sync.index,
    'online': online,
    'window_visible': windowVisible,
    'revocation_observed': revocationObserved,
    'revision': revision,
  };
}

@immutable
final class AppTransition {
  const AppTransition._({
    required this.event,
    required this.previous,
    required this.next,
    required this.accepted,
    this.rejectionReason,
    this.invariantViolations = const <String>[],
  });

  factory AppTransition.accepted({
    required AppEvent event,
    required AppMachineState previous,
    required AppMachineState next,
  }) => AppTransition._(
    event: event,
    previous: previous,
    next: next,
    accepted: true,
  );

  factory AppTransition.rejected({
    required AppEvent event,
    required AppMachineState state,
    required String reason,
    List<String> invariantViolations = const <String>[],
  }) => AppTransition._(
    event: event,
    previous: state,
    next: state,
    accepted: false,
    rejectionReason: reason,
    invariantViolations: List<String>.unmodifiable(invariantViolations),
  );

  final AppEvent event;
  final AppMachineState previous;
  final AppMachineState next;
  final bool accepted;
  final String? rejectionReason;
  final List<String> invariantViolations;
}

/// Pure, deterministic, and total app transition relation.
abstract final class AppTransitionSystem {
  static AppTransition transition(AppMachineState state, AppEvent event) {
    final currentViolations = state.invariantViolations();
    if (currentViolations.isNotEmpty) {
      return AppTransition.rejected(
        event: event,
        state: state,
        reason: 'current state violates the app safety invariant',
        invariantViolations: currentViolations,
      );
    }

    AppTransition reject(String reason) =>
        AppTransition.rejected(event: event, state: state, reason: reason);

    AppTransition accept(AppMachineState candidate) {
      final next = candidate.copyWith(revision: state.revision + 1);
      final violations = next.invariantViolations();
      if (violations.isNotEmpty) {
        return AppTransition.rejected(
          event: event,
          state: state,
          reason: 'candidate state violates the app safety invariant',
          invariantViolations: violations,
        );
      }
      return AppTransition.accepted(event: event, previous: state, next: next);
    }

    bool isOperationalLifecycle() =>
        state.lifecycle == AppLifecyclePhase.foreground ||
        state.lifecycle == AppLifecyclePhase.background;

    AppVaultState lockedVault() => switch (state.vault) {
      AppVaultState.unavailable => AppVaultState.unavailable,
      AppVaultState.destroyed => AppVaultState.destroyed,
      AppVaultState.locked || AppVaultState.unlocked => AppVaultState.locked,
    };

    return switch (event) {
      AppEvent.bootSignedOut =>
        state.lifecycle != AppLifecyclePhase.starting
            ? reject('signed-out boot completion requires starting state')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.foreground,
                  authentication: AppAuthenticationState.signedOut,
                  localDevice: LocalDeviceTrustState.pending,
                  vault: AppVaultState.unavailable,
                  sync: AppSyncState.disabled,
                  windowVisible: true,
                ),
              ),
      AppEvent.bootAuthenticated =>
        state.lifecycle != AppLifecyclePhase.starting
            ? reject('authenticated boot completion requires starting state')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.foreground,
                  authentication: AppAuthenticationState.authenticated,
                  localDevice: LocalDeviceTrustState.active,
                  vault: AppVaultState.locked,
                  sync: AppSyncState.disabled,
                  windowVisible: true,
                ),
              ),
      AppEvent.signInSucceeded =>
        !isOperationalLifecycle() ||
                state.localDevice == LocalDeviceTrustState.revoked ||
                (state.authentication != AppAuthenticationState.signedOut &&
                    state.authentication !=
                        AppAuthenticationState.reauthenticationRequired)
            ? reject('sign-in is not valid from the current identity state')
            : accept(
                state.copyWith(
                  authentication: AppAuthenticationState.authenticated,
                  vault: AppVaultState.locked,
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.deviceApproved =>
        !isOperationalLifecycle() ||
                state.authentication != AppAuthenticationState.authenticated ||
                state.localDevice != LocalDeviceTrustState.pending
            ? reject('device approval requires authenticated pending device')
            : accept(
                state.copyWith(
                  localDevice: LocalDeviceTrustState.active,
                  vault: AppVaultState.locked,
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.deviceResumed =>
        !isOperationalLifecycle() ||
                state.authentication != AppAuthenticationState.authenticated ||
                state.localDevice != LocalDeviceTrustState.suspended
            ? reject('device resume requires authenticated suspended device')
            : accept(
                state.copyWith(
                  localDevice: LocalDeviceTrustState.active,
                  vault: AppVaultState.locked,
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.unlockSucceeded =>
        !isOperationalLifecycle() ||
                state.authentication != AppAuthenticationState.authenticated ||
                state.localDevice != LocalDeviceTrustState.active ||
                state.vault != AppVaultState.locked ||
                (state.runtime == AppRuntimeKind.mobile &&
                    state.lifecycle == AppLifecyclePhase.background)
            ? reject('vault unlock requires every sensitive-work guard')
            : accept(
                state.copyWith(
                  vault: AppVaultState.unlocked,
                  sync: AppSyncState.idle,
                ),
              ),
      AppEvent.lockRequested =>
        state.vault != AppVaultState.unlocked
            ? reject('lock requires an unlocked vault')
            : accept(
                state.copyWith(
                  vault: AppVaultState.locked,
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.authenticationExpired =>
        !isOperationalLifecycle() ||
                state.authentication != AppAuthenticationState.authenticated ||
                state.localDevice == LocalDeviceTrustState.revoked
            ? reject('authentication expiry requires a live session')
            : accept(
                state.copyWith(
                  authentication:
                      AppAuthenticationState.reauthenticationRequired,
                  vault: lockedVault(),
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.signOutRequested =>
        !isOperationalLifecycle() ||
                state.authentication == AppAuthenticationState.revoked ||
                state.localDevice == LocalDeviceTrustState.revoked
            ? reject('sign-out is unavailable for a revoked or stopped app')
            : accept(
                state.copyWith(
                  authentication: AppAuthenticationState.signedOut,
                  vault: lockedVault(),
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.deviceSuspended =>
        !isOperationalLifecycle() ||
                state.localDevice != LocalDeviceTrustState.active
            ? reject('only an active device can be suspended')
            : accept(
                state.copyWith(
                  authentication:
                      AppAuthenticationState.reauthenticationRequired,
                  localDevice: LocalDeviceTrustState.suspended,
                  vault: lockedVault(),
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.deviceRevoked =>
        !isOperationalLifecycle() ||
                state.localDevice == LocalDeviceTrustState.revoked
            ? reject('device revocation requires a live non-revoked device')
            : accept(
                state.copyWith(
                  authentication: AppAuthenticationState.revoked,
                  localDevice: LocalDeviceTrustState.revoked,
                  vault: AppVaultState.destroyed,
                  sync: AppSyncState.disabled,
                  revocationObserved: true,
                ),
              ),
      AppEvent.networkConnected =>
        !isOperationalLifecycle() || state.online
            ? reject('network is already connected or app is not operational')
            : accept(state.copyWith(online: true)),
      AppEvent.networkDisconnected =>
        !isOperationalLifecycle() || !state.online
            ? reject(
                'network is already disconnected or app is not operational',
              )
            : accept(
                state.copyWith(
                  online: false,
                  sync: state.sync == AppSyncState.running
                      ? AppSyncState.backoff
                      : state.sync,
                ),
              ),
      AppEvent.syncRequested =>
        !state.permitsSensitiveWork ||
                !state.online ||
                (state.sync != AppSyncState.idle &&
                    state.sync != AppSyncState.backoff)
            ? reject(
                'sync requires unlocked, trusted, online idle/backoff state',
              )
            : accept(state.copyWith(sync: AppSyncState.running)),
      AppEvent.syncSucceeded =>
        state.sync != AppSyncState.running
            ? reject('sync success requires a running sync')
            : accept(state.copyWith(sync: AppSyncState.idle)),
      AppEvent.syncFailed =>
        state.sync != AppSyncState.running
            ? reject('sync failure requires a running sync')
            : accept(state.copyWith(sync: AppSyncState.backoff)),
      AppEvent.retryRequested =>
        !state.permitsSensitiveWork ||
                !state.online ||
                state.sync != AppSyncState.backoff
            ? reject('retry requires unlocked, trusted, online backoff state')
            : accept(state.copyWith(sync: AppSyncState.running)),
      AppEvent.foregroundRequested =>
        (state.lifecycle != AppLifecyclePhase.foreground &&
                state.lifecycle != AppLifecyclePhase.background)
            ? reject('foreground request requires a live app')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.foreground,
                  windowVisible: true,
                ),
              ),
      AppEvent.backgroundRequested =>
        (state.lifecycle != AppLifecyclePhase.foreground &&
                state.lifecycle != AppLifecyclePhase.background)
            ? reject('background request requires a live app')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.background,
                  windowVisible: false,
                  vault: state.runtime == AppRuntimeKind.mobile
                      ? lockedVault()
                      : state.vault,
                  sync: state.runtime == AppRuntimeKind.mobile
                      ? AppSyncState.disabled
                      : state.sync,
                ),
              ),
      AppEvent.shutdownRequested =>
        !{
              AppLifecyclePhase.starting,
              AppLifecyclePhase.foreground,
              AppLifecyclePhase.background,
              AppLifecyclePhase.faulted,
            }.contains(state.lifecycle)
            ? reject('shutdown is already in progress or complete')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.stopping,
                  windowVisible: false,
                  vault: lockedVault(),
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.shutdownCompleted =>
        state.lifecycle != AppLifecyclePhase.stopping
            ? reject('shutdown completion requires stopping state')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.stopped,
                  windowVisible: false,
                  vault: lockedVault(),
                  sync: AppSyncState.disabled,
                ),
              ),
      AppEvent.nativeFailure =>
        !{
              AppLifecyclePhase.starting,
              AppLifecyclePhase.foreground,
              AppLifecyclePhase.background,
              AppLifecyclePhase.stopping,
            }.contains(state.lifecycle)
            ? reject('native failure is already contained')
            : accept(
                state.copyWith(
                  lifecycle: AppLifecyclePhase.faulted,
                  windowVisible: false,
                  vault: lockedVault(),
                  sync: AppSyncState.disabled,
                ),
              ),
    };
  }
}

/// Mutable Flutter-facing shell around the pure transition system.
final class AppStateMachine extends ChangeNotifier {
  AppStateMachine({required AppMachineState initialState})
    : _state = initialState {
    final violations = initialState.invariantViolations();
    if (violations.isNotEmpty) {
      throw ArgumentError.value(
        initialState,
        'initialState',
        'invalid app state: ${violations.join('; ')}',
      );
    }
  }

  factory AppStateMachine.initial(AppRuntimeKind runtime) =>
      AppStateMachine(initialState: AppMachineState.initial(runtime));

  factory AppStateMachine.signedOut(AppRuntimeKind runtime) =>
      AppStateMachine(initialState: AppMachineState.signedOut(runtime));

  AppMachineState _state;
  AppTransition? _lastTransition;
  bool _dispatching = false;

  AppMachineState get state => _state;
  AppTransition? get lastTransition => _lastTransition;

  String get statusLabel {
    if (_state.lifecycle == AppLifecyclePhase.faulted) {
      return 'Controlled fault • vault locked • sync disabled';
    }
    return switch (_state.authentication) {
      AppAuthenticationState.signedOut =>
        'Signed out • vault ${_state.vault.name} • sync disabled',
      AppAuthenticationState.reauthenticationRequired =>
        'Reauthentication required • vault ${_state.vault.name} • sync disabled',
      AppAuthenticationState.revoked => 'Device revoked • local keys destroyed',
      AppAuthenticationState.authenticated =>
        '${_state.lifecycle.name} • vault ${_state.vault.name} • sync ${_state.sync.name}',
    };
  }

  AppTransition dispatch(AppEvent event) {
    if (_dispatching) {
      return AppTransition.rejected(
        event: event,
        state: _state,
        reason: 'reentrant dispatch is controlled and rejected',
      );
    }

    _dispatching = true;
    try {
      final transition = AppTransitionSystem.transition(_state, event);
      _lastTransition = transition;
      if (transition.accepted) {
        _state = transition.next;
        notifyListeners();
      }
      return transition;
    } finally {
      _dispatching = false;
    }
  }
}
