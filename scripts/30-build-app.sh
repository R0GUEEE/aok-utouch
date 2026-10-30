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

LIST="${BUILD}/qemu-ios/engine-link-inputs.txt"
[ -s "$LIST" ] || die "missing $LIST — run scripts/10-build-qemu-ios.sh, or restore a
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

banner "guest image"
# The guest travels inside the app: ~1 GiB of mostly zeroes compresses to a few
# tens of MB and is unpacked into Application Support on first start.
GUEST="${GUEST_IMAGE:-${ROOT}/build/guest/alpine.img}"
if [ -f "$GUEST" ]; then
    gzip -9 -c "$GUEST" > "${APP}/AokVM/Resources/${GUEST_BUNDLE_NAME:-alpine.img.gz}"
    ls -lh "$GUEST" "${APP}/AokVM/Resources/alpine.img.gz"
else
    echo "warning: no guest image at $GUEST — the app will build without one"
    echo "         (build it with scripts/20-make-alpine-image.sh, or set GUEST_IMAGE)"
    rm -f "${APP}/AokVM/Resources/alpine.img.gz"
fi

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

banner "verify the link list"
# _main in the response file means a QEMU object was copied under a colliding
# name; the app has its own @main and would link two.
if grep -q 'system_main\.c\.o' "$LIST"; then
    MAIN_COUNT="$(grep -c 'system_main\.c\.o' "$LIST")"
    [ "$MAIN_COUNT" -eq 1 ] || {
        echo "error: $MAIN_COUNT objects named *system_main.c.o in the link list" >&2
        exit 1; }
fi

banner "verify the binary"
# qemu_init must be inside, and the engine's own main() must not be: the app's
# entry point is @main in Swift.
# nm -U is "defined symbols only" on Darwin; the binary is not stripped, so the
# engine's entry points must be there.
if nm -U "$APP_BUNDLE/AokVM" 2>/dev/null | grep -q ' _qemu_init$'; then
    echo "qemu_init: present"
    nm -U "$APP_BUNDLE/AokVM" | grep -q ' _qemu_main_loop$' \
        || die "qemu_main_loop not linked in"
else
    echo "note: binary looks stripped, falling back to a size check"
    SIZE="$(stat -f%z "$APP_BUNDLE/AokVM")"
    [ "$SIZE" -gt 20000000 ] || die "app binary is $SIZE bytes; the engine is missing"
fi
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
echo "  build/guest/alpine.img"
