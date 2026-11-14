#!/usr/bin/env bash
# ClipTown macOS installer — installs ClipTown.app straight from GitHub.
#
#   curl -fsSL https://raw.githubusercontent.com/cliptown/cliptown-flutter/main/scripts/install-macos.sh | bash
#
# By default it downloads the latest GitHub Release build (ClipTown-macos.zip),
# verifies its SHA-256 checksum and bundle identity, and installs it. With
# --from-source it clones the public cliptown-flutter and cliptown-interfaces
# repositories and builds the app locally (needs Xcode, CocoaPods and Flutter).
# When no release has been published yet and Flutter is available, it builds
# from source automatically.
#
# ClipTown needs no account, login, or network service to run: history is
# encrypted locally and cloud sync is optional.
#
# Everything runs inside main(), invoked on the last line, so a truncated
# download (curl | bash) cannot execute a partial script.

set -euo pipefail

readonly ORG="cliptown"
readonly APP_REPO="cliptown-flutter"
readonly INTERFACES_REPO="cliptown-interfaces"
readonly APP_NAME="ClipTown.app"
readonly ASSET="ClipTown-macos.zip"
readonly BUNDLE_ID="com.cliptown.cliptownApp"
readonly EXECUTABLE="cliptown_app"

say() { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage: install-macos.sh [--from-source [--ref <ref>]] [--version <tag>] [--dest <dir>] [--no-launch]

  (default)        download the latest GitHub Release, verify SHA-256, install
  --from-source    clone github.com/cliptown/cliptown-flutter and build locally
  --ref <ref>      branch/tag/commit for --from-source (default: main)
  --version <tag>  install a specific release tag
  --dest <dir>     install directory (default: /Applications, else ~/Applications)
  --no-launch      do not open ClipTown afterwards
  --open-at-login  also start ClipTown automatically when you log in (macOS 13+)
EOF
}

# Branch, tag or commit names only: no option-looking or path-escaping values
# reach git or the release URL.
valid_ref() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$ ]] && [[ "$1" != *..* ]]
}

