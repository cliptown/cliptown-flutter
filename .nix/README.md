# Agent-first Nix contract

Canonical entrypoints:

```sh
nix develop
nix develop -c agent-check
nix run .#agent-check
```

The staged command supports `preflight`, `workspace`, `version`, `pub`, `format`, `analyze`, and `test`.

The application depends on `../cliptown-interfaces/generated/dart`. The agent contract validates a repository-local workspace and pins `cliptown/cliptown-interfaces` to commit `e4e957b5372dc363fe6a52559c8959f0de781efb`. It does not mutate a developer's sibling checkout or silently follow a moving `main` branch.

Flutter/Dart Pub, Gradle, XDG, generated build output, coverage, and sibling-workspace state remain under `.cache/nix-agent`. Analytics are suppressed without writing global user configuration. The shell does not select cloud identities, load secrets, or prompt.

## Platform and OCI boundary

The Android, iOS, macOS, Windows, and Linux applications are not OCI runtime workloads. Nix covers reproducible development, analysis, tests, and desktop prerequisites. A future web-serving image belongs in a dedicated server or deployment repository and must independently prove non-root execution, asset integrity, compression/cache behavior, health/entrypoint behavior, layers, SBOM/provenance, signing, vulnerability results, and deployment compatibility.
