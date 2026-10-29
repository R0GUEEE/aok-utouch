#!/usr/bin/env bash
# Configure and build QEMU's aarch64 system emulator for iPhoneOS arm64 with
# the TCTI backend and the AOK gadget front end, then turn the result into a
# static library Xcode can link.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/src/qemu"
BUILD="${ROOT}/build"
PREFIX="${BUILD}/ios-sysroot"
OUT="${BUILD}/qemu-ios"
CROSS="${BUILD}/cross-aarch64-ios.txt"
MIN="${IOS_MIN:-16.0}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

banner() { printf '\n== %s\n' "$*"; }

[ -d "$SRC" ] || { echo "run scripts/00-fetch.sh first" >&2; exit 1; }
# The sysroot is restored from a prebuilt tarball in CI, so the cross file has
# to be regenerable without running the dependency build.
CROSS="$(bash "${ROOT}/scripts/04-cross-file.sh")"
[ -d "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ] || {
    echo "no sysroot at $PREFIX — run scripts/05-build-deps.sh or restore a prebuilt one" >&2
    exit 1; }
command -v meson >/dev/null || { echo "meson missing: pip3 install meson" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja missing: brew install ninja" >&2; exit 1; }

export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_PATH=""

HASH="$(bash "${ROOT}/scripts/hash.sh" qemu)"
STAMP="${OUT}/.aok-qemu-${HASH}"
TARBALL="${BUILD}/prebuilt/qemu-aarch64-ios-${HASH}.tar.gz"

pack() {
    # Layout matches what scripts/09-restore-engine.sh expects under build/.
    mkdir -p "$BUILD/prebuilt"
    tar -czf "$TARBALL" -C "$BUILD" \
        qemu-ios/libqemu-system-aarch64.a \
        "qemu-ios/.aok-qemu-${HASH}" \
        qemu-ios/BUILDINFO \
        qemu-headers \
        firmware
    ls -lh "$TARBALL"
}

if [ -f "$OUT/libqemu-system-aarch64.a" ] && [ -f "$STAMP" ] && [ "${FORCE:-0}" != 1 ]; then
    banner "engine ${HASH} already built"
    [ "${PACK:-0}" = "1" ] && pack
    exit 0
fi

banner "configure"
# A note on the two interesting flags:
#   --enable-tcg-threaded-interpreter  makes the TCG code buffer data, not code
#   --enable-aok-gadgets               one gadget per guest instruction, AArch64
#                                      host, system emulation only
# Everything visual is disabled: no SDL, GTK, OpenGL, virgl, VNC. The app owns
# the window; QEMU only has to fill a surface.
mkdir -p "$OUT"
mkdir -p "$BUILD/configure-logs"
if [ ! -f "$OUT/config-host.mak" ]; then
    "$SRC/configure" \
        --cross-file="$CROSS" \
        --target-list=aarch64-softmmu \
        --enable-aok-gadgets \
        --enable-tcg-threaded-interpreter \
        --enable-slirp \
        --disable-user --disable-bsd-user --disable-linux-user \
        --disable-tools --disable-docs --disable-guest-agent \
        --disable-install-blobs \
        --disable-gtk --disable-sdl --disable-opengl --disable-virglrenderer \
        --disable-vnc --disable-spice --disable-curses --disable-cocoa \
        --disable-coreaudio --disable-pa --disable-alsa --disable-jack \
        --disable-pulseaudio --disable-dbus-display --disable-qed \
        --disable-vhost-user --disable-vhost-vdpa --disable-vhost-net \
        --disable-capstone --disable-fdt-tests \
        --disable-fuse --disable-fuse-lseek --disable-virtfs \
        --disable-download --disable-docs \
        --disable-werror \
        --prefix="$OUT/install" \
        2>&1 | tee "$BUILD/configure-logs/qemu-ios.log"
else
    echo "reusing existing configuration in $OUT"
fi

banner "build"
# -j is capped: ld64's memory use on an emulated/CI host is the real limit.
ninja -C "$OUT" -j"${JOBS}" qemu-system-aarch64 2>&1 | tail -40

banner "verify the two properties the whole port rests on"
CONFIG_H="$OUT/config-host.h"
grep -q 'define CONFIG_TCG_THREADED_INTERPRETER 1' "$CONFIG_H" || {
    echo "FATAL: TCTI is not enabled; the code buffer would be RWX" >&2; exit 1; }
grep -q 'define CONFIG_AOK_GADGETS 1' "$CONFIG_H" || {
    echo "FATAL: AOK gadgets are not enabled" >&2; exit 1; }
if grep -q 'define CONFIG_TCG_HYBRID 1' "$CONFIG_H"; then
    echo "note: hybrid build; the app relies on the TCTI backend being chosen"
fi
echo "TCTI + AOK gadgets: OK"

banner "static library"
FA="$OUT/libqemu-system-aarch64.fa"
if [ ! -f "$FA" ]; then
    FA="$(find "$OUT" -maxdepth 2 -name 'libqemu-system-aarch64*.fa' | head -1)"
fi
[ -f "$FA" ] || { echo "no libqemu-system-aarch64.fa produced" >&2; exit 1; }

WORK="$OUT/fa-objects"
rm -rf "$WORK"; mkdir -p "$WORK"
( cd "$WORK" && ar x "$FA" )
OBJ_COUNT="$(find "$WORK" -name '*.o' | wc -l | tr -d ' ')"
echo "extracted $OBJ_COUNT objects from $(basename "$FA")"
# libtool is Apple's archiver: produces an archive ld64 reads happily, unlike
# the .fa that meson writes.
( cd "$WORK" && xcrun libtool -static -o "$OUT/libqemu-system-aarch64.a" ./*.o )
ls -lh "$OUT/libqemu-system-aarch64.a"
rm -rf "$WORK"

banner "firmware blobs"
mkdir -p "$BUILD/firmware"
for blob in edk2-aarch64-code.fd edk2-arm-vars.fd; do
    if [ -f "$OUT/pc-bios/$blob" ]; then
        cp "$OUT/pc-bios/$blob" "$BUILD/firmware/"
    elif [ -f "$OUT/pc-bios/$blob.bz2" ]; then
        bunzip2 -kc "$OUT/pc-bios/$blob.bz2" > "$BUILD/firmware/$blob"
    fi
done
ls -lh "$BUILD/firmware" || echo "warning: edk2 blobs not found in pc-bios"

banner "stage headers for the app"
# The app must not need a 700 MB QEMU checkout to compile one C file. Copy the
# header tree plus the generated headers into a directory that can be shipped.
HDR="$BUILD/qemu-headers"
rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$SRC/include" "$HDR/include"
cp "$OUT/config-host.h" "$HDR/"
if [ -d "$OUT/qapi" ]; then
    cp -R "$OUT/qapi" "$HDR/qapi"
fi
for extra in qemu-version.h config-target.h; do
    [ -f "$OUT/$extra" ] && cp "$OUT/$extra" "$HDR/"
done
du -sh "$HDR"

date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP"
echo "$HASH" >> "$STAMP"

banner "provenance"
{
    echo "hash=${HASH}"
    echo "qemu_commit=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(uname -srm)"
    echo "xcode=$(xcodebuild -version 2>/dev/null | head -1)"
    echo "flags=--enable-aok-gadgets --enable-tcg-threaded-interpreter --target-list=aarch64-softmmu"
} | tee "$OUT/BUILDINFO"

if [ "${PACK:-0}" = "1" ]; then
    banner "pack"
    pack
fi

banner "done"
echo "library: $OUT/libqemu-system-aarch64.a"
echo "headers: $HDR (shipped copy), $SRC/include (source of truth)"
