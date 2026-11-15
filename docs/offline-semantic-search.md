# Offline MiniLM semantic clipboard search (desktop)

ClipTown keeps **lexical search** (titles, text, tags, collections and apps)
and additionally finds related text by **meaning**, even when no query word is
present in the saved clip. This is local inference; clipboard content is never
sent to Hugging Face, OpenAI or any external endpoint.

## Storage

The existing encrypted history stays unchanged at the platform app-support
location under `ClipTown/clip-history.v1.db`. Derived semantic vectors are
deliberately allowed to be unencrypted, as a disposable cache:

- macOS: `~/Library/Application Support/<app-support>/ClipTown/semantic-minilm-v1.db`
- Linux: `~/.local/share/<app-support>/ClipTown/semantic-minilm-v1.db`
- Windows: `%APPDATA%/<app-support>/ClipTown/semantic-minilm-v1.db`

The exact parent is returned by Flutter's `getApplicationSupportDirectory()`;
do not hardcode it. The cache contains clip IDs, SHA-256 content digests,
384-dimensional Float32 embeddings, and model metadata, but **not raw clip
text**. Vectors can still leak semantic information, so users who require
strong at-rest confidentiality should treat this cache accordingly.

Model weights live next to it in
`ClipTown/models/minilm-l6-v2-q4/all-MiniLM-L6-v2-Q4_K_M.gguf`.

## Model and integrity

`smarttasks/all-MiniLM-L6-v2-GGUF`, Q4_K_M (approximately 21.3 MB) runs with
llama.cpp via `llamadart` in the Flutter desktop process. It produces 384
normalized dimensions. On first use, ClipTown fetches **model weights only**
over HTTPS, limits the download to 32 MiB, verifies their pinned SHA-256, and
atomically installs the verified file. After that it works offline. An offline
first launch or failed model check leaves lexical search available. Failed
model loading can retry on a subsequent search or history modification,
and a successful query can resume an unfinished document backfill;
interrupted downloads are bounded and partial weights are discarded.

The model identity is distinct from the historical `cliptown-fnv1a-v1`
token-hash vector baseline. Old hashed vectors are never mixed with MiniLM.

## Index lifecycle

1. Load and unlock encrypted history as usual.
2. Reconcile clip IDs/content SHA-256 with the derived index (removing stale
   clips, invalidating changed text and retaining unchanged vectors).
3. Backfill missing 384-dimensional embeddings asynchronously, in a
   single worker. The search UI refreshes through index-update notifications.
4. When a clip is edited, re-embed only its text; pinning/reordering does not
   trigger recomputation. On deletion/retention pruning the derived row is
   removed. Erasing the vault erases the SQLite vector index too.
5. Search returns lexical hits plus ranked cosine-based semantic candidates.
   The initial threshold is cosine similarity >= 0.46; validate with real
   retrieval fixtures before changing it.

MiniLM is English-focused and intended for sentences/paragraphs. Longer
clipboard entries are bounded to the first 4096 characters and then reduced
to at most 240 actual model tokens for encoding;
lexical search continues to cover the full content. This initial release uses
a linear exact cosine scan of available vectors; evaluate a native ANN index
once histories become large. The index doesn't store full text, snippets,
or private encryption keys.

## Build/runtime compatibility

The native GGUF dependency currently requires macOS >= 14 and iOS >= 16.4,
which increases ClipTown's existing Apple deployment targets. This is an
explicit **release compatibility change**, not just a dependency bump. The
feature itself is enabled only on Windows, macOS and Linux; mobile still uses
existing history behavior. Verify all desktop and mobile build jobs before
moving this draft PR to ready.

The Flutter project uses a sibling `../cliptown-interfaces` checkout.

## Tests

Run:
```sh
flutter pub get
dart format lib test
flutter analyze --fatal-infos --fatal-warnings
flutter test test/minilm_semantic_clip_repository_test.dart
flutter test test/clip_store_test.dart
```

The deterministic fake-embedder tests prove indexing, persistence, deletion,
cache reuse and search UI refresh **without downloading model weights**.

To also test real neural meaning matches with the native GGUF runtime:
```sh
CLIPTOWN_RUN_MINILM_LIVE_TEST=1 flutter test test/minilm_real_embedding_test.dart -d macos
```

The live test downloads the published verified 21 MB model on first use.

## First-run search status

The desktop search bar now exposes local semantic-index readiness alongside
the existing keyboard shortcut guidance. During first-run setup, it displays
model download percentage (when the server provides a content length), then
incremental indexed/total clip counts. Failed model loads preserve lexical
search and show a retry control. No clipboard text is included in progress
events or sent to the model host.
