# Companion desktop implementation

This repository is the **live Flutter desktop implementation** for Cliptown.

## Allocated pair

- Flutter: [`cliptown/cliptown-flutter`](https://github.com/cliptown/cliptown-flutter) — **live**; this repository.
- Rust: [`cliptown/cliptown-desktop.rs`](https://github.com/cliptown/cliptown-desktop.rs) — **planned** and not yet verified as a published repository.

The planned URL is an allocation target, not proof that the remote exists. Do not mark the Rust implementation live until its repository, native targets, tests, packaging, and release status are verified.

## Feature-delivery contract

For every desktop-facing feature:

1. inspect both implementations before deciding scope;
2. define shared acceptance criteria for clipboard monitoring, tray behavior, global shortcuts, pinned/history items, local storage, offline sync, authentication, and cross-device state;
3. version affected APIs, schemas, clients, assets, fixtures, and conformance tests deliberately;
4. update both implementations, or record an explicit no-change rationale;
5. test and report Rust and Flutter status separately; and
6. keep reciprocal repository references current.

Until the Rust repository is published, feature plans must reserve its companion scope rather than treating Flutter completion as full desktop parity.

## Lifecycle state authority

The Flutter desktop window/tray host reports foreground, background, shutdown,
and native-failure events to `lib/state/app_state_machine.dart`. Close-to-tray
is an explicit desktop background state, not an independent boolean. Mobile
background always locks and disables sync; desktop background may retain an
unlocked vault only while the shared authentication, device-trust, and sync
invariants continue to hold. The matching Quint model and Dart ITF replay live
under `formal/`.

## Project routing

- GitHub Project: [`cliptown-project` — Project 1](https://github.com/orgs/cliptown/projects/1)
- Canonical portfolio registry: [`ORESoftware/project-registry`](https://github.com/ORESoftware/project-registry/blob/main/registry/desktop-applications.json)
- Linear rollout: [`DEN-2469`](https://linear.app/denman/issue/DEN-2469/roll-out-paired-rust-flutter-desktop-repositories-across-the-portfolio)
