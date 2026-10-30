# Architecture

## 1. The three layers

```
+----------------------------------------------------------------------+
| AokVM.app  (SwiftUI, iOS 16+)                                        |
|   ContentView -- VMRuntime -- ScanoutView (Metal, IOSurface)         |
|                     |            ^ dirty rects                       |
|                     v            |                                   |
|   engine/aok-ios: aok_ios_start / aok_ios_key / aok_ios_pointer      |
|   DisplayChangeListener -- qemu_console_register_listener            |
+----------------------------------------------------------------------+
| libqemu-system-aarch64.a   (emkey1/qemu @ aok-vm, QEMU 11.1.2)       |
|   TCG with TCTI backend + AOK gadget front end (target/arm/tcg/aok)  |
|   softmmu TLB, MMIO, virtio, slirp, edk2 pflash                      |
+----------------------------------------------------------------------+
| Alpine Linux 3.24 aarch64 guest (pre-configured, OpenRC)             |
|   kernel 6.18-virt, virtio-blk/gpu/net, busybox + apk, root password |
|   `aok`; console on tty1 (framebuffer) and ttyAMA0 (serial)          |
+----------------------------------------------------------------------+
```

`rcarmo/ios-linuxkit` is not in the boot path. It is the second runtime we ship: an AArch64
Linux userland for the in-app shell and the on-device build/test loop, and the reference
implementation for anything the engine stubs out (syscall surface, fakefs images, the AdvSIMD
correctness suites). Both engines descend from iSH; keeping them separate keeps the VM honest.

## 2. Why no JIT, and what replaces it

iOS denies `mmap(PROT_EXEC)` to third-party apps (WebKit and `dynamic-codesigning`-entitled
MDM apps aside). QEMU's normal TCG allocates an RWX code buffer in `tcg/region.c`; the fork
guards those paths with

```c
#if !defined(CONFIG_TCG_INTERPRETER) && !defined(CONFIG_TCG_THREADED_INTERPRETER)
```

so with the threaded interpreter enabled the buffer is plain writable memory. Two dispatch
strategies write into it:

* **TCTI** (`tcg/aarch64-tcti/`) — one precompiled gadget per *TCG op*. Guest state lives in
  `env`, gadgets are selected by operand shape (16 gadgets per one-operand op, 4096 per
  three-operand op), the stream is `[gadget][operands]...`, and every gadget ends with
  `ldr x27,[x28],#8; br x27`. This is the correctness floor: everything QEMU translates runs.
* **AOK gadgets** (`target/arm/tcg/aok/`, `accel/tcg/aok.c`) — one gadget per *guest
  instruction*, emitted by a translator that stops in front of anything it is not sure of.
  AOK streams are ordinary `TranslationBlock`s: found by `tb_lookup`, linked by `tb_add_jump`,
  invalidated by `tb_phys_invalidate`. Page walks, faults, MMIO, watchpoints, interrupts and
  devices stay QEMU's. Fused pairs (`shared/pairs.h`, generated `host-gadgets.h`) collapse two
  instructions into one gadget and drop the dispatch between them.

Configure both: a guest runs with AOK streams where a front end covers the instruction and
falls back to TCTI everywhere else. TCTI is the backend; AOK sits in front of it.

## 3. Boot path

```
aok_ios_start(argv)                     engine thread (NSThread, QoS userInteractive)
  +- qemu_init(argc, argv)              machine, devices, RAM, pflash firmware
  +- register DisplayChangeListener     console 0, ops from aok_ios_display
  +- qemu_main_loop()                   blocks until qemu_cleanup()
```

Command line the app builds (one string per element, no shell):

```
-M virt,highmem=on -cpu max -smp 2 -m 3072
-drive if=pflash,format=raw,readonly=on,file=edk2-aarch64-code.fd
-drive if=pflash,format=raw,file=edk2-arm-vars.fd
-device virtio-ramfb                 # firmware console, then virtio-gpu scanout
-drive if=none,id=hd0,file=<Application Support>/AokVM/guest.img,format=raw,cache=writeback
-device virtio-blk-pci,drive=hd0
-netdev user,id=n0 -device virtio-net-pci,netdev=n0
-device virtio-keyboard-pci
-device virtio-tablet-pci            # absolute pointer; touch device is M5
-display none -nodefaults -no-user-config
```

`virtio-ramfb` is UTM's device, present in this fork at `hw/display/virtio-ramfb.c`: edk2
draws on the ramfb before the guest's virtio-gpu driver takes the console over, so firmware
output and the Linux console arrive through the same listener.

Disk layout produced by `20-make-alpine-image.sh`:

```
p1  128 MiB  EFI System (FAT32)  grub arm64-efi, vmlinuz-virt, initramfs-virt, grub.cfg
p2  rest     ext4                Alpine 3.24 + apk + OpenRC, ~300 MB used
```

