# Bluetooth proximity sharing

ClipTown uses Bluetooth Low Energy as an optional, foreground-only transport for
encrypted clipboard envelopes when ordinary networking is unavailable. It does
not turn Bluetooth discovery, pairing, bonding, RSSI, or a matching code into an
authentication factor.

The Flutter app is a BLE central on Windows, macOS, Linux, Android, and iOS. It
can advertise the ClipTown GATT service on Windows, macOS, Android, and iOS.
Linux Flutter builds are central-only until the Linux peripheral backend is
implemented and physically certified. The independent Rust desktop app is a
central on Windows, macOS, and Linux, so both desktop products can connect to an
advertising mobile device without depending on each other.

`lib/proximity/proximity_contract.dart` implements rotating discovery IDs,
six-digit transcript comparison, strict signed envelope parsing, ciphertext
digests, two-minute expiry, recipient/sender binding, sequence and replay
checks, and one-use consent. `ble_frame_codec.dart` provides bounded GATT
fragmentation/reassembly, and `ble_proximity_transport.dart` is the real
Universal BLE adapter. The adapter never starts automatically and tears down on
background, radio loss, permission loss, cancellation, or disconnect.

Images and files stay in ClipTown's encrypted-object/chunk model; a BLE frame is
not a plaintext file path or a second storage system. Authentication uses only
the opaque `shared-auth:step-up:relay` purpose. The 3FA app submits that request
through authenticated Shared Auth, and ClipTown waits for a separately verified
Shared Auth result. If Shared Auth is offline, clipboard sharing may continue
between already enrolled devices but step-up remains unavailable.

Unit and hosted builds prove deterministic protocol behavior and platform
compilation. They do not prove a radio. Production enablement requires physical
mobile-to-mobile and mobile-to-Windows/macOS/Linux canaries for both desktop
implementations, including wrong-code, one-sided consent, replay, reorder,
expiry, revocation, oversize, digest/signature mismatch, background, disconnect,
and reconnect cases.
