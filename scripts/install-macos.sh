#!/usr/bin/env bash
# ClipTown macOS installer — installs ClipTown.app straight from GitHub.
#
#   curl -fsSL https://raw.githubusercontent.com/cliptown/cliptown-flutter/main/scripts/install-macos.sh | bash
#
# By default it downloads the latest GitHub Release build (ClipTown-macos.zip),
# verifies its SHA-256 checksum, and installs it. With --from-source it clones
# the public cliptown-flutter and cliptown-interfaces repositories and builds
# the app locally (needs Xcode, CocoaPods and Flutter). When no release has been
# published yet and Flutter is available, it builds from source automatically.
#
# Options:
#   --from-source       build from the GitHub source instead of a release
#   --ref <ref>         cliptown-flutter branch/tag/commit for --from-source (default: main)
#   --version <tag>     install a specific release tag instead of the latest
#   --dest <dir>        install directory (default: /Applications, else ~/Applications)
#   --no-launch         do not open ClipTown after installing
#   -h, --help          show this help
#
# ClipTown needs no account, login, or network service to run: history is
# encrypted locally and cloud sync is optional.

set -euo pipefail

readonly ORG="cliptown"
readonly APP_REPO="cliptown-flutter"
readonly INTERFACES_REPO="cliptown-interfaces"
readonly APP_NAME="ClipTown.app"
readonly ASSET="ClipTown-macos.zip"
readonly BUNDLE_ID="com.cliptown.cliptownApp"

from_source=0
ref="main"
version=""
dest=""
launch=1

say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
Usage: install-macos.sh [--from-source [--ref <ref>]] [--version <tag>] [--dest <dir>] [--no-launch]

  (default)        download the latest GitHub Release, verify SHA-256, install
  --from-source    clone github.com/cliptown/cliptown-flutter and build locally
  --ref <ref>      branch/tag/commit for --from-source (default: main)
  --version <tag>  install a specific release tag
  --dest <dir>     install directory (default: /Applications, else ~/Applications)
  --no-launch      do not open ClipTown afterwards
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-source) from_source=1 ;;
    --ref) [ $# -ge 2 ] || die "--ref needs a value"; ref="$2"; shift ;;
    --version) [ $# -ge 2 ] || die "--version needs a value"; version="$2"; shift ;;
    --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest="$2"; shift ;;
    --no-launch) launch=0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "${major:-0}" -ge 11 ] || die "ClipTown needs macOS 11 or later"

work="$(mktemp -d "${TMPDIR:-/tmp}/cliptown-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

download_release() {
  local base
  if [ -n "$version" ]; then
    base="https://github.com/$ORG/$APP_REPO/releases/download/$version"
  else
    base="https://github.com/$ORG/$APP_REPO/releases/latest/download"
  fi
  say "Downloading $ASSET from github.com/$ORG/$APP_REPO releases"
  curl -fsSL --retry 3 -o "$work/$ASSET" "$base/$ASSET" || return 1
  curl -fsSL --retry 3 -o "$work/$ASSET.sha256" "$base/$ASSET.sha256" ||
    die "release has no $ASSET.sha256 checksum; refusing to install an unverified build"
  local expected actual
  expected="$(awk '{print $1}' "$work/$ASSET.sha256")"
  actual="$(shasum -a 256 "$work/$ASSET" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
    die "checksum mismatch for $ASSET (expected $expected, got $actual)"
  say "Checksum verified ($actual)"
  ditto -x -k "$work/$ASSET" "$work/unpacked"
  app_path="$(find "$work/unpacked" -maxdepth 2 -name '*.app' -type d | head -n 1)"
  [ -n "$app_path" ] || die "release archive does not contain an .app bundle"
}

build_from_source() {
  have git || die "git is required (xcode-select --install)"
  have flutter || die "Flutter is required for --from-source: https://docs.flutter.dev/get-started/install/macos"
  have xcodebuild || die "Xcode is required for --from-source"
  have pod || die "CocoaPods is required for --from-source (brew install cocoapods)"

  local src="$work/src"
  mkdir -p "$src"
  say "Cloning $ORG/$APP_REPO@$ref"
  git clone --quiet --filter=blob:none "https://github.com/$ORG/$APP_REPO.git" "$src/$APP_REPO"
  git -C "$src/$APP_REPO" checkout --quiet "$ref"

  # The app's CI pins the interfaces revision it was tested against.
  local interfaces_ref
  interfaces_ref="$(sed -n 's/^ *CLIPTOWN_INTERFACES_REF: *\([0-9a-f]\{40\}\).*/\1/p' \
    "$src/$APP_REPO/.github/workflows/test.yml" | head -n 1)"
  [ -n "$interfaces_ref" ] || die "could not find the pinned $INTERFACES_REPO revision"
  say "Cloning $ORG/$INTERFACES_REPO@${interfaces_ref:0:12}"
  git clone --quiet --filter=blob:none "https://github.com/$ORG/$INTERFACES_REPO.git" "$src/$INTERFACES_REPO"
  git -C "$src/$INTERFACES_REPO" checkout --quiet "$interfaces_ref"

  say "Building ClipTown (release) — this takes a few minutes"
  (
    cd "$src/$APP_REPO"
    flutter config --enable-macos-desktop >/dev/null
    flutter pub get >/dev/null
  )
  # Ad-hoc signing: AdHoc.entitlements + login Keychain (see that script).
  app_path="$(bash "$src/$APP_REPO/scripts/build-macos-adhoc.sh" | tail -n 1)"
  [ -d "$app_path" ] || die "build finished but no .app bundle was produced"
}

app_path=""
if [ "$from_source" -eq 1 ]; then
  build_from_source
elif ! download_release; then
  if have flutter; then
    warn "no published release found; building from source instead"
    build_from_source
  else
    die "no published release found. Install Flutter and re-run with --from-source, or wait for a release at https://github.com/$ORG/$APP_REPO/releases"
  fi
fi

if [ -z "$dest" ]; then
  if [ -w /Applications ]; then dest="/Applications"; else dest="$HOME/Applications"; fi
fi
mkdir -p "$dest"
target="$dest/$APP_NAME"

if pgrep -f "$APP_NAME/Contents/MacOS/" >/dev/null 2>&1 ||
  pgrep -x cliptown_app >/dev/null 2>&1; then
  say "Quitting the running ClipTown"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  sleep 2
  pkill -x cliptown_app >/dev/null 2>&1 || true
fi

say "Installing to $target"
if [ -e "$target" ]; then rm -rf "$target"; fi
ditto "$app_path" "$target"
# Downloaded with curl, so no quarantine is expected; clear any that a proxy
# or browser-assisted download may have added.
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
  warn "the app signature did not verify; macOS may refuse to open it"
fi

say "ClipTown installed."
echo "    Open it any time with Option+C. It lives in the menu bar; Option+X hides it."
echo "    Turn on 'Open ClipTown at login' in its Privacy and capture settings."
if [ "$launch" -eq 1 ]; then open "$target"; fi
