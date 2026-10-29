#!/usr/bin/env bash
# Build the four libraries QEMU cannot be built without: static, for
# arm64-apple-ios${IOS_MIN}. Or restore them from a prebuilt tarball.
#
#   pixman  - scanout surfaces
#   pcre2   - glib's GRegex (glib refuses to build without it)
#   libffi  - GObject closures
#   glib    - QEMU's entire object model
#
# Usage:
#   ./scripts/05-build-deps.sh                      # build (or reuse stamp)
#   AOK_PREBUILT_DEPS=url-or-path ./scripts/05-build-deps.sh
#   PACK=1 ./scripts/05-build-deps.sh               # also emit the tarball
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deps/manifest.env
. "${ROOT}/deps/manifest.env"

PREFIX="${ROOT}/build/ios-sysroot"
DEPS="${ROOT}/build/deps"
PREBUILT_DIR="${ROOT}/build/prebuilt"
HASH="$("${ROOT}/scripts/hash.sh" deps)"
STAMP="${PREFIX}/.aok-deps-${HASH}"
TARBALL="${PREBUILT_DIR}/ios-sysroot-${HASH}.tar.gz"

banner() { printf '\n== %s\n' "$*"; }
mkdir -p "$PREFIX" "$DEPS" "$PREBUILT_DIR"

if [ -f "$STAMP" ]; then
    banner "deps ${HASH} already present"
    if [ "${PACK:-0}" = "1" ]; then
        tar -czf "$TARBALL" -C "${ROOT}/build" ios-sysroot
        ls -lh "$TARBALL"
    fi
    exit 0
fi

if [ -n "${AOK_PREBUILT_DEPS:-}" ]; then
    banner "restoring prebuilt deps ${HASH}"
    src="$AOK_PREBUILT_DEPS"
    if [[ "$src" == http* ]]; then
        curl -fL --retry 3 -o "${TARBALL}.download" "$src"
        src="${TARBALL}.download"
    fi
    rm -rf "$PREFIX"; mkdir -p "$PREFIX"
    tar -xzf "$src" -C "${ROOT}/build"
    if [ -f "$STAMP" ]; then
        echo "restored $(du -sh "$PREFIX" | cut -f1) into build/ios-sysroot"
        exit 0
    fi
    echo "warning: prebuilt tarball does not carry stamp ${HASH}; rebuilding" >&2
fi

CROSS="$("${ROOT}/scripts/04-cross-file.sh")"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "cross file: $CROSS"

export PKG_CONFIG_LIBDIR="${PREFIX}/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export PATH="${PREFIX}/bin:${PATH}"

fetch() { # fetch <dir-name> <url> <tarball>
    local name="$1" url="$2" tar="$3"
    if [ ! -d "$DEPS/$name" ]; then
        ( cd "$DEPS" && curl -fL --retry 3 -o "$tar" "$url" && tar xf "$tar" )
        local first
        first="$(tar tf "$DEPS/$tar" | head -1 | cut -d/ -f1)"
        [ "$first" = "$name" ] || mv "$DEPS/$first" "$DEPS/$name"
        rm -f "$DEPS/$tar"
    fi
}

banner "pixman ${PIXMAN_VERSION}"
fetch "pixman-${PIXMAN_VERSION}" \
  "https://cairographics.org/releases/pixman-${PIXMAN_VERSION}.tar.gz" pixman.tar.gz
meson setup "${DEPS}/pixman-build" "${DEPS}/pixman-${PIXMAN_VERSION}" \
    --cross-file "$CROSS" --prefix "$PREFIX" --buildtype release --default-library static \
    -Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled
ninja -C "${DEPS}/pixman-build" install

banner "pcre2 ${PCRE2_VERSION}"
fetch "pcre2-${PCRE2_VERSION}" \
  "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz" pcre2.tar.gz
CC="xcrun --sdk iphoneos clang -arch arm64 -isysroot ${SDKROOT} -miphoneos-version-min=${IOS_MIN}" \
    "${DEPS}/pcre2-${PCRE2_VERSION}/configure" \
    --host=aarch64-apple-darwin --prefix="$PREFIX" \
    --disable-shared --enable-static --with-pic \
    --disable-pcre2grep --disable-pcre2test --disable-pcre2grep-libz
make -C "${DEPS}/pcre2-${PCRE2_VERSION}" -j"$(sysctl -n hw.ncpu)" install

banner "libffi ${LIBFFI_VERSION}"
fetch "libffi-${LIBFFI_VERSION}" \
  "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz" libffi.tar.gz
CC="xcrun --sdk iphoneos clang -arch arm64 -isysroot ${SDKROOT} -miphoneos-version-min=${IOS_MIN}" \
    "${DEPS}/libffi-${LIBFFI_VERSION}/configure" \
    --host=aarch64-apple-darwin --prefix="$PREFIX" \
    --disable-shared --enable-static --with-pic
make -C "${DEPS}/libffi-${LIBFFI_VERSION}" -j"$(sysctl -n hw.ncpu)" install

banner "glib ${GLIB_VERSION}"
GLIB_SERIES="${GLIB_VERSION%.*}"
fetch "glib-${GLIB_VERSION}" \
  "https://download.gnome.org/sources/glib/${GLIB_SERIES}/glib-${GLIB_VERSION}.tar.xz" glib.tar.xz
meson setup "${DEPS}/glib-build" "${DEPS}/glib-${GLIB_VERSION}" \
    --cross-file "$CROSS" --prefix "$PREFIX" --buildtype release --default-library static \
    -Dintrospection=disabled -Dtests=false -Dglib_debug=disabled \
    -Dlibmount=disabled -Dselinux=disabled -Dxattr=false \
    -Dman-pages=disabled -Ddocumentation=false -Dbsymbolic_functions=false
ninja -C "${DEPS}/glib-build" install

banner "stamp"
date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP"
echo "$HASH" >> "$STAMP"

if [ "${PACK:-0}" = "1" ]; then
    banner "pack"
    # Only the sysroot: build trees live in build/deps and are reproducible.
    tar -czf "$TARBALL" -C "${ROOT}/build" ios-sysroot
    ls -lh "$TARBALL"
fi

banner "summary"
ls "$PREFIX/lib" | head -40
echo
echo "If glib rejected an option: meson configure ${DEPS}/glib-build | grep -i <name>"
