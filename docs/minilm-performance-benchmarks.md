# Local MiniLM vector-index performance checks

ClipTown's vector cache is an unencrypted, disposable SQLite index separate
from the encrypted clipboard history. The index uses 384-dimensional Float32
vectors and exact cosine top-K search.

## Reproducible measurements

Run with Flutter's pinned dependencies resolved and the sibling
`cliptown-interfaces` checkout available:

```sh
flutter pub get
dart run tool/benchmarks/minilm_vector_benchmark.dart --output=build/benchmarks/minilm.json
```

The command creates temporary **10,000- and 100,000-vector** SQLite indexes.
It records bulk SQLite insert duration, 5 paginated exact-search samples
(p50 and worst-observed sample labelled p95), process RSS, and the derived
SQLite file size. It checks that every query returns precisely 20 ranked
results and cleans up its temporary files.

`MiniLM vector-search benchmark` CI runs this workload when the script or
benchmark workflow changes, and provides the JSON as an Actions artifact.

**Scope:** Synthetic, repeatable local index benchmark only. Times do not
include MiniLM model download, native model initialization, embedding a
document, or end-to-end UI rendering. The ingestion measurement is a bulk
transaction with precomputed vectors, not end-to-end text indexing. Benchmarks
on hosted CI runners are exploratory, not production SLO guarantees.

Track separately on installed Windows, macOS, and Linux desktops:
first-launch model download, 10k/100k native embedding backfill throughput,
query p50/p95 under actual UI load, memory/CPU utilization and cold-start
time. Use the existing opt-in real GGUF test to validate semantic relevance.

If p95 exact search becomes too slow, evaluate an approximate index such as
HNSW while retaining an exact-retrieval correctness baseline.
