# Incremental encrypted history persistence

ClipTown's authoritative clipboard history stays in the existing SQLite3MultipleCiphers
(SQLCipher) database, keyed from platform secure storage. This change does not
migrate, recreate, downgrade, or decrypt the database onto the filesystem.

## Write path

`ClipRepository.save(List<ClipItem>)` remains a **complete, authoritative**
history replacement at the API boundary. `SqliteClipRepository` builds a
row-level delta from the last successfully committed snapshot:

- Identical or equivalent immutable clips: no UPDATE and no embedding write
- Newly captured clips: INSERT one clip row and an optional legacy vector
- Pinned, renamed, reordered, retagged or moved clips: UPDATE only their row
- Changed text: UPDATE the row, then replace that clip's legacy vector
- Removed clips: DELETE their row; the foreign-key cascade deletes the vector
- Desktop's MiniLM mode: do not retain obsolete token-hash vector rows

All changes are applied under `BEGIN IMMEDIATE` with existing `synchronous=FULL`
and verified encryption settings. Failed statements roll back the transaction.
The in-memory snapshot is replaced **only after COMMIT**. A failure invalidates
it so the next attempt reads authoritative encrypted rows rather than trusting
partially applied changes. `PRAGMA data_version` detects changes written by
other SQLite connections and forces a snapshot rebuild.

An immutable ClipItem identity is a constant-time unchanged fast path;
separately constructed records are compared field-by-field. This avoids
re-encoding clipboard text and binary payloads for every unchanged record,
although calculating the delta still loops through the full input list.

## Scope and limitations

- This does **not** make `ClipStore._commit` itself O(1): it still constructs
  an authoritative list, and the repository still performs an O(N) delta
  comparison for every save. It avoids O(N) row rewrites and embedding rebuilds.
- When the history is first opened in a new process or has changed externally,
  one full encrypted read is needed to establish the snapshot.
- For very large histories, a future typed `apply_changes` repository method
  can eliminate even the in-memory O(N) planning cost without weakening the
  full-list compatibility contract.
- The separate disposable desktop MiniLM cache remains unencrypted and keeps
  its existing documented privacy limitations. The authoritative history is
  always encrypted.

## Tests and benchmarks

Normal regression suite:

```sh
flutter test test/sqlite_clip_repository_test.dart \
  test/incremental_sqlite_clip_repository_test.dart \
  test/minilm_semantic_clip_repository_test.dart \
  test/clip_store_test.dart
```

Opt-in encrypted end-to-end persistence benchmarks:

```sh
flutter test --dart-define=CLIPTOWN_RUN_SQLITE_BENCH=true \
  test/performance/sqlite_clip_persistence_benchmark_test.dart --reporter=expanded
```

The benchmark reports initial 1k/10k/50k/100k seed latency, and p50/p95 for
single-row pin operations and unchanged saves, including `save(List<ClipItem>)`
planning overhead. Results depend on the machine and encrypted SQLite runtime.
Run on representative release hardware before declaring a user-visible speedup.
