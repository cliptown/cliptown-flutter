#!/usr/bin/env bash
# Builds an ad-hoc signed ClipTown.app release (no Apple Developer account).
#
# Used by scripts/install-macos.sh --from-source and the macOS release
# workflow. Release.entitlements is swapped for AdHoc.entitlements only for the
# duration of the build and is always restored. Prints the .app path last.
#
#   scripts/build-macos-adhoc.sh [extra flutter build args...]

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
entitlements="$root/macos/Runner/Release.entitlements"
backup="$(mktemp "${TMPDIR:-/tmp}/cliptown-release-entitlements.XXXXXX")"

cp "$entitlements" "$backup"
restore() { cp "$backup" "$entitlements"; rm -f "$backup"; }
trap restore EXIT
cp "$root/macos/Runner/AdHoc.entitlements" "$entitlements"

cd "$root"
flutter build macos --release \
  --dart-define=CLIPTOWN_MACOS_DATA_PROTECTION_KEYCHAIN=false \
  "$@" >&2

app="$root/build/macos/Build/Products/Release/cliptown_app.app"
[ -d "$app" ] || { echo "error: $app was not produced" >&2; exit 1; }
codesign --verify --deep --strict "$app" >&2
echo "$app"
