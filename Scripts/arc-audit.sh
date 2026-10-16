#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$root/.build/arc-audit"
products="$scratch/out/Products/Release"
objects="$scratch/out/Intermediates.noindex/OmniWM.build/Release/OmniWMShellCore-t.build/Objects-normal/arm64"
forbidden='_swift_retain|_swift_release|_swift_allocObject|_swift_allocBox|_swift_bridgeObjectRetain|_swift_bridgeObjectRelease|_swift_beginAccess|_swift_getGenericMetadata|_swift_dynamicCast|_objc_retain|_objc_release'

xcrun swift build -c release --target OmniWMShellCore --scratch-path "$scratch" >/dev/null

echo "arc-audit: runtime calls referenced by OmniWMShellCore, by function"
for object in "$objects"/*.o; do
    xcrun objdump --disassemble --no-show-raw-insn -r "$object" \
        | awk -v pattern="$forbidden" -v file="$(basename "$object")" '
            /^[0-9a-f]+ <.*>:$/ { function_name = substr($2, 2, length($2) - 3) }
            /ARM64_RELOC_BRANCH26|ARM64_RELOC_GOT_LOAD_PAGE21/ && $NF ~ "^(" pattern ")$" {
                print "  " file ": " function_name " -> " $NF
            }' \
        | sort -u | xcrun swift-demangle --simplified
done

xcrun clang -c -O2 -o "$scratch/Counters.o" "$root/Scripts/arc-audit/Counters.c"
xcrun swiftc -O -whole-module-optimization -parse-as-library -swift-version 6 \
    -I "$products" \
    -import-objc-header "$root/Scripts/arc-audit/Counters.h" \
    "$root/Scripts/arc-audit/ArcAudit.swift" \
    "$products/OmniWMShellCore.o" "$scratch/Counters.o" \
    -o "$scratch/arc-audit"
"$scratch/arc-audit"

echo "arc-audit: Embedded Swift compile of OmniWMShellCore (not gating)"
shopt -s nullglob
embedded_swiftc=""
for toolchain in "$HOME"/Library/Developer/Toolchains/swift-6.4*-RELEASE.xctoolchain \
    /Library/Developer/Toolchains/swift-6.4*-RELEASE.xctoolchain; do
    if [ -x "$toolchain/usr/bin/swiftc" ]; then
        embedded_swiftc="$toolchain/usr/bin/swiftc"
        break
    fi
done
if [ -z "$embedded_swiftc" ]; then
    echo "  skipped: no swift.org 6.4 toolchain, which carries the Embedded standard library"
elif "$embedded_swiftc" -enable-experimental-feature Embedded -wmo -parse-as-library -module-name OmniWMShellCore \
    -target arm64-apple-macos14 -c "$root"/Sources/OmniWMShellCore/*.swift -o "$scratch/embedded.o" \
    >"$scratch/embedded.log" 2>&1; then
    echo "  compiled with $(basename "$(dirname "$(dirname "$(dirname "$embedded_swiftc")")")")"
else
    echo "  did not compile; see $scratch/embedded.log"
    head -5 "$scratch/embedded.log" | sed 's/^/  /'
fi
