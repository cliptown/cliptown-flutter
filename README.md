# ClipTown Flutter application

Shared Flutter product surface for ClipTown desktop and mobile clients: encrypted clipboard history, device management, recovery, local search, and zero-knowledge synchronization.

The app also contains a foreground-only Bluetooth LE proximity transport for
encrypted clipboard and opaque Shared Auth/3FA requests. See
[`docs/bluetooth-proximity.md`](docs/bluetooth-proximity.md); Bluetooth never
counts as an authentication factor and mocked CI is not physical-radio proof.

## Current foundation

The application provides a testable local ClipTown shell with hybrid lexical/vector search, pinning, collections, a sequential-paste queue, configurable history size, safe transforms, rich clip-kind previews, and automatic text/image/file capture on supported desktops. On macOS, Windows, and supported Linux desktops it also installs a system-tray lifecycle: closing the main window hides it without terminating the process, and **Open ClipTown** restores a normal resizable 1100×760 window in the center of the active display. **Quit ClipTown** is the explicit process-exit path.

Local clipboard records and 384-dimensional text vectors are stored in an SQLite3MultipleCiphers database. A random 256-bit database key is kept in platform secure storage; an existing database with a missing or invalid key is locked rather than reset or opened as plaintext. The deterministic `cliptown-fnv1a-v1` embedding is a private, offline retrieval baseline, not a claim of model-quality semantic understanding. Cloud synchronization remains disabled until authenticated device key management, encrypted R2 object transfer, and Postgres/CockroachDB backup contracts are implemented and verified.

The Apple release entitlement files deliberately declare an empty
`keychain-access-groups` array so Keychain uses the app's default access group. Do
not insert an application identifier prefix until the corresponding Apple team,
provisioning profile, and signed release identity are configured: any restricted
keychain access-group entitlement on an ad-hoc-signed macOS debug build is rejected
by taskgated before Flutter starts. macOS debug/profile builds therefore use the
encrypted login Keychain without the data-protection access-group entitlement;
signed release builds opt into the data-protection Keychain. Hosted macOS E2E proves
debug Keychain persistence, while signed release acceptance must separately prove
the provisioned production path.

The independent native Rust/GPUI desktop client lives in [`cliptown-desktop.rs`](https://github.com/cliptown/cliptown-desktop.rs). The Rust and Flutter desktop applications are peer products: neither is a rewrite, compatibility shim, fallback, or successor to the other. Their behavior is validated against shared fixtures while each keeps its own UI toolkit, storage implementation, release artifacts, and roadmap.

The sibling `cliptown-interfaces` checkout is required at `../cliptown-interfaces` for the generated Dart wire package.

## Security foundation

- `lib/security/security_models.dart` defines revisioned pending/active/suspended/revoked devices, backup email/phone summaries, recovery challenges, and local biometric/passkey/PIN policy.
- `lib/security/security_services.dart` defines narrow platform/provider boundaries for Signal Protocol, secure key storage, device enrollment/revocation, and recovery channels. It implements no cryptographic primitive.
- `lib/security/encrypted_object_planner.dart` creates bounded, contiguous encrypted upload plans with randomized Cloudflare R2 storage paths. Actual AEAD and key wrapping remain in reviewed providers.
- `lib/history/sqlite_clip_repository.dart` stores encrypted rich history plus Float32 text vectors in SQLite and refuses plaintext fallback.
- `lib/clipboard/clipboard_service.dart` monitors and round-trips text, HTML, PNG, and file URI clipboard formats with explicit size bounds.
- `lib/security/security_center_page.dart` provides a tested device/recovery management surface.

The six-digit PIN is a local unlock factor for a random device-wrapping key; it is never the account master key, clipboard/file encryption key, recovery key, or server credential. Biometrics remain in platform authenticators and raw templates never leave the device. Backup email and phone OTP are recovery/step-up channels only.

## Validation

```sh
flutter pub get
dart format lib test integration_test
flutter analyze --fatal-infos --fatal-warnings
flutter test --coverage
flutter test integration_test/desktop_lifecycle_test.dart -d macos
flutter test integration_test/desktop_clipboard_e2e_test.dart -d macos
```

GitHub Actions builds Linux, macOS, Windows, Android, and iOS simulator targets with pinned Flutter 3.44.2. Each desktop runner executes three installed-app journeys—create/search/pin, native clipboard capture/search/queue/copy, and close-to-background/tray restore—and uploads the application plus crash diagnostics. Android and iOS execute the product and security-center flows on emulators/simulators. A successful compile is not treated as an E2E pass.

The feature benchmark and release-blocking parity gaps are tracked in [`docs/competitive-parity.md`](docs/competitive-parity.md). “Parity” means tested behavior under the relevant OS constraints; documentation or an unexercised code path does not count.

## Platform boundaries

- Desktop clipboard monitoring, menu-bar/tray integration, and global shortcuts require native plugins and explicit permission onboarding.
- Desktop tray lifecycle is enabled only if native tray setup succeeds. When unavailable (for example, GNOME without AppIndicator support), close-to-background is disabled so the application cannot become an unreachable hidden process.
- iOS and Android use user-initiated share, keyboard, or foreground capture flows; background clipboard access is not assumed.
- Production sessions and key material must use platform secure storage and the reviewed ClipTown auth/encryption architecture.

## Required production adapters

Before enabling sync, implement and review:

1. Signal Protocol through a maintained Flutter FFI/platform bridge;
2. Keychain/Secure Enclave, Android Keystore/BiometricPrompt, Windows Hello, and platform-equivalent secure storage;
3. authenticated Rust/Supabase device and recovery APIs;
4. per-clip/per-object random keys, chunked AEAD, resumable R2 upload/download, and manifest validation;
5. multi-device/recovery/revocation/replay E2E tests.

No plaintext clipboard data, content key, PIN, biometric template, OTP code, or private Signal key may be logged, synchronized, or uploaded.
