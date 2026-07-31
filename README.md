# ClipTown Flutter application

Shared Flutter product surface for ClipTown desktop and mobile clients: encrypted clipboard history, device management, recovery, local search, and zero-knowledge synchronization.

## Current foundation

The application provides a testable local ClipTown shell with search, pinning, clip-kind previews, and a clear disconnected-sync state. It does not claim cloud synchronization or production encryption until the authentication, key-management, and SDK contracts are integrated.

The sibling `cliptown-interfaces` checkout is required at `../cliptown-interfaces` for the generated Dart wire package.

## Security foundation

- `lib/security/security_models.dart` defines revisioned pending/active/suspended/revoked devices, backup email/phone summaries, recovery challenges, and local biometric/passkey/PIN policy.
- `lib/security/security_services.dart` defines narrow platform/provider boundaries for Signal Protocol, secure key storage, device enrollment/revocation, and recovery channels. It implements no cryptographic primitive.
- `lib/security/encrypted_object_planner.dart` creates bounded, contiguous encrypted upload plans with randomized Cloudflare R2 storage paths. Actual AEAD and key wrapping remain in reviewed providers.
- `lib/security/security_center_page.dart` provides a tested device/recovery management surface.

The six-digit PIN is a local unlock factor for a random device-wrapping key; it is never the account master key, clipboard/file encryption key, recovery key, or server credential. Biometrics remain in platform authenticators and raw templates never leave the device. Backup email and phone OTP are recovery/step-up channels only.

## Validation

```sh
flutter pub get
dart format lib test integration_test
flutter analyze --fatal-infos --fatal-warnings
flutter test --coverage
```

GitHub Actions additionally builds Linux, macOS, Windows, Android, and iOS simulator targets and executes the same search-and-pin integration flow on Android and iOS emulators. Mobile tests target the explicit `integration_test/app_test.dart` entrypoint so directory discovery cannot silently skip or misroute the device test.

## Platform boundaries

- Desktop clipboard monitoring, menu-bar/tray integration, and global shortcuts require native plugins and explicit permission onboarding.
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
