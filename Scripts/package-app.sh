#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
SIGN_AND_NOTARIZE="${2:-true}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${OMNIWM_APP_NAME:-OmniWM}"
BUNDLE_ID="${OMNIWM_BUNDLE_ID:-com.barut.OmniWM}"
case "$APP_NAME" in
  .|..|*/*)
    echo "package-app: the app name must be a single directory name" >&2
    exit 1
    ;;
esac
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
GHOSTTY_LIBRARY_DIR="$("$ROOT_DIR/Scripts/ghostty-preflight.sh" print-library-dir)"
SWIFT_BUILD_ARGS=(-c "$CONFIG" --arch arm64)

# Signing identity and notarization profile
SIGNING_IDENTITY="${OMNIWM_SIGNING_IDENTITY:-Developer ID Application: Oliver Nikolic (VF8LDJRGFM)}"
NOTARIZE_PROFILE="${OMNIWM_NOTARIZE_PROFILE:-OmniWM-Notarize}"
ENTITLEMENTS="$ROOT_DIR/OmniWM.entitlements"

echo "Running release checks..."
make -C "$ROOT_DIR" release-check

"$ROOT_DIR/Scripts/ghostty-preflight.sh" verify

echo "Building OmniWM arm64 binary ($CONFIG)..."
LIBRARY_PATH="$GHOSTTY_LIBRARY_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}" swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_DIR="$(LIBRARY_PATH="$GHOSTTY_LIBRARY_DIR${LIBRARY_PATH:+:$LIBRARY_PATH}" swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BUILD_DIR/OmniWM"
CLI_EXECUTABLE="$BUILD_DIR/omniwmctl"

echo "Verifying arm64 binaries..."
lipo -info "$EXECUTABLE"
lipo -info "$CLI_EXECUTABLE"

echo "Packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/OmniWM"
cp "$CLI_EXECUTABLE" "$APP_DIR/Contents/MacOS/omniwmctl"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if command -v plutil >/dev/null 2>&1; then
  plutil -replace OMNIWMGitHash -string "$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo SNAPSHOT)" "$APP_DIR/Contents/Info.plist"
  if [ "$APP_NAME" != "OmniWM" ] || [ "$BUNDLE_ID" != "com.barut.OmniWM" ]; then
    plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
    plutil -replace CFBundleName -string "$APP_NAME" "$APP_DIR/Contents/Info.plist"
    plutil -replace CFBundleDisplayName -string "$APP_NAME" "$APP_DIR/Contents/Info.plist"
  fi
fi
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp -R "$BUILD_DIR/OmniWM_OmniWM.bundle" "$APP_DIR/Contents/Resources/"
python3 "$ROOT_DIR/Scripts/localization.py" package \
  --bundle "$BUILD_DIR/OmniWM_OmniWM.bundle" --app "$APP_DIR"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
fi

if [ "$SIGN_AND_NOTARIZE" = "true" ]; then
  echo "Signing $APP_DIR with hardened runtime..."
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" --timestamp "$APP_DIR/Contents/MacOS/omniwmctl"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" --timestamp "$APP_DIR/Contents/MacOS/OmniWM"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" --timestamp "$APP_DIR"

  echo "Verifying signature..."
  codesign --verify --verbose "$APP_DIR"

  echo "Creating ZIP for notarization..."
  ZIP_PATH="$ROOT_DIR/dist/OmniWM.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

  echo "Submitting for notarization (this may take a few minutes)..."
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARIZE_PROFILE" --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$APP_DIR"

  echo "Verifying notarization..."
  spctl --assess --verbose=2 "$APP_DIR"

  echo "Checking distribution readiness..."
  syspolicy_check distribution "$APP_DIR"

  rm -f "$ZIP_PATH"
  echo "Done! $APP_DIR is signed and notarized."
elif [ "$SIGN_AND_NOTARIZE" = "dev" ]; then
  if security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
    IDENTITY="$SIGNING_IDENTITY"
  else
    IDENTITY="-"
    echo "No '$SIGNING_IDENTITY' certificate found; using ad-hoc signing. macOS may request permissions again after rebuilding. See CONTRIBUTING.md for certificate setup." >&2
  fi
  echo "Signing $APP_DIR for development (identity: $IDENTITY)..."
  codesign --force --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/omniwmctl"
  codesign --force --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/OmniWM"
  codesign --force --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"
  codesign --verify --verbose "$APP_DIR"
  echo "Done. Launch with 'open $APP_DIR' so LaunchServices assigns the app identity."
else
  echo "Done. Open $APP_DIR to grant Accessibility permissions."
  echo "Note: App is not signed. Run with 'release true' to sign and notarize."
fi
