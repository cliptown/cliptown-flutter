# Android release signing and developer verification

The Android application identity is `com.cliptown.cliptown_app`. Treat it as
durable: changing it creates a different Android application and a different
Google developer-verification record.

As of 2026-09-05, this package is registered in the Google Android developer
console with one verified signing fingerprint. That public registration does
not establish that the repository's release pipeline uses the same certificate
or that the key is an approved, recoverable production upload identity. This
repository does not create or retain a production key.

## Owner-controlled setup

An authorized owner must generate or select the production upload key, retain
and back it up through the approved encrypted secret lifecycle, and verify its
public SHA-256 certificate fingerprint against Google's record. Record
revocation and recovery ownership without copying private key material into an
issue, pull request, workflow log, repository, or chat.

Create a protected GitHub environment named `mobile-release`, require an owner
approval for deployments from it, and provision these environment secrets:

- `CLIPTOWN_ANDROID_KEYSTORE_BASE64`
- `CLIPTOWN_ANDROID_KEYSTORE_PASSWORD`
- `CLIPTOWN_ANDROID_KEY_ALIAS`
- `CLIPTOWN_ANDROID_KEY_PASSWORD`

## Release procedure

Run the `Mobile release candidate` workflow manually with a semantic version
and a monotonically increasing positive Android build number. The workflow:

1. validates the repository signing contract and protected inputs;
2. checks out the exact pinned public interface package;
3. materializes the upload keystore only on the ephemeral runner;
4. removes only dev-dependency plugin blocks from Flutter's ignored, generated
   Android registrant while retaining every production plugin registration;
5. creates an obfuscated, signed Android App Bundle;
6. verifies the bundle signature and retains the AAB, Dart symbols, dependency
   graph, source SHA, workflow run ID, version, build number, and checksums;
7. destroys the materialized keystore even when the build fails.

Outside that workflow, any requested Gradle release task fails before building
unless all four `CLIPTOWN_ANDROID_*` signing values are present and the keystore
path identifies a real file. Development and test tasks do not need release
signing material. Release builds never fall back to the debug key.

The retained artifact is a release candidate, not proof of store or device
delivery. Before declaring production readiness, separately verify the public
production fingerprint in Google's console, upload/install the exact retained
AAB through the intended distribution channel, and record a physical-device
acceptance result tied to its source SHA and checksum.