The guest is prepared, not assembled at runtime: hostname `aok`, DHCP on `eth0`, OpenRC
services enabled (`hostname`, `networking`, `syslog`, `crond`), `mkinitfs` features
`virtio ext4`, and gettys on `tty1`, `tty2` and `ttyAMA0`. Nothing depends on systemd.

## 3a. How the guest gets there

`scripts/30-build-app.sh` gzips the built image into `AokVM.app/alpine.img.gz` (1 GiB sparse
→ ~100 MB). On first start `GuestImage.installIfNeeded` streams it through `gzread` into
`Library/Application Support/AokVM/guest.img`, 1 MB at a time, publishing progress, writing to
`guest.img.partial` and moving it into place only after the whole stream is out — a killed app
never leaves a half-written guest. The file is excluded from iCloud backup. An image imported
by hand lives in Documents and takes precedence; `resetGuest()` deletes and re-unpacks.

## 4. Display pipeline

`dpy_gfx_switch` records the new `DisplaySurface`; `dpy_gfx_update` clamps the dirty rect and
calls back into Swift **on the engine thread** with `(base, stride, x, y, w, h)`. Swift
memcpys that rect into an `IOSurface`-backed `MTLTexture` row by row, marks the frame dirty,
and a `CADisplayLink` on the main thread draws one fullscreen textured quad (aspect-fit,
letterboxed) into the `CAMetalLayer`.

* Format: `PIXMAN_x8r8g8b8` / `PIXMAN_a8r8g8b8` -> `.bgra8Unorm`. Anything else is refused in
  `dpy_gfx_check_format`, which makes QEMU pick a format we accept.
* No `CGImage`, no `UIImage`, no `UIView.draw` — one texture upload per dirty rect, one draw
  call per vsync.
* The callback runs with the guest vCPU briefly stalled. It copies and returns; it never
  calls back into the engine.
* Input and every other main-thread -> engine call is marshalled through
  `aio_bh_schedule_oneshot(qemu_get_aio_context(), ...)`, so it lands in the main loop and
  never on a vCPU thread.

## 5. Input

| iOS source | Engine call | Guest device |
|---|---|---|
| Hardware/software keyboard (`UIKey`, HID usage) | `qemu_input_event_send(con, &ev)`, `INPUT_EVENT_KIND_KEY` | `virtio-keyboard-pci` |
| Finger drag, trackpad | `qemu_input_queue_abs` + `qemu_input_event_sync` | `virtio-tablet-pci` (absolute) |
| Multi-touch (M5) | `qemu_input_touch_event`, slots 0-9 | needs a touch device; this tree has none — PLAN M5 |

`QemuInputEvent` on this branch is one struct (`include/ui/input.h`), so the bridge fills it
and posts one event per transition.

## 6. Constraints that shape the code

1. **No `fork`, no `exec`.** One process, one thread group. `-daemonize`, `-runas`,
   `-sandbox` and every helper-process path are off.
2. **No `PROT_EXEC`.** Also rules out `virtio-gpu-virgl`: no GL context to give it. The guest
   draws through virtio-gpu into a framebuffer QEMU rasterises in software, so the ceiling is
   the console's text output, not a compositor's frame rate.
3. **Memory.** 3 GiB is safe on an 8 GiB device; `VMRuntime` clamps against
   `os_proc_available_memory()`.
4. **Signing.** Unsigned IPA -> SideStore/AltStore/TrollStore. No special entitlements: no
   `dynamic-codesigning`, no hypervisor, no `get-task-allow` beyond a normal dev profile.
5. **Thermals.** Sustained interpretation is CPU-bound. The app exposes a 30/60 Hz display
   link and pauses the VM when the scene goes to background (`aok_ios_pause`).

## 7. What each repo contributes, precisely

* **emkey1/qemu @ `aok-vm`** — the whole virtual machine. `tcg/aarch64-tcti/` (17 files,
  `tcg-target.c.inc` is the backend proper, `tcti-gadget-gen.py` generates the gadget
  assembly), `accel/tcg/aok.c` + `aok-entry.S` (stream entry, TB jump, lookup),
  `target/arm/tcg/aok/` (AArch64 front end: `translate-a64.c`, `gadgets.S`,
  `gadgets-simd.S`, `shared/pairs.h` at 87 KB of fused-pair table), `tcg/darwin-vm.h`
  (Hypervisor.framework host access for macOS builds), `hw/display/virtio-ramfb.c` (UTM's
  ramfb+virtio-gpu device).
* **emkey1/aok-gadgets** — retired 2026-10-14, superseded by per-engine copies. Its value
  now is provenance and correctness: `tools/check.sh` assembles every shared body against a
  stand-in host whose registers deliberately differ, and its README documents the contract
  each `frag.h` body may assume. We keep a checkout to run that check when we touch gadgets.
* **rcarmo/ios-linuxkit** — `asbestos/guest-arm64/` gadget sources, the syscall layer,
  `fakefsify` (turns a rootfs tarball into an iSH fakefs image), and a test suite that
  executes instructions against known answers. Used for the in-app shell target and as the
  reference when the engine's AOK front end declines an instruction.
