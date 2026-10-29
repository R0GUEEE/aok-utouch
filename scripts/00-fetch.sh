#!/usr/bin/env bash
# Clone and pin the three upstream projects, then apply the two edits the iOS
# link needs. Idempotent: re-running fast-forwards the branches it owns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/src"
QEMU_BRANCH="${QEMU_BRANCH:-aok-vm}"
QEMU_URL="${QEMU_URL:-https://github.com/emkey1/qemu.git}"

banner() { printf '\n== %s\n' "$*"; }

mkdir -p "$SRC"

banner "qemu (${QEMU_BRANCH})"
if [ ! -d "$SRC/qemu/.git" ]; then
    # Shallow: this repo is ~700 MB of history we do not need. Submodules are
    # not shallow-able in one pass, hence the second command.
    git clone --depth 1 --branch "$QEMU_BRANCH" "$QEMU_URL" "$SRC/qemu"
    git -C "$SRC/qemu" submodule update --init --recursive --depth 1
else
    git -C "$SRC/qemu" fetch --depth 1 origin "$QEMU_BRANCH"
    git -C "$SRC/qemu" checkout -q FETCH_HEAD
fi

banner "aok-gadgets"
if [ ! -d "$SRC/aok-gadgets/.git" ]; then
    git clone --depth 1 https://github.com/emkey1/aok-gadgets.git "$SRC/aok-gadgets"
else
    git -C "$SRC/aok-gadgets" pull --ff-only -q || true
fi
# The README says it is retired and its bodies now live in each engine; keep the
# checkout only for tools/check.sh and for provenance in the SBOM.
( cd "$SRC/aok-gadgets" && ./tools/check.sh ) || {
    echo "warning: aok-gadgets contract check failed; continuing" >&2
}

banner "ios-linuxkit (second runtime + fakefs tooling)"
if [ ! -d "$SRC/ios-linuxkit/.git" ]; then
    git clone --depth 1 --recurse-submodules https://github.com/rcarmo/ios-linuxkit.git \
        "$SRC/ios-linuxkit"
else
    git -C "$SRC/ios-linuxkit" pull --ff-only -q || true
fi

banner "engine edits"
# 1. QEMU's system emulator has its own main(). Linking a static library that
#    defines main into an app whose entry point is @main in Swift is a duplicate
#    symbol, so rename it. We never call the renamed symbol: qemu_init() and
#    qemu_main_loop() are what the app drives.
VLCM="$SRC/qemu/system/vl.c"
if grep -q '^int main(int argc, char \*\*argv)' "$VLCM"; then
    python3 - "$VLCM" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("int main(int argc, char **argv)",
              "int qemu_system_main(int argc, char **argv)", 1)
open(p, "w").write(s)
print("renamed main() -> qemu_system_main() in system/vl.c")
PY
else
    echo "system/vl.c: main() already renamed (or upstream changed it)"
    grep -n 'qemu_system_main' "$VLCM" | head -3 || true
fi

# 2. QEMU insists on a writable executable code buffer for the native backend.
#    With TCTI/AOK it never executes from it, but the mmap flags are chosen at
#    build time; assert the guards we rely on are present so a future upstream
#    change fails loudly here instead of at runtime on device.
if ! grep -q 'CONFIG_TCG_THREADED_INTERPRETER' "$SRC/qemu/tcg/region.c"; then
    echo "error: tcg/region.c no longer guards the RWX path on" >&2
    echo "       CONFIG_TCG_THREADED_INTERPRETER; the iOS build would map" >&2
    echo "       PROT_EXEC memory and be rejected by the kernel." >&2
    exit 1
fi

banner "pins"
{
    echo "qemu_branch=$QEMU_BRANCH"
    echo "qemu_commit=$(git -C "$SRC/qemu" rev-parse HEAD)"
    echo "aok_gadgets_commit=$(git -C "$SRC/aok-gadgets" rev-parse HEAD)"
    echo "ios_linuxkit_commit=$(git -C "$SRC/ios-linuxkit" rev-parse HEAD)"
    echo "fetched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "${ROOT}/versions.env"

banner "done"
echo "sources in $SRC"
