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

export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_PATH=""

HASH="$(bash "${ROOT}/scripts/hash.sh" qemu)"
STAMP="${OUT}/.aok-qemu-${HASH}"
TARBALL="${BUILD}/prebuilt/qemu-aarch64-ios-${HASH}.tar.gz"

pack() {
    # Layout matches what scripts/09-restore-engine.sh expects under build/.
    # ~1200 objects at ~64 KB apiece compress to a few tens of MB; the tarball
    # is the whole engine as far as the app is concerned.
    mkdir -p "$BUILD/prebuilt"
    tar -czf "$TARBALL" -C "$BUILD" \
        qemu-ios/flatten \
        qemu-ios/engine-link-inputs.txt \
        "qemu-ios/.aok-qemu-${HASH}" \
        qemu-ios/BUILDINFO \
        qemu-headers \
        firmware
    ls -lh "$TARBALL"
}

# The cache path must not need a QEMU checkout: CI restores the library and the
# staged headers from a cache or an artifact and never clones the source.
if [ -f "$OUT/libqemu-system-aarch64.a" ] && [ -f "$STAMP" ] && [ "${FORCE:-0}" != 1 ]; then
    banner "engine ${HASH} already built"
    [ "${PACK:-0}" = "1" ] && pack
    exit 0
fi

banner "preconditions"
[ -d "$SRC" ] || { echo "run scripts/00-fetch.sh first" >&2; exit 1; }
# Kept for inspection and hashed as a build input; configure writes its own
# machine file, so this is not passed to it.
CROSS="$(bash "${ROOT}/scripts/04-cross-file.sh")"
[ -d "$PREFIX" ] && [ -n "$(ls -A "$PREFIX")" ] || {
    echo "no sysroot at $PREFIX — run scripts/05-build-deps.sh or restore a prebuilt one" >&2
    exit 1; }
