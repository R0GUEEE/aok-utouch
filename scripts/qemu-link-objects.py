#!/usr/bin/env python3
"""Print the object files and archives that QEMU's final link actually used.

QEMU 11 does not leave a per-target static archive behind: the emulator is
linked straight from ~2000 objects that Meson keeps in a private directory whose
name is an implementation detail. Rather than guess that name, ask ninja for the
link command it would run and read the object list out of it.

    scripts/qemu-link-objects.py <build-dir> [ninja-target]

Prints one path per line, relative to the build directory. Exits 1 with a
message if the link line cannot be found.
"""
import os
import shlex
import subprocess
import sys


def ninja_commands(build_dir, target):
    try:
        out = subprocess.run(["ninja", "-C", build_dir, "-t", "commands", target],
                             check=True, capture_output=True, text=True).stdout
    except FileNotFoundError:
        sys.exit("ninja not found")
    except subprocess.CalledProcessError as exc:
        sys.exit(f"ninja -t commands failed: {exc.stderr.strip()[:300]}")
    return out.splitlines()


def find_link_line(lines, target):
    for line in reversed(lines):
        tokens = line.split()
        for i, token in enumerate(tokens):
            if token == "-o" and i + 1 < len(tokens) and tokens[i + 1].endswith(target):
                return line
    return None


def expand(tokens, build_dir):
    """Follow @response-files; return all tokens."""
    out = []
    for token in tokens:
        if token.startswith("@") and token.endswith(".rsp"):
            path = token[1:] if os.path.isabs(token[1:]) else os.path.join(build_dir, token[1:])
            try:
                with open(path, encoding="utf-8") as handle:
                    out.extend(handle.read().split())
                continue
            except OSError:
                pass
        out.append(token)
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    build_dir = os.path.abspath(sys.argv[1])
    target = sys.argv[2] if len(sys.argv) > 2 else "qemu-system-aarch64-unsigned"

    line = find_link_line(ninja_commands(build_dir, target), target)
    if line is None:
        sys.exit(f"no link command for {target} in {build_dir}/build.ninja "
                 f"(is the build complete?)")

    tokens = expand(shlex.split(line), build_dir)

    # Dependencies can arrive as `-L<dir> -l<name>` rather than as a path
    # (libslirp does, which is how the first app link ended up without slirp).
    libdirs, libnames = [], []
    i = 0
    while i < len(tokens):
        token = tokens[i]
        if token == "-L" and i + 1 < len(tokens):
            libdirs.append(tokens[i + 1])
            i += 2
            continue
        if token.startswith("-L") and len(token) > 2:
            libdirs.append(token[2:])
        elif token == "-l" and i + 1 < len(tokens):
            libnames.append(tokens[i + 1])
            i += 2
            continue
        elif token.startswith("-l") and len(token) > 2:
            libnames.append(token[2:])
        i += 1

    objects, archives = [], []
    for token in tokens:
        if token.startswith("-"):
            continue
        if token.endswith(".o"):
            objects.append(token)
        elif token.endswith((".a", ".fa")):
            archives.append(token)

    for name in libnames:
        for libdir in libdirs:
            for suffix in (".a", ".fa"):
                candidate = os.path.join(libdir, f"lib{name}{suffix}")
                if os.path.exists(candidate if os.path.isabs(candidate)
                                  else os.path.join(build_dir, candidate)):
                    archives.append(candidate)
                    break

    if not objects and not archives:
        sys.exit("link command has no objects; refusing to build an empty library")

    for path in objects + archives:
        print(path)
    print(f"# {len(objects)} objects, {len(archives)} archives", file=sys.stderr)


if __name__ == "__main__":
    main()
