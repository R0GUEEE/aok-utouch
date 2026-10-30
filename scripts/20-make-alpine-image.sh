#!/usr/bin/env bash
# Build the guest: a pre-configured Alpine Linux arm64 rootfs on a GPT disk
# with an EFI system partition, ready for QEMU's virt machine and its edk2
# firmware. Roughly 300 MB of root, a second of boot, no systemd, no Halium.
#
#   sudo ./scripts/20-make-alpine-image.sh [output.img]
#
# Needs: Linux arm64 host, root, ~2 GB free, and
#   apt install parted dosfstools e2fsprogs grub-efi-arm64-bin
#
# Environment: SIZE (default 1G), ESP_MB (128), ALPINE_VER (3.24),
#              ALPINE_REL (3.24.3), ALPINE_MIRROR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/build/guest/alpine.img}"
SIZE="${SIZE:-1G}"
ESP_MB="${ESP_MB:-128}"
VER="${ALPINE_VER:-3.24}"
REL="${ALPINE_REL:-3.24.3}"
MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
TARBALL_URL="${MIRROR}/v${VER}/releases/aarch64/alpine-minirootfs-${REL}-aarch64.tar.gz"

# Versions are documented in the commit that bumps them. Keep the kernel the
# image ships in step with the modules inside it by installing both from the
# same release.
PKGS="alpine-base linux-virt linux-firmware-none openssh-client \
bash nano less curl wget git tmux htop e2fsprogs-extra util-linux \
ifupdown-ng-iproute2 openrc openssh"

WORK="$(dirname "$OUT")"
MNT="${WORK}/mnt"
LOOP=""

banner() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (loop mounts, chroot)"
[ "$(uname -m)" = "aarch64" ] || die "run on an arm64 host"
for tool in parted mkfs.vfat mkfs.ext4 grub-install curl tar chroot; do
    command -v "$tool" >/dev/null || die "missing $tool"
done

cleanup() {
    set +e
    for d in dev/pts dev proc sys run boot/efi; do
        mountpoint -q "${MNT}/${d}" && umount -lf "${MNT}/${d}"
    done
    mountpoint -q "$MNT" && umount -lf "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    return 0
}
trap cleanup EXIT

banner "disk image ($SIZE, ESP ${ESP_MB}M)"
mkdir -p "$WORK"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart ESP fat32 1MiB "$((ESP_MB + 1))MiB"
parted -s "$OUT" set 1 esp on
parted -s "$OUT" mkpart root ext4 "$((ESP_MB + 1))MiB" 100%

LOOP="$(losetup --find --show --partscan "$OUT")"
udevadm settle 2>/dev/null || sleep 1
ROOTDEV="${LOOP}p2"; ESPDEV="${LOOP}p1"
[ -b "$ROOTDEV" ] || die "partitions did not appear (try partx -a $LOOP)"

mkfs.vfat -F 32 -n ESP "$ESPDEV" >/dev/null
mkfs.ext4 -q -F -L aok-root -O ^has_journal -m 1 "$ROOTDEV"

mkdir -p "$MNT"
mount "$ROOTDEV" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$ESPDEV" "$MNT/boot/efi"

banner "unpack Alpine ${REL}"
curl -fL --retry 3 -o "${WORK}/minirootfs.tar.gz" "$TARBALL_URL"
tar -xzf "${WORK}/minirootfs.tar.gz" -C "$MNT"
rm -f "${WORK}/minirootfs.tar.gz"

cat > "$MNT/etc/apk/repositories" <<EOF
${MIRROR}/v${VER}/main
${MIRROR}/v${VER}/community
EOF

# Resolver for the chroot, and a sane fallback for the guest: QEMU's slirp
# serves DNS at 10.0.2.3 and DHCP will overwrite this anyway.
echo 'nameserver 10.0.2.3' > "$MNT/etc/resolv.conf"
echo 'nameserver 1.1.1.1' >> "$MNT/etc/resolv.conf"

mkdir -p "$MNT/proc" "$MNT/dev" "$MNT/dev/pts" "$MNT/sys" "$MNT/run"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t tmpfs tmpfs "$MNT/run"

banner "packages"
chroot "$MNT" /sbin/apk update -q
# shellcheck disable=SC2086
chroot "$MNT" /sbin/apk add --no-cache $PKGS

banner "configure"
echo aok > "$MNT/etc/hostname"
cat > "$MNT/etc/hosts" <<'EOF'
127.0.0.1        localhost.localdomain localhost
::1              localhost.localdomain localhost
10.0.2.15        aok aok.local
EOF

