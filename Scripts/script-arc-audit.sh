#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

set -euo pipefail
cd "$(dirname "$0")/.."
swiftly_bin="${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/bin"
scratch="${OMNIWM_SCRIPT_ARC_SCRATCH:-$PWD/.build/script-arc-audit}"
configuration=release
product_configuration=Release
build_flags=(--build-system swiftbuild --arch arm64)
if (($#)); then
    if [[ $# != 2 || $1 != --lifetime ]]; then
        echo "usage: $0 [--lifetime debug|release|asan]" >&2
        exit 2
    fi
    case "$2" in
        debug) configuration=debug; product_configuration=Debug ;;
        release) ;;
        asan)
            runtime="$("$swiftly_bin/clang" -print-resource-dir)/lib/darwin"
            build_flags+=(--sanitize address -Xlinker "-L$runtime" -Xlinker -lclang_rt.asan_osx_dynamic)
            ;;
        *) echo "unknown lifetime build: $2" >&2; exit 2 ;;
    esac
    scratch="$scratch/$2"
fi
mkdir -p "$scratch"
export OMNIWM_SCRIPT_ARC_DIRECTORY="$(cd "$scratch" && pwd)"
unset OMNIWM_LIVE_CHECKS
scratch="$OMNIWM_SCRIPT_ARC_DIRECTORY"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
library="$scratch/libScriptARC.dylib"
tool=Scripts/script-arc-audit
fixture="$(mktemp -d "$scratch/fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
"$swiftly_bin/clang" -O2 -Wall -Werror -isysroot "$sdk" -target arm64-apple-macos26 \
    -dynamiclib Scripts/arc-audit/Counters.c "$tool"/Interpose/*.c \
    -I Scripts/arc-audit -I "$tool/Counters/include" -L "$sdk/usr/lib/swift" \
    -lswiftCore -lswift_Concurrency -lobjc -framework CoreFoundation \
    -install_name "$library" -o "$fixture/libScriptARC.dylib"
if ! cmp -s "$fixture/libScriptARC.dylib" "$library"; then
    mv -f "$fixture/libScriptARC.dylib" "$library"
fi
export LIBRARY_PATH="$(./Scripts/ghostty-preflight.sh print-library-dir)${LIBRARY_PATH:+:$LIBRARY_PATH}"
"$swiftly_bin/swift" build "${build_flags[@]}" -c "$configuration" --product script-arc-audit --scratch-path "$scratch/products"
binary_dir="$scratch/products/out/Products/$product_configuration"
export SWIFT_DETERMINISTIC_HASHING=1
if (($#)); then
    "$binary_dir/script-arc-audit" "$fixture" --lifetime
    exit
fi
DYLD_INSERT_LIBRARIES="$library" "$binary_dir/script-arc-audit" "$fixture" | tee "$fixture/counts.txt"
python3 "$tool/check.py" "$swiftly_bin/lldb" "$binary_dir/script-arc-audit" "$fixture" "$fixture/counts.txt"
"$binary_dir/script-arc-audit" "$fixture" --lifetime
