# CI: precompiling everything that is expensive

The build has three expensive layers and one cheap one:

| Layer | What | Cold | Warm |
|---|---|---|---|
| deps | glib, pixman, pcre2, libffi cross-built for arm64 iOS | ~15 min | 0 |
| engine | QEMU 11.1.2 + TCTI + AOK gadgets → `libqemu-system-aarch64.a` | ~45 min | 0 |
| app | Swift, one C file, one Metal shader → `.ipa` | — | ~3 min |
| image | Ubuntu 24.04 + UBports → 8 GB disk image (arm64 Linux) | ~25 min | — |

Everything above the app is content-addressed, so it is compiled once and then
restored. The app job never runs meson, never sees a QEMU checkout, and never
touches glib.

## Cache keys

`scripts/hash.sh` is the single source of truth:

```
scripts/hash.sh deps   # deps/manifest.env + cross file + 05-build-deps.sh
scripts/hash.sh qemu   # that, plus the QEMU commit + 00-fetch.sh + 10-build-qemu-ios.sh
```

Because the build scripts are hashed, changing a meson flag invalidates the
cache even though no version number moved. Because the QEMU *commit* is hashed
(not the branch name), a moving `aok-vm` tip produces a new key exactly once.

## Jobs

```
deps ──► engine ──► app
   └────────┘
image (independent, arm64 Linux)
publish (manual: attaches deps + engine tarballs to a prebuilt-* release)
```

* **deps** — `macos-15`. Restores `build/ios-sysroot` by key `ios-deps-<hash>`,
  builds, repacks, uploads the tarball as an artifact either way.
* **engine** — hashes the QEMU branch tip with `git ls-remote` (one API call, no
  clone). On a cache hit it never clones QEMU; on a miss it fetches, builds, and
  caches `libqemu-system-aarch64.a`, the staged header tree, and the edk2 blobs.
* **app** — downloads both artifacts, extracts them with
  `scripts/09-restore-engine.sh`, and runs `xcodebuild`. This is the job that
  runs on every pull request that touches Swift.
* **image** — `ubuntu-24.04-arm`, independent of macOS.

## Consuming a published prebuilt

`workflow_dispatch` with `publish_prebuilt` creates a release tagged
`prebuilt-<deps-hash>-<engine-hash>` holding both tarballs. Then, anywhere:

```sh
export TAG=prebuilt-<deps-hash>-<engine-hash>
AOK_PREBUILT_DEPS=https://github.com/OWNER/REPO/releases/download/$TAG/ios-sysroot-<deps-hash>.tar.gz \
    ./scripts/05-build-deps.sh
./scripts/09-restore-engine.sh \
    https://github.com/OWNER/REPO/releases/download/$TAG/qemu-aarch64-ios-<engine-hash>.tar.gz
./scripts/30-build-app.sh
```

That path is for forks, offline builds and anyone who wants the app without a
macOS toolchain of their own beyond Xcode. The Actions cache covers the rest.

## Building the same artefacts locally

```sh
PACK=1 ./scripts/05-build-deps.sh      # -> build/prebuilt/ios-sysroot-<hash>.tar.gz
PACK=1 ./scripts/10-build-qemu-ios.sh  # -> build/prebuilt/qemu-aarch64-ios-<hash>.tar.gz
```

Two properties the scripts enforce rather than assume:

* `10-build-qemu-ios.sh` refuses to continue unless `config-host.h` has both
  `CONFIG_TCG_THREADED_INTERPRETER` and `CONFIG_AOK_GADGETS` set. A build
  without them would map `PROT_EXEC` memory and be killed on device.
* `30-build-app.sh` refuses unless `qemu_init` is present in the linked binary,
  which is what catches a static archive that silently dropped QEMU's
  constructor-registered machines.

## What is deliberately not cached

* The Xcode `.app` bundle itself: three minutes is cheaper than the cache
  invalidation rules around derived data.
* `build/deps` (the extracted source trees): needed again only when the hash
  changes, which is exactly when the cache misses anyway.
