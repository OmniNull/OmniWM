#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${OMNIWM_DEV_TOOLS:-$ROOT_DIR/.cache/flake-tools}/bin"
if [[ "$BIN_DIR" != /* ]]; then
  BIN_DIR="$ROOT_DIR/$BIN_DIR"
fi
FRAMEWORK_DIR="$ROOT_DIR/Frameworks/GhosttyKit.xcframework"
ERRORS=0
source "$ROOT_DIR/Scripts/dev-tools.env"

problem() {
  echo "error: $*" >&2
  ERRORS=$((ERRORS + 1))
}

check_prerequisites() {
  local version major minor xcode_version
  if [ "$(uname -s)" != Darwin ]; then
    problem "Building OmniWM requires macOS 27 or newer."
    return
  fi
  [ "$(uname -m)" = arm64 ] || problem "Use a native Apple Silicon terminal, without Rosetta."
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  if [ "$major" -lt 27 ]; then
    problem "Building OmniWM requires macOS 27 or newer; found $version."
  else
    echo "macOS: $version ($(uname -m))"
  fi

  if xcode_version="$(xcodebuild -version 2>/dev/null)"; then
    echo "$xcode_version"
    version="$(printf '%s\n' "$xcode_version" | awk '/^Xcode / { print $2 }')"
    major="${version%%.*}"
    [ "$major" -ge 27 ] || problem "Select Xcode 27 or newer for the macOS 27 SDK."
  else
    problem "Install and select Xcode 27 for the macOS 27 SDK; Command Line Tools alone are insufficient."
  fi

  if version="$(swift --version 2>/dev/null)"; then
    echo "$version"
    version="$(printf '%s\n' "$version" | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -n 1)"
    IFS=. read -r major minor _ <<< "$version"
    if [ "${major:-0}" -lt 6 ] || { [ "${major:-0}" -eq 6 ] && [ "${minor:-0}" -lt 5 ]; }; then
      problem "Swift 6.5 or newer is required; install the toolchain pinned in .swift-version with swiftly."
    fi
  else
    problem "Swift is unavailable; install the toolchain pinned in .swift-version with swiftly."
  fi

  if version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null)"; then
    echo "macOS SDK: $version"
    major="${version%%.*}"
    [ "$major" -ge 27 ] || problem "The selected macOS SDK must be version 27 or newer."
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
    problem "Existing GhosttyKit does not match this checkout. It was preserved; move it aside before make setup."
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

check_nix() {
  if version="$(nix --version 2>/dev/null)"; then
    echo "$version"
  else
    problem "Nix is unavailable; install Lix from https://lix.systems/install/ and run make setup."
  fi
}

case "${1:-doctor}" in
  doctor)
    check_nix
    check_prerequisites
    check_framework
    check_tool swiftformat "$SWIFTFORMAT_VERSION"
    check_tool swiftlint "$SWIFTLINT_VERSION"
    check_signing
    print_paths
    [ "$ERRORS" -eq 0 ]
    ;;
  *)
    echo "Usage: Scripts/doctor.sh [doctor]" >&2
    exit 64
    ;;
esac