bundle_id_of() {
  /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

download_release() {
  local base expected actual
  if [ -n "$version" ]; then
    base="https://github.com/$ORG/$APP_REPO/releases/download/$version"
  else
    base="https://github.com/$ORG/$APP_REPO/releases/latest/download"
  fi
  say "Downloading $ASSET from github.com/$ORG/$APP_REPO releases"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$work/$ASSET" "$base/$ASSET" || return 1
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$work/$ASSET.sha256" "$base/$ASSET.sha256" ||
    die "release has no $ASSET.sha256 checksum; refusing to install an unverified build"
  expected="$(awk 'NR == 1 {print $1}' "$work/$ASSET.sha256")"
  actual="$(shasum -a 256 "$work/$ASSET" | awk '{print $1}')"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "malformed checksum file for $ASSET"
  [ "$expected" = "$actual" ] || die "checksum mismatch for $ASSET (expected $expected, got $actual)"
  say "Checksum verified ($actual)"
  ditto -x -k "$work/$ASSET" "$work/unpacked" || die "could not unpack $ASSET"
  app_path="$(find "$work/unpacked" -maxdepth 2 -name '*.app' -type d -print -quit)"
  [ -n "$app_path" ] || die "release archive does not contain an .app bundle"
}

build_from_source() {
  have git || die "git is required (xcode-select --install)"
  have flutter || die "Flutter is required for --from-source: https://docs.flutter.dev/get-started/install/macos"
  have xcodebuild || die "Xcode is required for --from-source"
  have pod || die "CocoaPods is required for --from-source (brew install cocoapods)"

  local src="$work/src" interfaces_ref
  mkdir -p "$src"
  say "Cloning $ORG/$APP_REPO@$ref"
  git clone --quiet --filter=blob:none "https://github.com/$ORG/$APP_REPO.git" "$src/$APP_REPO"
  git -C "$src/$APP_REPO" -c advice.detachedHead=false checkout --quiet "$ref" -- ||
    die "unknown ref: $ref"

  # The app's CI pins the interfaces revision it was tested against.
  interfaces_ref="$(sed -n 's/^ *CLIPTOWN_INTERFACES_REF: *\([0-9a-f]\{40\}\).*/\1/p' \
    "$src/$APP_REPO/.github/workflows/test.yml" | awk 'NR == 1')"
  [ -n "$interfaces_ref" ] || die "could not find the pinned $INTERFACES_REPO revision"
  say "Cloning $ORG/$INTERFACES_REPO@${interfaces_ref:0:12}"
  git clone --quiet --filter=blob:none "https://github.com/$ORG/$INTERFACES_REPO.git" "$src/$INTERFACES_REPO"
  git -C "$src/$INTERFACES_REPO" -c advice.detachedHead=false checkout --quiet "$interfaces_ref" --

  say "Building ClipTown (release) — this takes a few minutes"
  (
    cd "$src/$APP_REPO"
    flutter config --enable-macos-desktop >/dev/null
    flutter pub get >/dev/null
  )
  # Ad-hoc signing: AdHoc.entitlements + login Keychain (see that script).
  app_path="$(bash "$src/$APP_REPO/scripts/build-macos-adhoc.sh" | awk 'END {print}')"
  [ -d "$app_path" ] || die "build finished but no .app bundle was produced"
}

quit_running_copy() {
  pgrep -x "$EXECUTABLE" >/dev/null 2>&1 || return 0
  say "Quitting the running ClipTown"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local waited=0
  while pgrep -x "$EXECUTABLE" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  # Only force-quit the copy being replaced, never a build running elsewhere.
  pkill -f "$target/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1 || true
}

main() {
  from_source=0
  ref="main"
  version=""
  dest=""
  launch=1
  open_at_login=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from-source) from_source=1 ;;
      --ref) [ $# -ge 2 ] || die "--ref needs a value"; ref="$2"; shift ;;
      --version) [ $# -ge 2 ] || die "--version needs a value"; version="$2"; shift ;;
      --dest) [ $# -ge 2 ] || die "--dest needs a value"; dest="$2"; shift ;;
      --no-launch) launch=0 ;;
      --open-at-login) open_at_login=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
    shift
  done

  valid_ref "$ref" || die "invalid --ref: $ref"
  [ -z "$version" ] || valid_ref "$version" || die "invalid --version: $version"
  [ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS"
  [ "$(id -u)" -ne 0 ] || die "run without sudo; ClipTown installs per user and needs your login Keychain"
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "${major:-0}" -ge 11 ] || die "ClipTown needs macOS 11 or later"

  work="$(mktemp -d "${TMPDIR:-/tmp}/cliptown-install.XXXXXX")"
  trap 'rm -rf "$work"' EXIT

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

  [ "$(bundle_id_of "$app_path")" = "$BUNDLE_ID" ] ||
    die "refusing to install: the bundle is not $BUNDLE_ID"

  if [ -z "$dest" ]; then
    # Upgrade an existing install in place rather than creating a second copy.
    if [ "$(bundle_id_of "$HOME/Applications/$APP_NAME")" = "$BUNDLE_ID" ]; then
      dest="$HOME/Applications"
    elif [ -w /Applications ]; then
      dest="/Applications"
    else
      dest="$HOME/Applications"
    fi
  fi
  mkdir -p "$dest"
  target="$dest/$APP_NAME"
  if [ -e "$target" ] && [ "$(bundle_id_of "$target")" != "$BUNDLE_ID" ]; then
    die "$target exists and is not ClipTown; move it away first"
  fi

  quit_running_copy

  # Stage next to the target, then swap, so a failed copy never leaves the
  # user without a working app.
  local staging="$dest/.ClipTown.app.installing" previous="$dest/.ClipTown.app.previous"
  rm -rf "$staging" "$previous"
  say "Installing to $target"
  ditto "$app_path" "$staging" || die "could not copy ClipTown into $dest"
  # Downloaded with curl, so no quarantine is expected; clear any that a proxy
  # or browser-assisted download may have added.
  xattr -dr com.apple.quarantine "$staging" 2>/dev/null || true
  if ! codesign --verify --deep --strict "$staging" >/dev/null 2>&1; then
    rm -rf "$staging"
    die "the app signature did not verify; not installing"
  fi
  if [ -e "$target" ]; then mv "$target" "$previous"; fi
  if ! mv "$staging" "$target"; then
    [ -e "$previous" ] && mv "$previous" "$target"
    die "could not move ClipTown into place; the previous version was kept"
  fi
  rm -rf "$previous"

  say "ClipTown installed."
  echo "    Open it any time with Option+C. It lives in the menu bar; Option+X hides it."
  if [ "$open_at_login" -eq 1 ]; then
    # SMAppService can only register the app that calls it, so ClipTown
    # registers itself on this launch.
    open "$target" --args --enable-open-at-login
    echo "    ClipTown will start automatically when you log in (System Settings > General > Login Items)."
  else
    echo "    Turn on 'Open ClipTown at login' in its Privacy and capture settings."
    if [ "$launch" -eq 1 ]; then open "$target"; fi
  fi
}

main "$@"