command -v meson >/dev/null || { echo "meson missing: pip3 install meson" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja missing: brew install ninja" >&2; exit 1; }

banner "toolchain"
# QEMU's configure has no --cross-file: it writes its own config-meson.cross
# from the compilers it finds. This fork detects the iOS device target from
# TargetConditionals.h and adds needs_exe_wrapper=true itself, which is exactly
# what a cross build from an Intel Mac needs.
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
TARGET_FLAGS="-arch arm64 -isysroot ${SDKROOT} -miphoneos-version-min=${MIN}"
export CC="${CC:-xcrun --sdk iphoneos clang}"
export CXX="${CXX:-xcrun --sdk iphoneos clang++}"
export OBJCC="${OBJCC:-xcrun --sdk iphoneos clang}"
export CFLAGS="${CFLAGS:-} ${TARGET_FLAGS} -O3"
export CXXFLAGS="${CXXFLAGS:-} ${TARGET_FLAGS} -O3"
export OBJCFLAGS="${OBJCFLAGS:-} ${TARGET_FLAGS} -O3"
export LDFLAGS="${LDFLAGS:-} ${TARGET_FLAGS}"
export AR="xcrun --sdk iphoneos ar"
export RANLIB="xcrun --sdk iphoneos ranlib"
export STRIP="xcrun --sdk iphoneos strip"
export NM="xcrun --sdk iphoneos nm"
export OBJCOPY="xcrun --sdk iphoneos objcopy"
echo "CC=$CC"
echo "SDK=$SDKROOT"

banner "configure"
# Subprojects (dtc/libfdt, keycodemapdb, berkeley-softfloat, libslirp) are
# downloaded by meson rather than pinned as git submodules: QEMU's .gitmodules
# marks the ROM submodules "update = none", and the ones that matter are wraps.
#
# A note on the two interesting flags:
#   --enable-tcg-threaded-interpreter  makes the TCG code buffer data, not code
#   --enable-aok-gadgets               one gadget per guest instruction, AArch64
#                                      host, system emulation only
# Everything visual is disabled: no SDL, GTK, OpenGL, virgl, VNC. The app owns
# the window; QEMU only has to fill a surface.
mkdir -p "$OUT"
mkdir -p "$BUILD/configure-logs"
if [ ! -f "$OUT/config-host.mak" ]; then
    # configure must run *inside* the build dir: meson refuses a build dir that
    # is a parent of the source tree, which is what happens if you invoke
    # src/qemu/configure from the repo root.
    ( cd "$OUT" && "$SRC/configure" \
        --cross-prefix= \
        --cpu=aarch64 \
        --target-list=aarch64-softmmu \
        --enable-aok-gadgets \
        --enable-tcg-threaded-interpreter \
        --enable-slirp \
        --disable-user --disable-bsd-user \
        --disable-tools --disable-docs --disable-guest-agent \
        --disable-werror \
        --disable-gtk --disable-sdl --disable-opengl --disable-virglrenderer \
        --disable-vnc --disable-spice --disable-curses --disable-cocoa \
        --disable-coreaudio --disable-pa --disable-alsa --disable-jack \
        --disable-pipewire --disable-dbus-display \
        --disable-vhost-user --disable-vhost-vdpa --disable-vhost-net \
        --disable-capstone --disable-fuse --disable-fuse-lseek \
        --disable-virtfs --disable-qed --disable-bzip2 \
        --prefix="$OUT/install" \
        2>&1 | tee "$BUILD/configure-logs/qemu-ios.log" )
else
    echo "reusing existing configuration in $OUT"
fi

banner "build"
# -j is capped: ld64's memory use on an emulated/CI host is the real limit.
ninja -C "$OUT" -j"${JOBS}" qemu-system-aarch64 2>&1 | tail -40

banner "verify the two properties the whole port rests on"
CONFIG_H="$OUT/config-host.h"
# meson writes "#define NAME" for booleans and "#define NAME 1" for explicit
# values, so match the symbol, not the value.
grep -n 'TCG_THREADED_INTERPRETER\|AOK_GADGETS' "$CONFIG_H" || echo "(no TCG macros in $CONFIG_H)"
grep -q 'define CONFIG_TCG_THREADED_INTERPRETER' "$CONFIG_H" || {
    echo "FATAL: TCTI is not enabled; the code buffer would be RWX" >&2; exit 1; }
grep -q 'define CONFIG_AOK_GADGETS' "$CONFIG_H" || {
    echo "FATAL: AOK gadgets are not enabled" >&2; exit 1; }
# Belt and braces, informational: the generated TCTI gadget translation units
# only exist when the backend is TCTI. They live under $OUT/tcg/.
find "$OUT" -name '*tcti*gadgets.c' -print -quit | grep -q . \
    && echo "generated TCTI gadget sources: yes" \
    || echo "note: no generated TCTI gadget sources found (macros already confirmed)"
if grep -q 'define CONFIG_TCG_HYBRID 1' "$CONFIG_H"; then
    echo "note: hybrid build; the app relies on the TCTI backend being chosen"
fi
echo "TCTI + AOK gadgets: OK"

banner "static library"
LIB="$OUT/libqemu-system-aarch64.a"
OBJECT_LIST_OUT="$OUT/engine-link-inputs.txt"

if [ -s "$OBJECT_LIST_OUT" ]; then
    echo "reusing $OBJECT_LIST_OUT ($(wc -l < "$OBJECT_LIST_OUT" | tr -d ' ') link inputs)"
else
    # Read the object list out of QEMU's own link command instead of guessing
    # where Meson put things: the emulator is linked from ~2000 objects plus the
    # subproject archives, and no single .fa is left behind afterwards.
    LIST="$OUT/link-inputs.txt"
    python3 "${ROOT}/scripts/qemu-link-objects.py" "$OUT" > "$LIST" || exit 1
    OBJ_COUNT="$(grep -c '\.o$' "$LIST" || true)"
    echo "$OBJ_COUNT objects on the link line"
    [ "${OBJ_COUNT:-0}" -gt 500 ] || {
        echo "error: only ${OBJ_COUNT:-0} objects; the link line was not parsed" >&2
        head -20 "$LIST" >&2
        exit 1; }

    # How QEMU links this itself (meson.build, the `execs` loop):
    #   exe_objs = lib.extract_all_objects(recursive: true)
    # i.e. every object of the emulator's libraries is linked *directly*, and
    # ld then resolves duplicate definitions by first-definition-wins across
    # the whole set. libqemuutil.a and subproject archives come in as
    # dependencies instead.
    #
    # A single archive cannot express that: ld only pulls a member when a
    # symbol is undefined, so weak stubs (stubs_iothread-lock.c) and 64-bit
    # translators (translate-a64.c) would never be reached. Flatten the QEMU
    # libraries, keep first definition of each symbol, and carry the
    # third-party archives (libqemuutil, dtc, subprojects) as members.
    QEMU_ARCHIVES="$OUT/link-archives.txt"
    THIRD_PARTY="$OUT/link-archives-thirdparty.txt"
    : > "$QEMU_ARCHIVES"; : > "$THIRD_PARTY"

    while read -r input; do
        case "$input" in
            \#*) continue ;;
            *.a|*.fa)
                case "$input" in
                    "$PREFIX"/*) continue ;;      # sysroot: the app links these
                esac
                name="$(basename "$input")"
                case "$name" in
                    libqemuutil*|libfdt*|*slirp*) echo "$OUT/$input" >> "$THIRD_PARTY" ;;
                    *)                            echo "$OUT/$input" >> "$QEMU_ARCHIVES" ;;
                esac
                ;;
        esac
    done < "$LIST"

    for extra in $(find "$OUT/subprojects" -name '*.a' 2>/dev/null); do
        echo "$extra" >> "$THIRD_PARTY"
    done
    sort -u -o "$QEMU_ARCHIVES" "$QEMU_ARCHIVES"
    sort -u -o "$THIRD_PARTY" "$THIRD_PARTY"

    echo "QEMU archives ($(wc -l < "$QEMU_ARCHIVES" | tr -d ' ')), flattened:"
    sed 's|^|  |' "$QEMU_ARCHIVES"
    echo "third-party archives kept whole:"
    sed 's|^|  |' "$THIRD_PARTY"

    # The link line already names ~1200 objects directly; that *is* meson's
    # extract_all_objects() result, and it is the only thing that matters.
    WORK="$OUT/flatten"
    rm -rf "$WORK"; mkdir -p "$WORK"
    while read -r input; do
        case "$input" in
            \#*) continue ;;
            *.o)
                cp "$OUT/$input" "$WORK/$(echo "$input" | tr '/' '_')" 2>/dev/null || true
                ;;
        esac
    done < "$LIST"

    # Anything still only reachable through a QEMU archive gets flattened too,
    # after the direct objects, so the direct ones win any duplicate.
    for archive in $(cat "$QEMU_ARCHIVES"); do
        EX="$WORK/.x"
        rm -rf "$EX"; mkdir -p "$EX"
        ( cd "$EX" && ar x "$archive" 2>/dev/null ) || continue
        find "$EX" -name '*.o' -exec mv -n {} "$WORK"/ \;
    done

    # The set legitimately contains duplicate definitions: QEMU links stubs and
    # real implementations together and lets ld pick the first (system_cpus.c
    # ships #include "stubs/iothread-lock.c" precisely so the order decides).
    # So it must stay *flat*: pass the objects to the linker directly. An
    # archive would publish the duplicates to ld's duplicate check, which is
    # what turned this into 221 errors.
    DEFS="$OUT/flatten-defs.txt"
    : > "$DEFS"
    for obj in "$WORK"/*.o; do
        xcrun nm -gU --defined-only "$obj" 2>/dev/null | awk '{print $3}' >> "$DEFS"
    done
    echo "objects: $(find "$WORK" -maxdepth 1 -name '*.o' | wc -l | tr -d ' '), symbols with duplicate definitions: $(sort "$DEFS" | uniq -d | wc -l | tr -d ' ')"

    TOTAL="$(find "$WORK" -maxdepth 1 -name '*.o' | wc -l | tr -d ' ')"
    echo "flattened $TOTAL objects"
    [ "$TOTAL" -gt 700 ] || { echo "error: only $TOTAL objects flattened" >&2; exit 1; }

    : > "$OBJECT_LIST_OUT"
    for obj in "$WORK"/*.o; do
        echo "$obj" >> "$OBJECT_LIST_OUT"
    done
    for archive in $(cat "$THIRD_PARTY"); do
        echo "$archive" >> "$OBJECT_LIST_OUT"
    done
    rm -f "$LIB"   # superseded: the flat object list is what the app links
fi
# The app links these, flat and in order (see app/project.yml).
echo "link inputs: $(wc -l < "$OBJECT_LIST_OUT" | tr -d ' ')"

banner "firmware blobs"
mkdir -p "$BUILD/firmware"
for blob in edk2-aarch64-code.fd edk2-arm-vars.fd; do
    for dir in "$OUT/pc-bios" "$SRC/pc-bios"; do
        if [ -f "$dir/$blob" ]; then
            cp "$dir/$blob" "$BUILD/firmware/$blob"; break
        elif [ -f "$dir/$blob.bz2" ]; then
            bunzip2 -kc "$dir/$blob.bz2" > "$BUILD/firmware/$blob"; break
        fi
    done
done
[ -s "$BUILD/firmware/edk2-aarch64-code.fd" ] || {
    echo "error: edk2 aarch64 firmware not found in build or source pc-bios" >&2
    ls -1 "$SRC/pc-bios" | grep -i edk2 >&2 || true
    exit 1; }
ls -lh "$BUILD/firmware" || echo "warning: edk2 blobs not found in pc-bios"

banner "stage headers for the app"
# The app must not need a 700 MB QEMU checkout to compile one C file. Copy the
# header tree plus the generated headers into a directory that can be shipped.
HDR="$BUILD/qemu-headers"
rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$SRC/include" "$HDR/include"
# Every generated header at the top of the build dir: config-host.h,
# config-poison.h (included by include/exec/poison.h), config-target.h,
# qemu-version.h and whatever else meson decides to emit.
cp "$OUT"/*.h "$HDR/" 2>/dev/null || true
if [ -d "$OUT/qapi" ]; then
    cp -R "$OUT/qapi" "$HDR/qapi"
fi
ls "$HDR" | sed 's/^/  /' 
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
