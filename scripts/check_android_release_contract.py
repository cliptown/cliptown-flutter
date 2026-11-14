#!/usr/bin/env python3
"""Fail closed when the Android signing/release contract is weakened."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GRADLE = ROOT / "android" / "app" / "build.gradle.kts"
WORKFLOW = ROOT / ".github" / "workflows" / "mobile-release.yml"

PACKAGE_ID = "com.cliptown.cliptown_app"
INTERFACES_REF = "e4e957b5372dc363fe6a52559c8959f0de781efb"
SIGNING_ENV = (
    "CLIPTOWN_ANDROID_KEYSTORE_PATH",
    "CLIPTOWN_ANDROID_KEYSTORE_PASSWORD",
    "CLIPTOWN_ANDROID_KEY_ALIAS",
    "CLIPTOWN_ANDROID_KEY_PASSWORD",
)
WORKFLOW_SECRETS = (
    "CLIPTOWN_ANDROID_KEYSTORE_BASE64",
    "CLIPTOWN_ANDROID_KEYSTORE_PASSWORD",
    "CLIPTOWN_ANDROID_KEY_ALIAS",
    "CLIPTOWN_ANDROID_KEY_PASSWORD",
)


def require(text: str, marker: str, source: Path) -> None:
    if marker not in text:
        raise SystemExit(f"{source.relative_to(ROOT)} is missing required marker: {marker}")


def main() -> None:
    gradle = GRADLE.read_text(encoding="utf-8")
    workflow = WORKFLOW.read_text(encoding="utf-8")

    require(gradle, f'applicationId = "{PACKAGE_ID}"', GRADLE)
    require(gradle, "releaseTaskRequested", GRADLE)
    require(gradle, "providers.environmentVariable(name)", GRADLE)
    require(gradle, "keystoreFile.isFile", GRADLE)
    require(gradle, 'create("release")', GRADLE)
    require(gradle, 'signingConfigs.getByName("release")', GRADLE)
    for name in SIGNING_ENV:
        require(gradle, name, GRADLE)

    if re.search(r'signingConfigs\.getByName\(["\']debug["\']\)', gradle):
        raise SystemExit("release builds must never use the Android debug signing config")

    require(workflow, "workflow_dispatch:", WORKFLOW)
    require(workflow, "permissions:\n  contents: read", WORKFLOW)
    require(workflow, "environment: mobile-release", WORKFLOW)
    require(workflow, "persist-credentials: false", WORKFLOW)
    require(workflow, INTERFACES_REF, WORKFLOW)
    require(workflow, "python3 scripts/prepare_android_release_registrant.py", WORKFLOW)
    require(workflow, "flutter build appbundle --release --no-pub", WORKFLOW)
    require(workflow, "jarsigner -verify", WORKFLOW)
    require(workflow, "git rev-parse HEAD", WORKFLOW)
    require(workflow, "checksums.sha256", WORKFLOW)
    require(workflow, "if-no-files-found: error", WORKFLOW)
    for name in WORKFLOW_SECRETS:
        require(workflow, name, WORKFLOW)

    if "pull_request_target:" in workflow:
        raise SystemExit("the release workflow must not run in pull_request_target context")

    unpinned_actions = re.findall(
        r"^\s*-?\s*uses:\s+[^\s@]+@(?![0-9a-f]{40}(?:\s|$))([^\s#]+)",
        workflow,
        re.MULTILINE,
    )
    if unpinned_actions:
        raise SystemExit(
            f"release workflow actions must be pinned to full commits: {unpinned_actions}"
        )

    print(f"Android release contract is fail-closed for {PACKAGE_ID}.")


if __name__ == "__main__":
    main()
