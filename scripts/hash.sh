#!/usr/bin/env bash
# Content hashes used as cache keys. Changing a version, a meson flag, a source
# pin or one of the build scripts changes the hash, so a stale artefact can
# never be mistaken for a current one.
#
#   scripts/hash.sh deps   -> hash of everything scripts/05-build-deps.sh consumes
#   scripts/hash.sh qemu   -> hash of the engine build inputs (needs a checkout)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

deps_hash() {
    {
        cat deps/manifest.env
        cat cross/aarch64-ios.txt.in
        cat scripts/04-cross-file.sh
        cat scripts/05-build-deps.sh
    } | sha | cut -c1-16
}

qemu_hash() {
    local commit="${AOK_QEMU_COMMIT:-unknown}"
    if [ "$commit" = "unknown" ] && [ -d src/qemu/.git ]; then
        commit="$(git -C src/qemu rev-parse HEAD)"
    elif [ "$commit" = "unknown" ] && [ -f versions.env ]; then
        commit="$(sed -n 's/^qemu_commit=//p' versions.env)"
    fi
    {
        echo "qemu=$commit"
        cat deps/manifest.env
        cat cross/aarch64-ios.txt.in
        # The flag set lives in this script, so hashing it hashes the flags.
        cat scripts/04-cross-file.sh scripts/00-fetch.sh scripts/10-build-qemu-ios.sh
    } | sha | cut -c1-16
}

case "${1:-}" in
    deps) deps_hash ;;
    qemu) qemu_hash ;;
    *) echo "usage: $0 deps|qemu" >&2; exit 2 ;;
esac
