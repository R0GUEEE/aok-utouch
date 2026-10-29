# Plan

Milestones are ordered by what unblocks the next step, and each has an exit gate that is a
thing you can look at, not a feeling. Status marks what exists in this tree today.

## M0 — Engine links and shows pixels — *code written, unbuilt*

* `scripts/05-build-deps.sh` builds glib + pixman static for `arm64-apple-ios16.0`.
* `scripts/10-build-qemu-ios.sh` configures `aarch64-softmmu` with
  `--enable-aok-gadgets --enable-tcg-threaded-interpreter`, no SDL/GTK/OpenGL/virgl.
* `engine/aok-ios/` supplies `qemu_init`/`qemu_main_loop` ownership, the
  `DisplayChangeListener`, and the input bridge.
* `app/AokVM` renders the framebuffer through Metal.

**Gate:** app launches on device, edk2 prints to the screen, `Instruments` shows no
`PROT_EXEC` mapping, and the VM pauses/resumes on scene phase changes without leaking a thread.

## M1 — A Linux guest boots — *scripts written, unbuilt*

* Disk image with ESP + root; edk2 -> GRUB -> Ubuntu 24.04 arm64 -> console.
* `-netdev user` DHCP; `apt` inside the guest reaches the network through slirp.
* Serial console mirrored to the app's log view.

**Gate:** `uname -a` in the guest console; `ping`/`apt update` succeed; 60 s cold boot to
login prompt at 1024x768.

## M2 — Ubuntu Touch userland — *package selection verified*

* `20-make-ut-image.sh --ut` adds `repo.ubports.com 24.04-1.x main` and installs the
  mainline session set from `UBUNTU-TOUCH.md`.
* `aok-lomiri.service` starts the session as `phablet` on tty1, no LightDM.

**Gate:** `systemctl status aok-lomiri` active; `journalctl -u aok-lomiri` shows Mir opening
`/dev/dri/card0`; no libhybris/Android dependency present (`apt-mark showmanual | grep -c hybris`
= 0).

## M3 — Lomiri on screen and interactive — *unbuilt*

* Mir `gbm-kms` scanout reaches our listener; the shell's greeter-free home renders.
* `virtio-tablet` drives the pointer; keyboard shortcuts reach the shell.
* `virtio-ramfb` hands the console to virtio-gpu cleanly at driver load.

**Gate:** launcher grid visible, app opens and closes, text entry works, screen rotates with
the device orientation (we rotate the Metal quad, not the guest).

## M4 — Performance decision — *unbuilt*

Deterministic benchmark: scroll the Lomiri app drawer for 30 s while sampling
`dpy_gfx_update` rect area/second and host frame time; record fps, p95 frame time, guest
CPU %, device temperature delta, and battery drop per 10 min.

**Gate:** >= 15 fps at 1280x720 on M1 or newer, else the escalation ladder in
`UBUNTU-TOUCH.md` §4 is applied and re-measured until it is. This milestone decides whether
the product ships at 720p, 600p or 540p.

## M5 — Touch, not pointer — *unbuilt*

This tree has no multi-touch device: `hw/input/` offers `virtio-input-hid` (kbd/mouse/tablet)
and USB HID, but no `usb-multitouch`, and no `virtio-multitouch`.

* Port UTM's `usb-multitouch` (or write `hw/input/virtio-multitouch.c`), 10 slots,
  `INPUT_EVENT_KIND_MTT`.
* Map UIKit multi-touch gestures to it; keep one-finger drag as pointer for desktop apps.

**Gate:** pinch-zoom in the browser, swipe between apps, long-press context menu — all
through the touch device, `evtest` in the guest confirming slot events.

## M6 — Product surface — *partially written*

* VM list with import/export of images through `UIDocumentPicker`, disk size checks against
  free space, boot args editor, console log viewer, "reset to snapshot".
* Pause on background, resume with a 2 s grace, watchdog that stops the engine if
  `qemu_main_loop` stops consuming bottom halves.
* Clipboard bridge via qemu-ga over virtio-serial, shared folder via `virtio-9p` (see risk R3).

**Gate:** a friend can install the IPA, import an image, boot, use the shell, and quit
without reading a README.

## M7 — Ship — *unbuilt*

* Signed development IPA artefacts, reproducible QEMU tarball, image digest in the README.
* `ios-linuxkit` second-runtime target: an in-app AArch64 shell for recovery when the VM
  image is broken (this is where `rcarmo/ios-linuxkit` earns its place in the binary).

## Risks

| # | Risk | Likelihood | Mitigation |
|---|---|---|---|
| R1 | glib cross-build for iOS is the classic wall (gobject introspection, `iconv`, `libintl`) | High | Script builds glib with `-Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled`; fall back to UTM's prebuilt `glib-ios` |
| R2 | llvmpipe in guest makes Lomiri unusable (see M4) | Medium | Resolution ladder, software Qt Quick backend, Mir software renderer |
| R3 | `virtio-9p` local backend needs xattr/`ftw` that iOS lacks | Medium | Drop 9p; use a second virtio-blk disk (FAT32) as the share — no host path sharing at all |
| R4 | App Store review rejects an emulator that boots a full OS | Certain | Unsigned IPA distribution only; no Store build target |
| R5 | Two vCPUs under TCTI/AOK thrash (`tb_flush`, region locks) | Medium | `-smp 1` default, tune at M4 |
| R6 | edk2 pflash vars file is read-only on iOS when bundled in the app | Low | Copy `edk2-arm-vars.fd` into Documents on first run and point `-drive` at the copy |
