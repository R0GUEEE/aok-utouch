# aok-utouch

A Linux VM backend for iOS built from three projects, running a pre-configured Alpine
rootfs inside the app.

| Piece | Repo | Role |
|---|---|---|
| Engine | [`emkey1/qemu`](https://github.com/emkey1/qemu) branch `aok-vm` (QEMU 11.1.2) | Full-system emulation with no runtime code generation: AOK gadget streams on top of the TCTI TCG backend |
| Gadget sources | [`emkey1/aok-gadgets`](https://github.com/emkey1/aok-gadgets) | AArch64 gadget bodies, fused-pair tables, x87; retired 2026-10-14, copies now live in the engine |
| Userland runtime | [`rcarmo/ios-linuxkit`](https://github.com/rcarmo/ios-linuxkit) | AArch64 Linux syscall layer + `fakefsify`; on-device shell and build/test host |
| Guest | Alpine Linux 3.24 (aarch64), pre-configured | The operating system you get when the VM starts |

## Why this combination works

iOS forbids mapping memory `PROT_EXEC` outside WebKit. Every normal emulator — QEMU's TCG,
Dolphin, FEX — dies on that. This engine never asks: `--enable-tcg-threaded-interpreter`
makes the TCG code buffer *data* (the tree says so at `tcg/region.c:1951`), and
`--enable-aok-gadgets` emits guest instructions as 64-bit words — a gadget address then its
operands — into that data buffer. Execution is `ldr x27,[x28],#8; br x27`: one guest
instruction per gadget, no JIT, no RWX, no entitlements.

Measured by the engine's own docs (`docs/devel/aok-gadgets.rst`): AOK streams take **1.7–3.7×
fewer host cycles than TCTI** on an M5 Max, **1.5–3.7×** on an iPad M4 and **1.4–4.4×** on an
A10X. That is the performance budget this app lives inside.

## Layout

```
docs/ARCHITECTURE.md      layers, boot path, the constraints that shape both
docs/UBUNTU-TOUCH.md      how UT runs on virtio hardware without Halium
docs/PLAN.md              milestones with exit gates
docs/CI.md                the pipeline, its cache keys, prebuilt releases
deps/manifest.env         versions of the four cross-compiled libraries
cross/aarch64-ios.txt.in  meson cross file template for iPhoneOS arm64
scripts/hash.sh           content hashes = cache keys for deps and engine
scripts/00-fetch.sh       clone + pin the three repos, install the glue
scripts/05-build-deps.sh  pixman, pcre2, libffi, glib - static, for iPhoneOS
scripts/09-restore-engine.sh   unpack a prebuilt engine instead of building it
scripts/10-build-qemu-ios.sh   configure + build libqemu-system-aarch64.a
scripts/20-make-alpine-image.sh  Alpine 3.24 aarch64 -> GPT disk image (arm64 Linux host)
scripts/30-build-app.sh   XcodeGen + xcodebuild -> unsigned .ipa
engine/aok-ios/           iOS platform layer: display listener, input bridge, VM thread
app/AokVM/                SwiftUI app, Metal scanout, host keyboard, VM settings
.github/workflows/pipeline.yml  deps -> engine -> app, plus image and publish
```

## Build

Needs macOS with Xcode 16+ (the only host that can link the iOS app), plus an arm64 Linux
host or VM for the guest image.

```sh
./scripts/00-fetch.sh                      # ~2.5 GB: QEMU + UT packages
./scripts/05-build-deps.sh                 # glib, pixman, pcre2, libffi -> build/ios-sysroot
./scripts/10-build-qemu-ios.sh             # -> build/qemu-ios/libqemu-system-aarch64.a
sudo ./scripts/20-make-alpine-image.sh     # -> build/guest/alpine.img (~1 GB sparse, ~300 MB used)
./scripts/30-build-app.sh                  # -> dist/AokVM-unsigned.ipa
```

Nothing above the app has to be rebuilt twice. Both toolchain layers are
content-addressed and packable:

```sh
make prebuilt        # -> build/prebuilt/ios-sysroot-<hash>.tar.gz
                     #    build/prebuilt/qemu-aarch64-ios-<hash>.tar.gz
make restore DEPS_URL=... ENGINE_URL=...    # the other direction
```

## CI

`.github/workflows/pipeline.yml` builds the same three products on GitHub
Actions with three separate cache keys derived from `scripts/hash.sh`, so the
app job — the one that runs on every Swift change — never compiles glib, never
clones QEMU and finishes in minutes. `workflow_dispatch` with
`publish_prebuilt` attaches both tarballs to a `prebuilt-<hash>` release for
forks and offline builds. Details in [docs/CI.md](docs/CI.md).

Install the .ipa with SideStore/AltStore/TrollStore. **The guest is inside it**: the build
gzips `alpine.img` into the bundle (~100 MB of the ~145 MB IPA) and the app unpacks it into
Application Support on the first start, with a progress bar. There is nothing to import.

The guest boots to a login prompt on tty1 (the displayed framebuffer) and on ttyAMA0, whose
output lands in `Documents/Logs/engine.log`. Root password `aok`. Importing a different image
through the Files importer still works, and replaces the bundled one until you reset.

## State

The pipeline is green: run 41010497241 built `AokVM-unsigned.ipa` (25.5 MB, 342 MB binary,
`NOUNDEFS`), the prebuilt engine, the iOS dependency sysroot and the 8.6 GB Ubuntu Touch image,
all as downloadable artifacts. See [docs/STATUS.md](docs/STATUS.md) for sizes, hashes and what
that does and does not prove.

It proves the app links and packages. It does not prove the guest boots — the first launch on a
device is still unwritten.
