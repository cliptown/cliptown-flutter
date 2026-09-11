#!/usr/bin/env bash
set -euo pipefail

export CI="${CI:-1}"
export NO_COLOR="${NO_COLOR:-1}"
export FLUTTER_SUPPRESS_ANALYTICS="${FLUTTER_SUPPRESS_ANALYTICS:-true}"
export DART_SUPPRESS_ANALYTICS="${DART_SUPPRESS_ANALYTICS:-true}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

cache_root="${NIX_AGENT_CACHE_ROOT:-$repo_root/.cache/nix-agent}"
workspace_root="$cache_root/workspace"
flutter_repo="$workspace_root/cliptown-flutter"
interfaces_repo="$workspace_root/cliptown-interfaces"
interfaces_revision="e4e957b5372dc363fe6a52559c8959f0de781efb"
expected_flutter_version="3.44.3"

export PUB_CACHE="${PUB_CACHE:-$cache_root/dart-pub}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$cache_root/gradle}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_root/xdg-cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$cache_root/xdg-config}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-$cache_root/xdg-data}"
mkdir -p \
  "$PUB_CACHE" \
  "$GRADLE_USER_HOME" \
  "$XDG_CACHE_HOME" \
  "$XDG_CONFIG_HOME" \
  "$XDG_DATA_HOME" \
  "$workspace_root"

sync_interfaces() {
  local current_revision=""

  if [[ -d "$interfaces_repo/.git" ]]; then
    current_revision="$(git -C "$interfaces_repo" rev-parse HEAD 2>/dev/null || true)"
  fi
  if [[ "$current_revision" == "$interfaces_revision" && -f "$interfaces_repo/generated/dart/pubspec.yaml" ]]; then
    return
  fi

  rm -rf "$interfaces_repo"
  mkdir -p "$interfaces_repo"
  git -C "$interfaces_repo" init -q
  git -C "$interfaces_repo" remote add origin https://github.com/cliptown/cliptown-interfaces.git
  git -C "$interfaces_repo" fetch --depth=1 origin "$interfaces_revision"
  git -C "$interfaces_repo" checkout --detach -q FETCH_HEAD

  current_revision="$(git -C "$interfaces_repo" rev-parse HEAD)"
  if [[ "$current_revision" != "$interfaces_revision" ]]; then
    printf 'ClipTown interfaces revision mismatch: expected %s, found %s\n' \
      "$interfaces_revision" \
      "$current_revision" >&2
    return 70
  fi
  test -f "$interfaces_repo/generated/dart/pubspec.yaml"
}

sync_flutter_repo() {
  mkdir -p "$flutter_repo"
  rsync -a --delete \
    --exclude '.git/' \
    --exclude '.cache/' \
    --exclude '.dart_tool/' \
    --exclude 'build/' \
    --exclude 'coverage/' \
    "$repo_root/" \
    "$flutter_repo/"
}

prepare_workspace() {
  sync_interfaces
  sync_flutter_repo
}

run_in_workspace() {
  prepare_workspace
  (
    cd "$flutter_repo"
    "$@"
  )
}

run_stage() {
  local stage="$1"
  local actual_flutter_version

  printf '\n==> agent-check stage: %s\n' "$stage"
  case "$stage" in
    preflight)
      git diff --check
      if git grep -nE '^(<<<<<<<|=======|>>>>>>>)' -- .; then
        printf '%s\n' 'unresolved Git conflict marker found' >&2
        return 1
      fi
      nixfmt --check flake.nix .nix/dev-shell.nix
      shellcheck .nix/agent-check.sh
      shfmt -i 2 -ci -d .nix/agent-check.sh
      actionlint \
        .github/workflows/test.yml \
        .github/workflows/nix.yml \
        .github/workflows/formal-methods.yml
      nix flake check --show-trace
      ;;
    workspace)
      prepare_workspace
      printf 'Flutter workspace: %s\ninterfaces revision: %s\n' \
        "$flutter_repo" \
        "$(git -C "$interfaces_repo" rev-parse HEAD)"
      ;;
    version)
      actual_flutter_version="$(flutter --version --machine | jq -r '.frameworkVersion')"
      if [[ "$actual_flutter_version" != "$expected_flutter_version" ]]; then
        printf 'expected Flutter %s from flake.lock, found %s\n' \
          "$expected_flutter_version" \
          "$actual_flutter_version" >&2
        return 1
      fi
      flutter --version
      dart --version
      ;;
    pub)
      run_in_workspace flutter pub get
      ;;
    format)
      run_in_workspace dart format --output=none --set-exit-if-changed \
        lib test integration_test tool
      ;;
    analyze)
      run_in_workspace flutter analyze --fatal-infos --fatal-warnings
      ;;
    test)
      run_in_workspace flutter test --coverage --reporter=expanded
      ;;
    *)
      printf 'unknown agent-check stage: %s\n' "$stage" >&2
      return 64
      ;;
  esac
}

case "${1:-all}" in
  all)
    for stage in preflight workspace version pub format analyze test; do
      run_stage "$stage"
    done
    ;;
  preflight | workspace | version | pub | format | analyze | test)
    run_stage "$1"
    ;;
  *)
    printf 'usage: %s [all|preflight|workspace|version|pub|format|analyze|test]\n' "$0" >&2
    exit 64
    ;;
esac
