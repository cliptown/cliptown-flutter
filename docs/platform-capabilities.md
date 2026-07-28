# ClipTown platform capability contract

The machine-readable source of truth is [`platform-capabilities.json`](platform-capabilities.json). It separates operating-system constraints from implementation status so project documentation cannot imply that an OS-supported feature is already shipped.

## Constraint states

- `available` — the platform permits the capability without a special long-lived privilege.
- `permission_gated` — the capability requires explicit user, system, entitlement, portal, signing, or store approval.
- `foreground_only` — the capability is valid only during a visible user interaction or approved foreground surface.
- `impossible` — the general capability is incompatible with the platform application model.

## Implementation states

- `planned` — no production implementation is claimed.
- `foundation` — shared UI/model behavior exists, but the native integration is incomplete.
- `verified` — CI evidence demonstrates the stated build or behavior.

## Product rules

1. iOS and Android must never be described as supporting a hidden, continuously running clipboard-history daemon.
2. Desktop monitoring must remain visible, pausable, and compatible with per-application exclusions and protected-content filtering.
3. Platform key stores hold wrapped device/account material; a six-digit PIN is only a bounded local unlock factor.
4. Signing, notarization, store submission, and production downloads remain false until reviewed credentials and release evidence exist.
5. A capability marked `verified` must name repository evidence exercised by CI.

## Validation

`test/platform_capabilities_test.dart` parses the JSON source during the normal Flutter quality job. It rejects unknown states, missing permission or platform-boundary explanations, unsupported mobile background-capture claims, unevidenced verified claims, and premature release-readiness claims. The same pull request must continue to pass desktop builds and Android/iOS integration jobs.

The contract describes platform feasibility and current evidence only. It does not grant permissions, add entitlements, enable background capture, publish binaries, or authorize store submission.
