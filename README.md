# ClipTown Flutter

Cross-platform Flutter client for encrypted clipboard history, device management, recovery, local search, and zero-knowledge synchronization.

## Security foundation

- `lib/security/security_models.dart` defines revisioned pending/active/suspended/revoked devices, backup email/phone summaries, recovery challenges, and local biometric/passkey/PIN policy.
- `lib/security/security_services.dart` defines narrow platform/provider boundaries for Signal Protocol, secure key storage, device enrollment/revocation, and recovery channels. It implements no cryptographic primitive.
- `lib/security/encrypted_object_planner.dart` creates bounded, contiguous encrypted upload plans with randomized Cloudflare R2 storage paths. Actual AEAD and key wrapping remain in reviewed providers.
- `lib/security/security_center_page.dart` provides a tested device/recovery management surface.

The six-digit PIN is a local unlock factor for a random device-wrapping key; it is never the account master key, clipboard/file encryption key, recovery key, or server credential. Biometrics remain in platform authenticators and raw templates never leave the device. Backup email and phone OTP are recovery/step-up channels only.

## Required production adapters

Before enabling sync, implement and review:

1. Signal Protocol through a maintained Flutter FFI/platform bridge;
2. Keychain/Secure Enclave, Android Keystore/BiometricPrompt, Windows Hello, and platform-equivalent secure storage;
3. authenticated Rust/Supabase device and recovery APIs;
4. per-clip/per-object random keys, chunked AEAD, resumable R2 upload/download, and manifest validation;
5. multi-device/recovery/revocation/replay E2E tests.

No plaintext clipboard data, content key, PIN, biometric template, OTP code, or private Signal key may be logged, synchronized, or uploaded.
