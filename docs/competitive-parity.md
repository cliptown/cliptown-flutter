# Competitive clipboard parity contract

ClipTown benchmarks itself against eight representative, actively maintained clipboard products whose current documentation describes meaningful behavior added or supported after 2021: Paste, CopyQ, Ditto, Maccy, Raycast Clipboard History, PastePal, Pastebot, and Microsoft SwiftKey Cloud Clipboard. This is a reproducible product benchmark, not a claim that an objective universal “top eight” ranking exists.

Primary product evidence:

- Paste: [search and filters](https://pasteapp.io/help/search-and-filters), [pinboards](https://pasteapp.io/help/organize-with-pinboards), [retention](https://pasteapp.io/help/control-history-retention), and [iPhone/iPad workflows](https://pasteapp.io/help/paste-on-iphone).
- CopyQ: [repository feature list](https://github.com/hluk/CopyQ) and [official documentation](https://copyq-docs.readthedocs.io/en/latest/).
- Ditto: [official repository](https://github.com/sabrogden/Ditto).
- Maccy: [official repository and feature list](https://github.com/p0deje/Maccy).
- Raycast: [Clipboard History manual](https://manual.raycast.com/clipboard-history) and [product page](https://www.raycast.com/core-features/clipboard-history).
- PastePal: [App Store feature list](https://apps.apple.com/us/app/clipboard-manager-pastepal/id1503446680) and [public repository](https://github.com/IndieGoodies/PastePal).
- Pastebot: [product/help index](https://tapbots.com/pastebot), [filters](https://tapbots.com/pastebot/help/05_filters/), and [sequential paste](https://tapbots.com/pastebot/help/07_sequential_paste/).
- SwiftKey: [Windows/Android Cloud Clipboard documentation](https://support.microsoft.com/en-us/swiftkey-keyboard/how-to-use-microsoft-swiftkey-keyboard-to-copy-and-paste-text-between-swiftkey-and-windows).

## Release-blocking matrix

Legend: **implemented** means code plus local automated evidence exists; **hosted gate** means the workflow exists but the exact branch must still pass; **planned** means the gap blocks a parity claim.

| Capability represented in benchmark | Flutter desktop | Rust desktop | Flutter mobile | Release rule |
| --- | --- | --- | --- | --- |
| Search text, metadata, tags, type, collection | Implemented | Implemented | Implemented foreground UI | Must pass shared query fixtures |
| Local text-vector index and related-result search | Implemented with encrypted SQLite Float32 vectors | Implemented with SQLite + `sqlite-vec` | Implemented in shared Flutter app | Never upload plaintext vectors |
| Configurable saved-item count and age retention | Implemented; pinned clips exempt | Implemented count limit; pinned clips exempt | Shared Flutter behavior | Boundary tests at 1 and 100,000 |
| Text, HTML, images, and file-list clipboard formats | Implemented desktop adapter and local index | Implemented desktop adapter and local index | Foreground/share adapters planned | Native round-trip E2E per supported format |
| Pin/favorite, collections/groups, tags, rename | Implemented | Core pin/search implemented; collection/tag UI planned | Shared Flutter UI | Shared fixtures must preserve metadata |
| Pause capture, exclude apps, reject likely secrets | Implemented policy; source-app identity adapter incomplete | Policy/UI onboarding planned | Background daemon prohibited | Platform privacy tests are blocking |
| Sequential paste queue | Implemented | Planned | Shared UI only | Ordered-copy journey required |
| Plain paste and deterministic transforms | Implemented baseline transforms | Planned | Shared UI | Transform corpus must match both desktops |
| Tray/menu-bar lifecycle and global shortcut | Implemented foundation | GPUI window foundation; tray/hotkey planned | Not applicable | Installed-app journey on all desktop OSes |
| OCR, QR generation, color intelligence | Planned | Planned | Planned | Required before union-parity claim |
| Scripting/CLI automation | Planned in Flutter product | Implemented CLI contract probe and commands | Not applicable | Sandboxed scripting/security design required |
| Encrypted device-to-device sync | Planned | Planned | Planned | Cryptographic and revocation E2E required |
| Encrypted image/file objects in Cloudflare R2 | Upload planner only; transfer planned | Planned | Planner shared in Flutter | R2/MinIO contract plus live R2 canary required |
| Encrypted metadata/vector backup in Postgres and CockroachDB | Planned schema/contract | Planned schema/contract | Planned | Declarative migration convergence on both engines |
| iOS share/keyboard extensions and Android share/input method | Not applicable | Not applicable | Planned | Real-device acceptance and store-policy review |
| Shared pinboards/collaboration | Planned | Planned | Planned | Explicit end-to-end privacy and authorization model |
| Signed installers, auto-update, stores | Planned | Planned | Planned | Separate signed canary for every target |

## Paired-desktop rule

The Flutter and Rust desktop applications are developed perpetually and independently. Each pull request that changes shared clipboard behavior must run the same versioned, privacy-safe fixture corpus against both implementations. The corpus covers text, rich text, PNG metadata, file lists, deduplication, pin preservation, retention, lexical search, vector dimensions/model identifiers, and deterministic rejection outcomes. UI-toolkit-specific behavior remains in each repository's own E2E suite.

Neither desktop client can inherit the other client's evidence. A green Flutter macOS run does not verify Rust macOS, and a Rust contract probe does not verify an installed Flutter app. The organization-level release gate requires exact-head evidence for both clients on Windows, macOS, and Linux, plus Flutter on Android and iOS.
