#!/usr/bin/env bash
# Restore prebuilt build products instead of compiling them.
#
#   ./scripts/09-restore-engine.sh <url-or-path>        # engine tarball
#   AOK_PREBUILT_DEPS=<url-or-path> ./scripts/05-build-deps.sh
#
# This is what CI calls when a published artefact matches the current hash, so
# a pull request that touches only Swift rebuilds in minutes instead of an hour.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-}"
TARBALL="${ROOT}/build/prebuilt/engine.tar.gz"

banner() { printf '\n== %s\n' "$*"; }

[ -n "$SRC" ] || { echo "usage: $0 <url-or-path>" >&2; exit 2; }

banner "fetch"
mkdir -p "$(dirname "$TARBALL")"
if [[ "$SRC" == http* ]]; then
    curl -fL --retry 3 -o "$TARBALL" "$SRC"
else
    cp "$SRC" "$TARBALL"
fi
echo "$(du -h "$TARBALL" | cut -f1) from $SRC"

banner "extract"
tar -xzf "$TARBALL" -C "${ROOT}/build"
COUNT_WANT="$(wc -l < "${ROOT}/build/qemu-ios/engine-link-inputs.txt" 2>/dev/null | tr -d ' ')"
COUNT_HAVE="$(find "${ROOT}/build/qemu-ios/flatten" -name '*.o' 2>/dev/null | wc -l | tr -d ' ')"
echo "link inputs listed: ${COUNT_WANT:-none}, objects present: ${COUNT_HAVE:-0}"
[ "${COUNT_HAVE:-0}" -gt 700 ] || {
    echo "error: tarball has no flat engine objects" >&2; exit 1; }
# The list holds absolute paths from whichever machine built it. Rebuild every
# entry against this checkout: objects live in flatten/, archives either in
# build/qemu-ios/ or in support-archives/.
LIST="${ROOT}/build/qemu-ios/engine-link-inputs.txt"
if [ -f "$LIST" ]; then
    python3 - "$LIST" "${ROOT}/build/qemu-ios" <<'PY'
import os, sys
list_path, base = sys.argv[1], sys.argv[2]
out = []
seen_objects = set()
for line in open(list_path):
    entry = line.strip()
    if not entry or entry.startswith("#"):
        continue
    name = os.path.basename(entry)
    if entry.endswith(".o"):
        path = os.path.join(base, "flatten", name)
        if path in seen_objects:
            continue
        seen_objects.add(path)
        out.append(path)
    elif os.path.isfile(os.path.join(base, name)):
        out.append(os.path.join(base, name))
    elif os.path.isfile(os.path.join(base, "support-archives", name)):
        out.append(os.path.join(base, "support-archives", name))
    else:
        print(f"warning: cannot locate {name}", file=sys.stderr)
        out.append(entry)
with open(list_path, "w") as handle:
    handle.write("\n".join(out) + "\n")
print(f"rewrote {len(out)} link inputs")
PY
fi
MISSING=0
for archive in $(grep '\.a$' "$LIST" 2>/dev/null); do
    if [ ! -f "$archive" ]; then
        # Paths are absolute from the machine that built the tarball; resolve
        # the basename against the support-archives directory instead.
        alt="${ROOT}/build/qemu-ios/support-archives/$(basename "$archive")"
        [ -f "$alt" ] || { echo "error: missing archive $archive" >&2; MISSING=1; }
    fi
done
[ "$MISSING" = 0 ] || exit 1
[ -d "${ROOT}/build/qemu-headers/include" ] || {
    echo "error: tarball has no qemu-headers/include" >&2; exit 1; }

banner "verify"
cat "${ROOT}/build/qemu-ios/BUILDINFO" 2>/dev/null || echo "(no BUILDINFO in tarball)"
HAVE="$(sed -n 's/^hash=//p' "${ROOT}/build/qemu-ios/BUILDINFO" 2>/dev/null || true)"
if [ -d "${ROOT}/src/qemu/.git" ]; then
    WANT="$(bash "${ROOT}/scripts/hash.sh" qemu)"
    if [ "$WANT" = "$HAVE" ]; then
        echo "hash matches the current checkout: $WANT"
    else
        echo "warning: artefact ${HAVE:-none} != checkout ${WANT}" >&2
    fi
fi
