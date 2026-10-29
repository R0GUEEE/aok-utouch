# Status, as of 2026-10-29

## Verified by reading the sources (not assumed)

| Fact | Where |
|---|---|
| QEMU fork is 11.1.2; branches `aok-vm`, `tctish-edition` | `VERSION`, branches API |
| TCTI backend for AArch64 hosts, one gadget per TCG op | `tcg/aarch64-tcti/`, `meson_options.txt:102` |
| AOK gadgets: one gadget per guest instruction, AArch64 host, system emulation | `meson_options.txt:104`, `docs/devel/aok-gadgets.rst` |
| AOK streams are ordinary TBs; faults/MMIO/devices stay QEMU's | `docs/devel/aok-gadgets.rst` |
| Measured 1.7–3.7× fewer cycles than TCTI (M5 Max), 1.5–3.7× (iPad M4), 1.4–4.4× (A10X) | same doc |
| Code buffer is data-only under `CONFIG_TCG_THREADED_INTERPRETER` | `tcg/region.c:1951` and the `#if !defined(CONFIG_TCG_INTERPRETER) && !defined(CONFIG_TCG_THREADED_INTERPRETER)` guards |
| `--enable-aok-gadgets` errors unless the host is aarch64 | `meson.build:2562` |
| virtio-ramfb (UTM's device) exists in this tree | `hw/display/virtio-ramfb.c`, `.name = "virtio-ramfb"` |
| No multi-touch HID device in this tree | `hw/input/*` listing: no `usb-multitouch`, no `virtio-multitouch` |
| Display listener API is `qemu_console_register_listener` + `qemu_console_hw_update` | `include/ui/console.h`, `ui/console.c:631` |
| Input API is one `QemuInputEvent` struct | `include/ui/input.h` |
| UT 24.04 archive is live, arm64, updated 2026-10-27 | `repo.ubports.com/dists/24.04-1.x/Release` |
| `lomiri`, `lomiri-system-compositor`, `qml-module-lomiri-components`, `ubuntu-touch-session`, `ubuntu-touch-core-mainline` all present | `Contents-arm64` from that suite |
| `ubuntu-touch-hybris` exists and is *not* needed on virtio hardware | same index |

| CI pipeline exists (deps → engine → app → image → publish) | `.github/workflows/pipeline.yml`, YAML-validated locally |
| Hashes are stable and content-derived | `scripts/hash.sh deps/qemu` |

## Not verified

* Nothing has been compiled: this machine is an Alpine/iSH sandbox without Xcode.
* The workflow has never run on GitHub. It is YAML-valid and every script it
  calls passes `bash -n`, but the first real run will find things — the usual
  candidates are glib's cross-build options and macOS runner image drift.
* QEMU's configure has not been run against `cross/aarch64-ios.txt`; glib's
  cross-build is the likeliest failure point (risk R1 in `PLAN.md`).
* `virtio-ramfb,xres=…,yres=…` is assumed to inherit virtio-gpu-base's
  properties. If it does not, drop the two properties and use the kernel
  `video=` parameter (already in the image's GRUB command line).
* Lomiri's first start on a greeter-less mainline session. `ubuntu-touch-session`
  ships units that expect a greeter; `aok-lomiri.service` bypasses them. If the
  shell starts but apps do not, the next thing to look at is `lomiri-app-launch`
  and the `phablet` user's `$XDG_RUNTIME_DIR`.
