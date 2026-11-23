#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_APP_NAME="${OMNIWM_DEV_APP_NAME:-OmniWM Dev}"
DEV_BUNDLE_ID="com.barut.OmniWM.dev"
DEV_IDENTITY="${OMNIWM_SIGNING_IDENTITY:-OmniWM Dev}"
INSTALL_DIR="${OMNIWM_DEV_INSTALL_DIR:-$HOME/Applications}"
RELEASE_APP="${OMNIWM_RELEASE_APP:-/Applications/OmniWM.app}"
RELEASE_BUNDLE_ID="com.barut.OmniWM"
DEV_APP="$INSTALL_DIR/$DEV_APP_NAME.app"

fail() {
  echo "omniwm-dev: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 install | use dev | use release" >&2
  exit 64
}

validate_destination() {
  case "$DEV_APP_NAME" in
    ''|.|..|*/*) fail "the development app name must be a single directory name" ;;
  esac
  case "$INSTALL_DIR" in
    /*) ;;
    *) fail "OMNIWM_DEV_INSTALL_DIR must be an absolute path" ;;
  esac
  python3 - "$DEV_APP" "$RELEASE_APP" <<'PYTHON'
import os
import sys

dev, release = map(os.path.realpath, sys.argv[1:])
if os.path.commonpath([dev, release]) in (dev, release):
    sys.exit("omniwm-dev: development and release installation paths must not overlap")
PYTHON
}

quit_other_copies() {
  osascript -l JavaScript - "${1:-}" "$RELEASE_BUNDLE_ID" "$DEV_BUNDLE_ID" <<'JAVASCRIPT'
ObjC.import("AppKit");
function run(args) {
    const keepPath = ObjC.unwrap($(args[0]).stringByStandardizingPath.stringByResolvingSymlinksInPath);
    let keptPID = 0;
    for (const identifier of args.slice(1)) {
        const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(identifier);
        for (let index = 0; index < apps.count; index++) {
            const app = apps.objectAtIndex(index);
            const appPath = ObjC.unwrap(app.bundleURL.path.stringByResolvingSymlinksInPath);
            if (args[0] && appPath === keepPath) {
                keptPID = app.processIdentifier;
            } else if (!app.terminate) {
                throw new Error("Could not quit " + identifier + "; quit it manually and try again.");
            }
        }
    }
    return keptPID;
}
JAVASCRIPT
}

wait_for_no_other_omniwm() {
  local keep_pid="${1:-0}" pids status attempt
  for ((attempt = 0; attempt < 40; attempt++)); do
    if pids="$(pgrep -x OmniWM)"; then
      [ "$pids" = "$keep_pid" ] && return 0
    else
      status=$?
      [ "$status" -eq 1 ] && return 0
      fail "could not inspect running OmniWM processes"
    fi
    sleep 0.25
  done
  fail "an OmniWM process is still running; quit it manually and try again"
}

seed_settings() {
  local config_base="${XDG_CONFIG_HOME:-$HOME/.config}"
  case "$config_base" in
    /*) ;;
    *) config_base="$HOME/.config" ;;
  esac
  local source="$config_base/omniwm/settings.luau"
  local destination="$config_base/omniwm-dev"
  if [ ! -e "$destination" ]; then
    mkdir -p "$destination"
    if [ -f "$source" ]; then
      cp -L "$source" "$destination/settings.luau"
      echo "omniwm-dev: copied settings to $destination/settings.luau"
    fi
  fi
}

open_copy() {
  local command=(open) key value
  for key in XDG_CONFIG_HOME XDG_STATE_HOME OMNIWM_SOCKET; do
    if value="$(printenv "$key")"; then
      command+=(--env "$key=$value")
    fi
  done
  "${command[@]}" "$1"
}

install_dev() {
  validate_destination
  OMNIWM_APP_NAME="$DEV_APP_NAME" \
  OMNIWM_BUNDLE_ID="$DEV_BUNDLE_ID" \
  OMNIWM_SIGNING_IDENTITY="$DEV_IDENTITY" \
    "$ROOT_DIR/Scripts/package-app.sh" debug dev

  quit_other_copies >/dev/null
  wait_for_no_other_omniwm
  seed_settings
  mkdir -p "$INSTALL_DIR"
  rm -rf "$DEV_APP"
  mv "$ROOT_DIR/dist/$DEV_APP_NAME.app" "$DEV_APP"
  echo "omniwm-dev: installed $DEV_APP"
  open_copy "$DEV_APP"
}

use_copy() {
  local app keep_pid
  case "${1:-}" in
    dev) app="$DEV_APP" ;;
    release) app="$RELEASE_APP" ;;
    *) usage ;;
  esac
  [ -d "$app" ] || fail "$app is missing; run 'make dev-install' to build Dev"
  keep_pid="$(quit_other_copies "$app")"
  wait_for_no_other_omniwm "$keep_pid"
  open_copy "$app"
}

case "${1:-}" in
  install) install_dev ;;
  use) use_copy "${2:-}" ;;
  *) usage ;;
esac
