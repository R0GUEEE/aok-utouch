# Status, as of 2026-10-30

## The pipeline is green

`pipeline` run **41020168581** on `fd20c40` built every product, on
`macos-15-intel`:

| Artifact | Size | What it is |
|---|---|---|
| `AokVM-unsigned.ipa` | 124,247,279 B | The app **and the guest**: `Payload/AokVM.app/AokVM` is a 342 MB Mach-O arm64 executable with `NOUNDEFS`, next to `alpine.img.gz` (100,124,380 B) |
| `alpine.img` | 1,073,741,958 B | **The guest**: GPT, 128 MiB ESP + ext4 root, Alpine 3.24.3, 175 MB used |
| `qemu-engine` | 121,367,693 B | Flat object set + headers + edk2 blobs (~1212 objects) |
| `ios-sysroot` | 21,585,040 B | glib 2.82.2, pixman 0.43.4, pcre2 10.44, libffi 3.4.6, libslirp 4.9.1 |

The guest travels inside the app: `30-build-app.sh` gzips the image into the bundle
(1 GiB sparse → 96 MB) and `GuestImage.installIfNeeded` streams it into Application Support on
first start. Checked by taking the `.gz` out of the IPA and gunzipping it: byte-identical
sha256 to the `alpine.img` from the same run (`aad97de4ebee9821…`).

The disc image was checked locally, not just built: GPT signature `EFI PART`, partition 1
`ESP` (FAT32 magic `FAT32`), partition 2 `root` starting at 129 MiB with an ext4 superblock
(`0xEF53`), and on the ESP `vmlinuz-virt`, `initramfs-virt`, `grub/grub.cfg`,
`EFI/BOOT/BOOTAA64.EFI`.
The binary contains `qemu-system-aarch64` and `aok-engine`, and `file(1)` reports
`flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|PIE>`, so nothing is missing at load time.

## How the engine is packaged (this changed)

It is **not** a static archive. QEMU links the emulator with
`lib.extract_all_objects(recursive: true)`, and the resulting set legitimately
contains two definitions of some symbols — `system_cpus.c` includes
`stubs/iothread-lock.c`, `target/arm` ships a 32-bit stub next to the 64-bit
translator — where ld takes the first. An archive publishes each duplicate to
ld's duplicate check, which rejects them (221 errors, then 23, then 1).

So `10-build-qemu-ios.sh` now writes `build/qemu-ios/engine-link-inputs.txt`:
about 1200 objects from QEMU's own link line, minus `system/main.c` (the app has
its own `@main`), plus the third-party archives (`libqemuutil`, `libfdt`,
`libslirp`). The app passes that file as `-Wl,@...` so the objects go straight to
the linker. Tarball layout and `09-restore-engine.sh` rewrite the absolute paths
on restore.

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

* **The guest has never booted.** It is assembled from packages that exist, its filesystem
  verifies, and the loader is installed — none of which is a boot. Everything above proves the app links and
  packages; it does not prove Lomiri starts, that the kernel finds its root, or
  that the display listener gets a frame. That is M4.
* The framebuffer console needs `virtio_gpu` to load. If the screen stays black while the
  serial log in `Documents/Logs/engine.log` reaches a login prompt, that is the module to
  look for.
* Multi-touch is still absent (no touch device in this QEMU tree), so the pointer is the
  only pointing device.
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
