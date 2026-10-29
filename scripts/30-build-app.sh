#!/usr/bin/env bash
# Assemble and build the iOS app: firmware into the bundle, XcodeGen project
# from project.yml, xcodebuild unsigned, zip into an .ipa.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/app"
BUILD="${ROOT}/build"
DIST="${ROOT}/dist"
LIB="${BUILD}/qemu-ios/libqemu-system-aarch64.a"

banner() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ -f "$LIB" ] || die "missing $LIB — run scripts/10-build-qemu-ios.sh, or restore a
       prebuilt engine with scripts/09-restore-engine.sh <url>"
command -v xcodebuild >/dev/null || die "xcodebuild missing (macOS + Xcode)"
command -v xcodegen >/dev/null || die "xcodegen missing (brew install xcodegen)"

banner "firmware into the bundle"
mkdir -p "${APP}/AokVM/Resources"
for blob in edk2-aarch64-code.fd edk2-arm-vars.fd; do
    [ -f "${BUILD}/firmware/${blob}" ] || die "missing build/firmware/${blob}"
    cp "${BUILD}/firmware/${blob}" "${APP}/AokVM/Resources/${blob}"
done
ls -lh "${APP}/AokVM/Resources"

banner "project"
( cd "$APP" && xcodegen generate --spec project.yml )

banner "build"
mkdir -p "$DIST"
( cd "$APP" && xcodebuild \
    -project AokVM.xcodeproj \
    -scheme AokVM \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "${BUILD}/app" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ENABLE_BITCODE=NO \
    build 2>&1 | tee "${BUILD}/xcodebuild.log" | tail -30 )

APP_BUNDLE="${BUILD}/app/Build/Products/Release-iphoneos/AokVM.app"
[ -d "$APP_BUNDLE" ] || die "no app bundle at $APP_BUNDLE"

banner "verify the binary"
# qemu_init must be inside, and the engine's own main() must not be: the app's
# entry point is @main in Swift.
nm -gU "$APP_BUNDLE/AokVM" | grep -q ' _qemu_init$' || die "qemu_init not linked in"
if nm -gU "$APP_BUNDLE/AokVM" | grep -q ' _qemu_system_main$'; then
    echo "note: qemu_system_main is linked but never called (expected)"
fi
lipo -info "$APP_BUNDLE/AokVM"
du -sh "$APP_BUNDLE"

banner "ipa"
STAGE="${BUILD}/ipa-stage"
rm -rf "$STAGE"; mkdir -p "${STAGE}/Payload"
cp -R "$APP_BUNDLE" "${STAGE}/Payload/"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
           "$APP_BUNDLE/Info.plist" 2>/dev/null || echo 0.0.0)"
IPA="${DIST}/AokVM-${VERSION}-unsigned.ipa"
( cd "$STAGE" && zip -qry "$IPA" Payload )
rm -rf "$STAGE"

banner "done"
ls -lh "$IPA"
shasum -a 256 "$IPA" | tee "${DIST}/$(basename "$IPA" .ipa).sha256"
echo
echo "Install with SideStore/AltStore/TrollStore, then import"
echo "  $(basename "${OUT:-build/ut/ut-2404-arm64.img}")"
