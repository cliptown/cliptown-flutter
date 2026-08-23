# ClipTown app lifecycle formal verification

This directory owns the executable specification for the shared mobile and
desktop Flutter control plane. The production transition authority is
`lib/state/app_state_machine.dart`; native lifecycle handlers, UI status, auth,
vault, device trust, connectivity, and sync must enter that reducer rather than
mutating parallel booleans.

## Safety properties

`app_lifecycle_safety` checks that:

1. unauthenticated, pending, suspended, and revoked devices cannot unlock the
   vault or sync;
2. sync can run only for an authenticated active device with an unlocked vault
   and live network;
3. mobile background execution locks and disables sync;
4. desktop tray background execution is explicitly modeled and cannot escape
   the same authentication/device/vault gates;
5. expiry, suspension, shutdown, and native failure fail closed;
6. device revocation is monotonic, destroys local vault access, and can only
   progress toward shutdown; and
7. window visibility agrees with the lifecycle phase.

The Dart reducer is total: every reachable abstract state is paired with every
`AppEvent` in `test/app_state_machine_test.dart`. Invalid events produce a
controlled rejection and preserve the previous valid state. Valid events must
advance the state revision and satisfy all invariants. Reentrant listener
dispatch is rejected so nested callbacks cannot interleave transitions.

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
liveness or eventual sync-delivery claim is made.

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
