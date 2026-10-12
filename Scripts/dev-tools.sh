#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/.cache/dev-tools"
BIN_DIR="$TOOLS_DIR/bin"
DOWNLOAD_DIR="$TOOLS_DIR/downloads"
FRAMEWORK_DIR="$ROOT_DIR/Frameworks/GhosttyKit.xcframework"
WORK_DIR=""
ERRORS=0
source "$ROOT_DIR/Scripts/dev-tools.env"

fail() {
  echo "dev-tools: $*" >&2
  exit 1
}

problem() {
  echo "error: $*" >&2
  ERRORS=$((ERRORS + 1))
}

cleanup() {
  if [ -n "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

check_prerequisites() {
  local version major minor xcode_version
  if [ "$(uname -s)" != Darwin ]; then
    problem "macOS 26 or newer is required."
    return
  fi
  [ "$(uname -m)" = arm64 ] || problem "Use a native Apple Silicon terminal, without Rosetta."
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  if [ "$major" -lt 26 ]; then
    problem "macOS 26 or newer is required; found $version."
  else
    echo "macOS: $version ($(uname -m))"
  fi

  if xcode_version="$(xcodebuild -version 2>/dev/null)"; then
    echo "$xcode_version"
    version="$(printf '%s\n' "$xcode_version" | awk '/^Xcode / { print $2 }')"
    major="${version%%.*}"
    [ "$major" -ge 27 ] || problem "Select Xcode 27 or newer; Xcode 26 does not include Swift 6.4."
  else
    problem "Install and select Xcode 27 with Swift 6.4; Command Line Tools alone are insufficient."
  fi

  if version="$(swift --version 2>/dev/null)"; then
    echo "$version"
    version="$(printf '%s\n' "$version" | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -n 1)"
    IFS=. read -r major minor _ <<< "$version"
    if [ "${major:-0}" -lt 6 ] || { [ "${major:-0}" -eq 6 ] && [ "${minor:-0}" -lt 4 ]; }; then
      problem "Swift 6.4 or newer is required; select the Xcode 27 toolchain."
    fi
  else
    problem "Swift is unavailable; install and select Xcode 27."
  fi

  if version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
    echo "macOS SDK: $version"
    major="${version%%.*}"
    [ "$major" -ge 26 ] || problem "The selected macOS SDK must be version 26 or newer."
  else
    problem "The selected Xcode has no usable macOS SDK."
  fi

  if version="$(python3 --version 2>/dev/null)"; then
    echo "$version"
  else
    problem "Python 3 is required for Dev install path checks and tooling tests."
  fi
}

tool_version() {
  case "$1" in
    swiftformat) "$2" --version ;;
    swiftlint) "$2" version ;;
  esac
}

check_tool() {
  local tool="$1" expected="$2" actual
  if actual="$(tool_version "$tool" "$BIN_DIR/$tool" 2>/dev/null)" && [ "$actual" = "$expected" ]; then
    echo "$tool: $actual ($BIN_DIR/$tool)"
  else
    problem "$tool $expected is missing from $BIN_DIR; run make setup."
  fi
}

verify_framework() {
  [ -f "$FRAMEWORK_DIR/Info.plist" ] && "$ROOT_DIR/Scripts/ghostty-preflight.sh" verify
}

check_framework() {
  if verify_framework; then
    echo "GhosttyKit: verified ($FRAMEWORK_DIR)"
  elif [ -e "$FRAMEWORK_DIR" ] || [ -L "$FRAMEWORK_DIR" ]; then
    problem "Existing GhosttyKit does not match this checkout. It was preserved; move it aside explicitly before make setup."
  else
    problem "GhosttyKit is missing; run make setup."
  fi
}

check_signing() {
  local identity="${OMNIWM_SIGNING_IDENTITY:-OmniWM Dev}"
  if security find-identity -v -p codesigning 2>/dev/null | awk -v identity="$identity" '$2 == identity || index($0, "\"" identity "\"") { found = 1 } END { exit !found }'; then
    echo "Development signing identity: $identity"
  else
    echo "warning: No code-signing identity named \"$identity\". Dev will use ad-hoc signing; the optional local certificate helps retain permissions across rebuilds." >&2
  fi
}

