#!/usr/bin/env bash
set -euo pipefail

# Imports the CI signing certificate and notarization key into a temporary
# keychain so Scripts/package-app.sh and Scripts/omniwm_release.py work
# unchanged via their --keychain-profile / OMNIWM_NOTARIZE_PROFILE plumbing.
# Required inputs are supplied by the release workflow; run `cleanup` in an
# always() step to delete the keychain afterwards.

SCRIPT_NAME="release-ci-credentials"
KEYCHAIN_PATH="${RUNNER_TEMP:-}/omniwm-release.keychain-db"

case "${1:-store}" in
  cleanup)
    if [ -n "${RUNNER_TEMP:-}" ] && [ -e "$KEYCHAIN_PATH" ]; then
      security delete-keychain "$KEYCHAIN_PATH"
    fi
    exit 0
    ;;
  store) ;;
  *)
    echo "$SCRIPT_NAME: unknown subcommand '$1' (expected none or 'cleanup')" >&2
    exit 2
    ;;
esac

MISSING=()
for VAR in APPLE_DEVELOPER_ID_CERT_P12_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD \
  APPLE_NOTARY_KEY_ID APPLE_NOTARY_ISSUER_ID APPLE_NOTARY_KEY_P8 \
  RUNNER_TEMP KEYCHAIN_PASSWORD; do
  if [ -z "${!VAR:-}" ]; then
    MISSING+=("$VAR")
  fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  printf '%s: missing required environment variables: %s\n' \
    "$SCRIPT_NAME" "${MISSING[*]}" >&2
  exit 2
fi

IDENTITY="${OMNIWM_RELEASE_SIGNING_IDENTITY:-Developer ID Application: Oliver Nikolic (VF8LDJRGFM)}"
NOTARIZE_PROFILE="${OMNIWM_RELEASE_NOTARIZE_PROFILE:-OmniWM-Notarize}"
CERT_PATH="$RUNNER_TEMP/developer-id.p12"
NOTARY_KEY_PATH="$RUNNER_TEMP/AuthKey_${APPLE_NOTARY_KEY_ID}.p8"

trap 'rm -f "$CERT_PATH" "$NOTARY_KEY_PATH"' EXIT

umask 077
printf '%s' "$APPLE_DEVELOPER_ID_CERT_P12_BASE64" | base64 --decode > "$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security import "$CERT_PATH" \
  -P "$APPLE_DEVELOPER_ID_CERT_PASSWORD" \
  -A \
  -t cert \
  -f pkcs12 \
  -k "$KEYCHAIN_PATH"

security list-keychains -d user -s "$KEYCHAIN_PATH"
security default-keychain -s "$KEYCHAIN_PATH"

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$KEYCHAIN_PATH"

IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH")"
if ! grep -qF -- "$IDENTITY" <<<"$IDENTITIES"; then
  echo "$SCRIPT_NAME: signing identity '$IDENTITY' not found in $KEYCHAIN_PATH; check OMNIWM_RELEASE_SIGNING_IDENTITY and the imported certificate" >&2
  exit 1
fi

printf '%s\n' "$APPLE_NOTARY_KEY_P8" > "$NOTARY_KEY_PATH"
head -n 1 "$NOTARY_KEY_PATH" | grep -q 'BEGIN PRIVATE KEY' || {
  echo "$SCRIPT_NAME: APPLE_NOTARY_KEY_P8 does not start with a BEGIN PRIVATE KEY line" >&2
  exit 1
}
tail -n 1 "$NOTARY_KEY_PATH" | grep -q 'END PRIVATE KEY' || {
  echo "$SCRIPT_NAME: APPLE_NOTARY_KEY_P8 does not end with an END PRIVATE KEY line; check for a truncated paste" >&2
  exit 1
}
if grep -q '\\n' "$NOTARY_KEY_PATH"; then
  echo "$SCRIPT_NAME: APPLE_NOTARY_KEY_P8 contains literal \\n sequences; paste the raw .p8 contents instead" >&2
  exit 1
fi

xcrun notarytool store-credentials "$NOTARIZE_PROFILE" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_ISSUER_ID" \
  --keychain "$KEYCHAIN_PATH"