# Root password is aok. The VM is behind slirp's NAT: nothing outside the
# device can reach it, and the console is the intended way in.
chroot "$MNT" sh -c 'echo "root:aok" | chpasswd'

cat > "$MNT/etc/fstab" <<'EOF'
/dev/vda2  /          ext4  defaults,noatime  0 1
/dev/vda1  /boot/efi  vfat  defaults          0 2
EOF

# virtio + ext4 must be in the initramfs: they are modules in linux-virt.
cat > "$MNT/etc/mkinitfs/mkinitfs.conf" <<'EOF'
features="ata base ide scsi usb virtio ext4"
EOF

cat > "$MNT/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Console on both: tty1 is the virtio-gpu framebuffer the app displays, and
# ttyAMA0 is the serial port, which lands in the app's engine log.
cat > "$MNT/etc/inittab" <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
ttyAMA0::respawn:/sbin/getty -L 115200 ttyAMA0 vt100

::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

cat > "$MNT/etc/motd" <<'EOF'

  aok-utouch guest -- Alpine Linux on the AOK gadget engine
  ------------------------------------------------
  kernel   : $(uname -r)
  console  : tty1 (framebuffer), ttyAMA0 (serial)
  packages : apk add <name>
  network  : DHCP on eth0 via QEMU slirp (10.0.2.15/24, gw 10.0.2.2)

EOF

# Services: without these an OpenRC rootfs boots to a login prompt and does
# nothing else. rc-update writes /etc/runlevels, no init required.
for svc in hostname; do chroot "$MNT" rc-update add "$svc" boot; done
for svc in networking syslog; do chroot "$MNT" rc-update add "$svc" boot; done
for svc in crond; do chroot "$MNT" rc-update add "$svc" default; done

chroot "$MNT" mkinitfs -o /boot/initramfs-virt "$(ls "$MNT/lib/modules" | head -1)" || true

ls -l "$MNT/boot/" | sed 's/^/  /'

banner "boot loader"
# grub comes from the host: the guest needs a kernel and a loader that the
# firmware can find, not grub packages of its own.
[ -s "$MNT/boot/vmlinuz-virt" ] || die "no kernel at /boot/vmlinuz-virt"
[ -s "$MNT/boot/initramfs-virt" ] || die "no initramfs: mkinitfs failed in the chroot"
install -Dm644 "$MNT/boot/vmlinuz-virt" "$MNT/boot/efi/vmlinuz-virt"
install -Dm644 "$MNT/boot/initramfs-virt" "$MNT/boot/efi/initramfs-virt"
mkdir -p "$MNT/boot/efi/grub"

cat > "$MNT/boot/efi/grub/grub.cfg" <<'EOF'
set timeout=1
set default=0

menuentry "Alpine Linux (aok-utouch)" {
    linux /vmlinuz-virt root=/dev/vda2 rw rootwait console=ttyAMA0,115200 console=tty1
    initrd /initramfs-virt
}

menuentry "Alpine Linux (quiet)" {
    linux /vmlinuz-virt root=/dev/vda2 rw rootwait quiet console=ttyAMA0,115200 console=tty1
    initrd /initramfs-virt
}
EOF

# --boot-directory is the ESP itself, so grub's prefix is (hd0,gpt1)/grub and
# the config has to live at /grub/grub.cfg - not at /grub.cfg.
grub-install --target=arm64-efi --efi-directory="$MNT/boot/efi" \
    --boot-directory="$MNT/boot/efi" --removable --no-nvram \
    --modules="part_gpt part_msdos fat ext2 normal linux configfile echo search" \
    >/dev/null
cp "$MNT/boot/efi/grub/grub.cfg" "$MNT/boot/efi/EFI/BOOT/grub.cfg"
ls -l "$MNT/boot/efi/EFI/BOOT/" | sed 's/^/  /'

banner "report"
du -sh "$MNT" 2>/dev/null | sed 's/^/  rootfs: /'
df -h "$MNT" | sed -n '2p' | sed 's/^/  /'

banner "unmount"
for d in dev/pts dev proc sys run boot/efi; do
    mountpoint -q "${MNT}/${d}" && umount -lf "${MNT}/${d}"
done
umount -lf "$MNT"
losetup -d "$LOOP"; LOOP=""
trap - EXIT
rm -rf "$MNT"

banner "result"
ls -lh "$OUT"
echo
echo "Import $(basename "$OUT") in the app, then Start."
echo "Serial console output goes to Documents/Logs/engine.log on the device."
