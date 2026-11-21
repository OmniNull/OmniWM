#!/bin/bash
set -euo pipefail

usage() {
  echo "usage: $0 restore|save DIR" >&2
  exit 2
}

MODE="${1:-}"
DIR="${2:-}"
[ -n "$DIR" ] || usage
case "$MODE" in
  restore | save) ;;
  *) usage ;;
esac

PINS="$(dirname "$0")/dev-tools.env"
pin() {
  sed -n "s/^$1=//p" "$PINS"
}

GHOSTTY_URL="$(pin OMNIWM_GHOSTTY_DOWNLOAD_URL)"
DOWNLOADS=(
  "swiftformat.zip $(pin OMNIWM_SWIFTFORMAT_ZIP_SHA256)"
  "portable_swiftlint.zip $(pin OMNIWM_SWIFTLINT_ZIP_SHA256)"
  "${GHOSTTY_URL##*/} $(pin OMNIWM_GHOSTTY_ZIP_SHA256)"
)

for download in "${DOWNLOADS[@]}"; do
  read -r name hash <<<"$download"
  store_path="$(nix-store --print-fixed-path sha256 "$hash" "$name")"
  if [ "$MODE" = save ]; then
    mkdir -p "$DIR"
    install -m 644 "$store_path" "$DIR/$name"
  elif [ -f "$DIR/$name" ]; then
    added="$(nix-store --add-fixed sha256 "$DIR/$name")"
    if [ "$added" != "$store_path" ]; then
      echo "$0: $DIR/$name does not match its pinned SHA-256" >&2
      exit 1
    fi
  fi
done
