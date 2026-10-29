#!/usr/bin/env bash
# Write build/cross-aarch64-ios.txt from cross/aarch64-ios.txt.in for the
# installed iPhoneOS SDK, and print its path.
#
# Called by 05-build-deps.sh (deps) and 10-build-qemu-ios.sh (engine). The
# engine job in CI restores a prebuilt sysroot and never runs the deps script,
# so this small step has to be reachable on its own.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deps/manifest.env
. "${ROOT}/deps/manifest.env"

command -v xcrun >/dev/null || { echo "xcrun missing: macOS with Xcode required" >&2; exit 1; }
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
PREFIX="${ROOT}/build/ios-sysroot"
OUT="${ROOT}/build/cross-aarch64-ios.txt"

mkdir -p "${ROOT}/build"
sed -e "s|@SDKROOT@|${SDKROOT}|g" \
    -e "s|@MIN@|${IOS_MIN}|g" \
    -e "s|@PREFIX@|${PREFIX}|g" \
    "${ROOT}/cross/aarch64-ios.txt.in" > "$OUT"

echo "$OUT"
