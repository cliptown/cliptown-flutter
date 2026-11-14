# ClipTown app lifecycle formal verification

This directory owns the executable specification for the shared mobile and
desktop Flutter control plane. The production transition authority is
`lib/state/app_state_machine.dart`; native lifecycle handlers, UI status, auth,
vault, device trust, connectivity, and sync must enter that reducer rather than
mutating parallel booleans. Clipboard capture intent and the ready, monitoring,
and controlled-fault effect states are part of the same authority.

## Safety properties

`app_lifecycle_safety` checks that:

1. cloud sync can run only for an authenticated active device with an unlocked
   vault and live network;
2. signed-out local mode may use an unlocked device vault, but it cannot sync;
3. capture requires explicit retained user intent plus every local-work guard;
4. automatic monitoring exists only on desktop and is represented separately
   from foreground/manual capture readiness;
5. capture faults deny further capture until explicit recovery, while disabling
   capture clears user intent;
6. mobile background execution locks and disables both capture and sync;
7. reviewed desktop tray background execution may retain vault, capture, and
   sync state but cannot escape device/vault/authentication gates;
8. expiry, suspension, shutdown, and native failure fail closed;
9. device revocation is monotonic, destroys local vault access, clears capture
   intent, and can only progress toward shutdown; and
10. window visibility agrees with the lifecycle phase.

The Dart reducer is total: every reachable abstract state is paired with every
`AppEvent` in `test/app_state_machine_test.dart`. Invalid events produce a
controlled rejection and preserve the previous valid state. Valid events must
advance the state revision and satisfy all invariants. Reentrant listener
dispatch is rejected so nested callbacks cannot interleave transitions.
`ClipboardController` checks the granted capability before clipboard reads,
native watcher starts, and watcher callbacks. Awaited reads and starts retain
the granting revision and suppress stale completion when state changes. The UI
hides loaded records and denies persistent local mutations whenever
`local_work_allowed` is false.

## Model-to-production refinement

CI uses Quint to typecheck deterministic scenarios, explore the invariant,
perform bounded Apalache verification, and emit ITF model-based testing traces.
`test/formal_trace_replay_test.dart` drives `tool/replay_formal_traces.dart`
inside the Flutter test harness, replays each generated action through the real
Dart reducer, and compares the complete public state projection after every
step. A divergence fails CI and leaves a trace artifact suitable for a focused
regression test.

## Exact claim strength

The Dart graph test is exhaustive over the finite control state (revision is
excluded only from graph identity and is checked separately). Quint simulation
uses the reproducible seed and bounds in `fm.toml`; Apalache verification checks
all executions up to the declared step bound. These checks establish the
abstract transition policy and its Dart refinement. They do **not** prove
Flutter engine, OS plugin, cryptographic-provider, network, filesystem, or
hardware behavior. Those components remain behind explicit ports and must
convert failures into `nativeFailure` or another reviewed event. No unbounded
liveness or eventual sync-delivery claim is made. Revision checks prove the
implemented command boundary, not cancellation of an OS operation after the OS
has already performed it.

## Local checks

```sh
QUINT_PACKAGE='@informalsystems/quint@0.32.0'

npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/app_lifecycle.qnt
npx --yes --package="$QUINT_PACKAGE" quint typecheck formal/app_lifecycle_test.qnt
npx --yes --package="$QUINT_PACKAGE" quint test \
  formal/app_lifecycle_test.qnt \
  --main=app_lifecycle_test \
  --match='.*Test$'
flutter test test/app_state_machine_test.dart
```

Java 17 or newer is required for `quint verify`; CI uses Java 21 and records the
exact manifest, model, production reducer, adapter, tool versions, and hashes.