print_paths() {
  local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
  local state_base="${XDG_STATE_HOME:-$HOME/.local/state}"
  local dev_app="${OMNIWM_DEV_INSTALL_DIR:-$HOME/Applications}/${OMNIWM_DEV_APP_NAME:-OmniWM Dev}.app"
  local release_app="${OMNIWM_RELEASE_APP:-/Applications/OmniWM.app}" app
  case "$config_base" in /*) ;; *) config_base="$HOME/.config" ;; esac
  case "$state_base" in /*) ;; *) state_base="$HOME/.local/state" ;; esac
  echo "Development tools: $BIN_DIR"
  echo "Release settings: $config_base/omniwm/settings.toml"
  echo "Dev settings: $config_base/omniwm-dev/settings.toml"
  echo "Dev state: $state_base/omniwm-dev"
  for app in "$dev_app" "$release_app"; do
    if [ -d "$app" ]; then
      echo "Installed app: $app"
    else
      echo "App not installed: $app"
    fi
  done
}

has_digest() {
  [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]
}

download() {
  local url="$1" digest="$2" destination="$DOWNLOAD_DIR/$2.zip"
  if ! has_digest "$destination" "$digest"; then
    echo "Downloading $url" >&2
    curl --fail --location --silent --show-error --connect-timeout 15 --max-time 600 \
      "$url" --output "$WORK_DIR/download.zip" || fail "Download failed: $url"
    has_digest "$WORK_DIR/download.zip" "$digest" || fail "Downloaded archive checksum mismatch: $url"
    mv -f "$WORK_DIR/download.zip" "$destination"
  fi
  printf '%s\n' "$destination"
}

install_tool() {
  local tool="$1" expected="$2" url="$3" digest="$4" archive actual
  if actual="$(tool_version "$tool" "$BIN_DIR/$tool" 2>/dev/null)" && [ "$actual" = "$expected" ]; then
    return
  fi
  archive="$(download "$url" "$digest")"
  mkdir -p "$WORK_DIR/$tool"
  ditto -x -k "$archive" "$WORK_DIR/$tool"
  [ -f "$WORK_DIR/$tool/$tool" ] || fail "$tool archive did not contain the expected executable."
  chmod 755 "$WORK_DIR/$tool/$tool"
  actual="$(tool_version "$tool" "$WORK_DIR/$tool/$tool")"
  [ "$actual" = "$expected" ] || fail "$tool archive reports $actual; expected $expected."
  mv -f "$WORK_DIR/$tool/$tool" "$BIN_DIR/$tool"
}

install_framework() {
  local archive staging="$WORK_DIR/ghostty"
  if [ -e "$FRAMEWORK_DIR" ] || [ -L "$FRAMEWORK_DIR" ]; then
    verify_framework || fail "Existing GhosttyKit does not match this checkout; it was preserved. Move it aside explicitly before make setup."
    return
  fi
  archive="$(download "$OMNIWM_GHOSTTY_DOWNLOAD_URL" "$OMNIWM_GHOSTTY_ZIP_SHA256")"
  mkdir -p "$staging/Frameworks" "$staging/Scripts"
  ditto -x -k "$archive" "$staging/Frameworks"
  [ -f "$staging/Frameworks/GhosttyKit.xcframework/Info.plist" ] || fail "GhosttyKit download did not contain the complete xcframework."
  cp "$ROOT_DIR/Scripts/ghostty-preflight.sh" "$ROOT_DIR/Scripts/build-metadata.env" "$staging/Scripts/"
  "$staging/Scripts/ghostty-preflight.sh" verify
  mkdir -p "$ROOT_DIR/Frameworks"
  mv -n "$staging/Frameworks/GhosttyKit.xcframework" "$ROOT_DIR/Frameworks/"
  verify_framework || fail "GhosttyKit verification failed; any existing framework was preserved."
}

case "${1:-doctor}" in
  setup|setup-tools)
    check_prerequisites
    [ "$ERRORS" -eq 0 ] || exit 1
    mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"
    WORK_DIR="$(mktemp -d "$TOOLS_DIR/setup.XXXXXX")"
    trap cleanup EXIT
    if [ "$1" = setup ]; then
      install_framework
    fi
    install_tool swiftformat "$SWIFTFORMAT_VERSION" "https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/swiftformat.zip" "$OMNIWM_SWIFTFORMAT_ZIP_SHA256"
    install_tool swiftlint "$SWIFTLINT_VERSION" "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" "$OMNIWM_SWIFTLINT_ZIP_SHA256"
    check_tool swiftformat "$SWIFTFORMAT_VERSION"
    check_tool swiftlint "$SWIFTLINT_VERSION"
    check_signing
    print_paths
    [ "$ERRORS" -eq 0 ]
    ;;
  doctor)
    check_prerequisites
    check_framework
    check_tool swiftformat "$SWIFTFORMAT_VERSION"
    check_tool swiftlint "$SWIFTLINT_VERSION"
    check_signing
    print_paths
    [ "$ERRORS" -eq 0 ]
    ;;
  *)
    echo "Usage: Scripts/dev-tools.sh [setup|setup-tools|doctor]" >&2
    exit 64
    ;;
esac
