#!/usr/bin/env bash
# Install only the prebuilt dependencies needed by this CI job.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source Scripts/dev-tools.env
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

download() {
  curl --fail --silent --show-error --location --retry 3 --output "$work/archive" "$1"
  echo "$2  $work/archive" | shasum -a 256 -c -
}

case "${1:-}" in
  style)
    case "$(uname -s)" in
      Linux)
        format_asset=swiftformat_linux.zip
        format_sha="$OMNIWM_SWIFTFORMAT_LINUX_ZIP_SHA256"
        lint_asset=swiftlint_linux_amd64.zip
        lint_sha="$OMNIWM_SWIFTLINT_LINUX_ZIP_SHA256"
        ;;
      Darwin)
        format_asset=swiftformat.zip
        format_sha="$OMNIWM_SWIFTFORMAT_ZIP_SHA256"
        lint_asset=portable_swiftlint.zip
        lint_sha="$OMNIWM_SWIFTLINT_ZIP_SHA256"
        ;;
      *) echo 'Unsupported CI style platform' >&2; exit 1 ;;
    esac
    mkdir -p .cache/flake-tools/bin
    download "https://github.com/nicklockwood/SwiftFormat/releases/download/$SWIFTFORMAT_VERSION/$format_asset" "$format_sha"
    unzip -qo "$work/archive" -d .cache/flake-tools/bin
    if [[ "$(uname -s)" == Linux ]]; then
      mv .cache/flake-tools/bin/swiftformat_linux .cache/flake-tools/bin/swiftformat
    fi
    download "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/$lint_asset" "$lint_sha"
    unzip -qo "$work/archive" -d .cache/flake-tools/bin
    if [[ "$(uname -s)" == Linux ]]; then
      mv -f .cache/flake-tools/bin/swiftlint-static .cache/flake-tools/bin/swiftlint
      # SourceKit rules still use the runner's Swift installation.
      swift_bin="$(readlink -f "$(command -v swift)")"
      sourcekit="$(dirname "$(dirname "$swift_bin")")/lib/libsourcekitdInProc.so"
      test -f "$sourcekit"
      echo "LINUX_SOURCEKIT_LIB_PATH=$sourcekit" >> "$GITHUB_ENV"
    fi
    chmod +x .cache/flake-tools/bin/swiftformat .cache/flake-tools/bin/swiftlint
    ;;
  ghostty)
    if [[ ! -d Frameworks/GhosttyKit.xcframework ]]; then
      download "$OMNIWM_GHOSTTY_DOWNLOAD_URL" "$OMNIWM_GHOSTTY_ZIP_SHA256"
      mkdir -p Frameworks
      unzip -q "$work/archive" -d Frameworks
    fi
    ./Scripts/ghostty-preflight.sh verify
    ;;
  nu)
    download "https://github.com/nushell/nushell/releases/download/$NUSHELL_VERSION/nu-$NUSHELL_VERSION-aarch64-apple-darwin.tar.gz" "$OMNIWM_NUSHELL_MACOS_SHA256"
    tar -xzf "$work/archive" -C "$work" --strip-components=1
    mkdir -p .cache/ci-shells
    install -m755 "$work/nu" .cache/ci-shells/nu
    .cache/ci-shells/nu --version
    ;;
  *) echo 'Usage: Scripts/ci-dependencies.sh {style|ghostty|nu}' >&2; exit 1 ;;
esac
