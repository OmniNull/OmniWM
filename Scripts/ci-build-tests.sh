#!/bin/bash

set -euo pipefail
cd "$(dirname "$0")/.."

scratch=.build/localization
library_dir="$(./Scripts/ghostty-preflight.sh print-library-dir)"
export LIBRARY_PATH="$library_dir${LIBRARY_PATH:+:$LIBRARY_PATH}"
build=(swift build --build-tests --build-system swiftbuild --arch arm64 --scratch-path "$scratch")

if [[ -z "${CACHED_BUILD_KEY:-}" ]]; then
    exec "${build[@]}"
fi

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if "${build[@]}" 2>&1 | tee "$log"; then
    exit 0
else
    status=$?
fi

if ! grep -Eq 'Assertion failed: .*Wrote the same PCM with different contents.*InProcessModuleCache\.cpp' "$log"; then
    exit "$status"
fi

# Swift Build shares module caches and the build description in its scratch directory.
echo "::warning::Clang aborted while scanning modules with a restored cache. Rebuilding from an empty Swift Build scratch directory."
rm -rf -- "$scratch"
"${build[@]}"
