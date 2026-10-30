# Ubuntu Touch on virtio hardware (deferred)

> **Deferred.** The shipping guest is a pre-configured Alpine rootfs
> (`scripts/20-make-alpine-image.sh`); this page is kept because the analysis is
> still correct if the Lomiri front end is picked up again. Nothing below is
> built by CI today, and the Ubuntu image builder it refers to has been replaced by
> `20-make-alpine-image.sh`.

## 1. What "port Ubuntu Touch" means here

UT 24.04-1.x is an Ubuntu 24.04 arm64 base plus the UBports archive. Verified today:

```
$ curl -s https://repo.ubports.com/dists/24.04-1.x/Release
Origin: UBports       Suite: 24.04-1.x      Codename: 24.04-1.x
Architectures: amd64 arm64 armhf            Components: main
Date: Tue, 27 Oct 2026 19:14:05 UTC
```

The packages we need are all in that suite for arm64 (checked against
`Contents-arm64`, 11 MB index):

| Need | Package |
|---|---|
| The shell | `lomiri` (installs `/usr/bin/lomiri`), `lomiri-system-compositor` |
| UI toolkit | `qml-module-lomiri-components`, `lomiri-ui-toolkit-theme`, `lomiri-ui-toolkit-common` |
| Session | `ubuntu-touch-session`, `ubuntu-touch-session-mir`, `ubuntu-touch-core`, `ubuntu-touch-core-mainline` |
| App launch / settings / keyboard | `lomiri-app-launch`, `lomiri-system-settings`, `lomiri-keyboard`, `lomiri-greeter` |
| Compositor platform | `mir-platform-graphics-gbm-kms`, `mir-platform-input-evdev10`, `qtmir-qt5-mir1` |

**Halium is not involved.** UT ships two device classes: `ubuntu-touch-hybris` +
`mir1-graphics-drivers-android*` (Android kernel, libhybris, Android GPU drivers) and
`ubuntu-touch-core-mainline` (ordinary Linux DRM/KMS + evdev — what PinePhone and other
mainline ports use). A QEMU `virt` machine with virtio-gpu, virtio-input and a generic Ubuntu
kernel is a mainline device, so we take the mainline class and skip every Hybris package. That
single decision is what makes this port tractable: no Android blobs, no libhybris, no
`/dev/binder`.

## 2. The boot chain

```
edk2 aarch64 (pflash)  ->  GRUB arm64-efi on p1  ->  Image + initrd.img  ->
  systemd (graphical.target) -> seatd + logind -> aok-lomiri.service (user phablet)
    -> lomiri-system-compositor (Mir, gbm-kms on /dev/dri/card0)
      -> lomiri shell (Qt5/QML) -> apps via lomiri-app-launch
```

`aok-lomiri.service` is ours, not UT's: a normal `systemd --user` session for `phablet`
with a greeter-less start. UT's own path expects LightDM + a greeter + `ubuntu-touch-session`'s
`upstart`-era plumbing, which is more moving parts than a first port needs. The unit is
installed by `20-make-ut-image.sh` as `/etc/systemd/system/aok-lomiri.service` and does:

```ini
[Unit]
Description=Lomiri session (aok-utouch)
Requires=systemd-user-sessions.service
After=systemd-user-sessions.service seatd.service
[Service]
User=phablet
PAMName=login
TTYPath=/dev/tty1
Environment=QT_QPA_PLATFORM=ubuntumirclient XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=Lomiri
Environment=MIR_SERVER_PLATFORM_PATH=/usr/lib/aarch64-linux-gnu/mir/server-platform
ExecStart=/usr/bin/lomiri
Restart=on-failure
```

## 3. Devices the guest must find

| Guest need | QEMU flag | Guest driver |
|---|---|---|
| Display | `-device virtio-ramfb` (inherits virtio-gpu-base: `xres`/`yres`) | `virtio_gpu` -> DRM card0 |
| Disk | `-device virtio-blk-pci,drive=hd0` | `virtio_blk` -> vda |
| Pointer | `-device virtio-tablet-pci` | `virtio_input` (absolute) |
| Keyboard | `-device virtio-keyboard-pci` | `virtio_input` |
| Network | `-netdev user,id=n0 -device virtio-net-pci,netdev=n0` | `virtio_net` + NetworkManager DHCP |
| Firmware console | `virtio-ramfb` + `video=Virtual-1:1280x720@60` | `simpledrm`/`virtio_gpu` |

`virtio_gpu`, `virtio_input`, `virtio_blk` and `virtio_net` are all in the kernel's
`linux-modules-<abi>-generic` package, which `linux-image-generic` pulls; nothing this VM
needs lives in `linux-modules-extra` (which has no meta package on arm64 at all). The image
script runs `update-initramfs` so they are present before root is mounted.

## 4. Rendering: the honest problem

Mir on `gbm-kms` wants GL. Our host has no GPU to give it — `virtio-gpu-virgl` needs
virglrenderer, which needs a host GLES implementation, which an unsigned iOS app does not
have. So the guest's Mesa falls back to `llvmpipe`, and every Lomiri frame is rasterised by
interpreted AArch64 code.

That is the project's real performance ceiling, and it is measured, not argued:

* Target: **1280x720 at >= 15 fps** for shell navigation on M1-class or newer iPad.
* Escalation if missed, in order:
  1. 1024x600 scanout, Lomiri `gridUnit` scale 1.0, `QT_QUICK_BACKEND=software` for apps
     that tolerate it (Qt Quick's software renderer bypasses llvmpipe for plain scenes).
  2. `-smp 1` and a `nice`d Mir: one vCPU often beats two under a cooperative interpreter
     because TB churn and locking cost more than the parallelism gains.
  3. Mir's software renderer instead of `gbm-kms` (drops full-screen GL passes; Lomiri's
     shell is mostly 2D surfaces).
  4. Accept a lower resolution (960x540) — pixel count is the dominant term in llvmpipe.

AOK gadgets matter here more than anywhere else: the measured 1.5–3.7× over TCTI on an iPad
M4 is the difference between a usable shell and a slideshow.

## 5. Image contents and trimming

`20-make-ut-image.sh` installs, then removes everything a VM does not need: `snapd`,
`apport`, `whoopsie`, `unattended-upgrades`, `tracker`, `bluez`, `wpa_supplicant`, `modemmanager`,
`ubuntu-report`. It enables: `zram` (0.5x RAM), `fstrim.timer`, `serial-getty@ttyAMA0`.
It disables: `systemd-resolved` stub listener (slirp provides DNS), `apt-daily*`.

Resulting footprint: ~2.9 GB used on an 8 GB image with the core Lomiri apps.
