#!/usr/bin/env bash
# Build the guest: Ubuntu 24.04 (noble) arm64, plus the UBports 24.04-1.x suite
# for Lomiri, laid out as a GPT disk with an EFI system partition and an ext4
# root, ready for QEMU's virt machine with edk2 firmware.
#
# Needs: Linux arm64 host, root, ~12 GB free. Debian/Ubuntu host:
#   apt install debootstrap parted dosfstools e2fsprogs mtools \
#               grub-efi-arm64-bin qemu-utils
#
#   sudo ./scripts/20-make-ut-image.sh [output.img]
#
# --keep-root leaves build/ut/root mounted-free but intact for inspection.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/build/ut/ut-2404-arm64.img}"
SIZE="${SIZE:-8G}"
ESP_MB="${ESP_MB:-512}"
ARCH=arm64
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
SUITE="${SUITE:-noble}"
UT_SUITE="${UT_SUITE:-24.04-1.x}"
UT_KEY_URL="https://repo.ubports.com/keyring.gpg"
KEEP_ROOT=0
[ "${2:-}" = "--keep-root" ] && KEEP_ROOT=1

WORK="$(dirname "$OUT")"
ROOTDIR="${WORK}/root"
MNT="${WORK}/mnt"
LOOP=""

banner() { printf '\n== %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root (debootstrap, loop mounts, chroot)"
[ "$(uname -m)" = "aarch64" ] || die "run on an arm64 host (or set QEMU_DEBOOTSTRAP=1 and add --foreign)"
command -v debootstrap >/dev/null || die "debootstrap missing"
command -v parted >/dev/null || die "parted missing"
command -v mkfs.vfat >/dev/null || die "dosfstools missing"
command -v grub-install >/dev/null || die "grub-efi-arm64-bin missing"

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

banner "disk image ($SIZE)"
mkdir -p "$WORK"
if [ -f "$OUT" ]; then
    echo "$OUT exists; rebuilding"
    rm -f "$OUT"
fi
truncate -s "$SIZE" "$OUT"

# GPT: p1 ESP, p2 root. Names matter to neither firmware nor Linux, but they
# make `lsblk` readable when debugging an image by hand.
parted -s "$OUT" mklabel gpt
parted -s "$OUT" mkpart ESP fat32 1MiB "$((ESP_MB + 1))MiB"
parted -s "$OUT" set 1 esp on
parted -s "$OUT" mkpart root ext4 "$((ESP_MB + 1))MiB" 100%

LOOP="$(losetup --find --show --partscan "$OUT")"
echo "loop device: $LOOP"
udevadm settle 2>/dev/null || sleep 1
ROOTDEV="${LOOP}p2"; ESPDEV="${LOOP}p1"
[ -b "$ROOTDEV" ] || die "partition devices did not appear (try partx -a $LOOP)"

mkfs.vfat -F 32 -n ESP "$ESPDEV" >/dev/null
mkfs.ext4 -q -L ut-root -O ^has_journal -m 1 "$ROOTDEV"

banner "debootstrap ${SUITE}/${ARCH}"
if [ ! -x "${ROOTDIR}/debootstrap/debootstrap" ] && [ ! -d "${ROOTDIR}/usr/bin" ]; then
    mkdir -p "$ROOTDIR"
    debootstrap --arch="$ARCH" --variant=minbase --foreign "$SUITE" "$ROOTDIR" "$MIRROR"
fi

mkdir -p "$MNT"
mount "$ROOTDEV" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$ESPDEV" "$MNT/boot/efi"

if [ -x "${ROOTDIR}/debootstrap/debootstrap" ]; then
    banner "second stage"
    cp /usr/bin/qemu-aarch64-static "$MNT/usr/bin/" 2>/dev/null || true
    chroot "$MNT" /debootstrap/debootstrap --second-stage
fi

banner "apt sources"
cat > "$MNT/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main restricted universe multiverse
deb ${MIRROR} ${SUITE}-updates main restricted universe multiverse
deb ${MIRROR} ${SUITE}-security main restricted universe multiverse
EOF

curl -fsSL "$UT_KEY_URL" -o "$MNT/tmp/ubports.gpg"
install -Dm644 "$MNT/tmp/ubports.gpg" "$MNT/etc/apt/trusted.gpg.d/ubports.gpg"
cat > "$MNT/etc/apt/sources.list.d/ubports.list" <<EOF
deb https://repo.ubports.com/ ${UT_SUITE} main
EOF
# Flatpak and snap are noise in a VM.
cat > "$MNT/etc/apt/preferences.d/no-snap" <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

cp /etc/resolv.conf "$MNT/etc/resolv.conf"
mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/dev/pts" "$MNT/run"
mount -t proc proc "$MNT/proc"
mount -t sysfs sys "$MNT/sys"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount -t tmpfs tmpfs "$MNT/run"

# Never start services while we are chrooted into the image.
cat > "$MNT/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$MNT/usr/sbin/policy-rc.d"

export DEBIAN_FRONTEND=noninteractive

banner "base system"
chroot "$MNT" apt-get update -qq
chroot "$MNT" apt-get install -y -qq --no-install-recommends \
    systemd systemd-sysv initramfs-tools dbus dbus-user-session \
    linux-image-generic linux-modules-extra-generic \
    grub-efi-arm64 grub-efi-arm64-bin \
    locales tzdata ca-certificates curl gnupg sudo less nano \
    systemd-timesyncd systemd-networkd systemd-resolved \
    seatd libgl1-mesa-dri libegl1 libgles2 mesa-utils \
    fonts-ubuntu fontconfig udev kmod \
    >/dev/null

banner "Ubuntu Touch packages"
# Checked against repo.ubports.com/dists/24.04-1.x/Contents-arm64.
UT_PKGS=(
    lomiri
    lomiri-system-compositor
    qml-module-lomiri-components
    lomiri-ui-toolkit-common
    lomiri-ui-toolkit-theme
    lomiri-app-launch
    lomiri-system-settings
    lomiri-keyboard
    lomiri-greeter
    ubuntu-touch-session
    ubuntu-touch-core-mainline
    ubuntu-touch-settings
    mir-platform-graphics-gbm-kms
    mir-platform-input-evdev10
    qtmir-qt5-mir1
)
for pkg in "${UT_PKGS[@]}"; do
    if chroot "$MNT" apt-cache show "$pkg" >/dev/null 2>&1; then
        echo "  + $pkg"
    else
        echo "  ! $pkg not in the index for ${UT_SUITE}/${ARCH}"
    fi
done
chroot "$MNT" apt-get install -y -qq --no-install-recommends "${UT_PKGS[@]}" || \
    echo "warning: some UT packages failed to install; see /var/log/apt in the image"

banner "user and session"
chroot "$MNT" useradd -m -s /bin/bash -G sudo,video,render,input,audio,plugdev,netdev,bluetooth \
    -c "Ubuntu Touch" phablet || true
echo 'phablet:phablet' | chroot "$MNT" chpasswd
echo 'phablet ALL=(ALL) NOPASSWD:ALL' > "$MNT/etc/sudoers.d/90-phablet"
chmod 440 "$MNT/etc/sudoers.d/90-phablet"

cat > "$MNT/etc/systemd/system/aok-lomiri.service" <<'EOF'
[Unit]
Description=Lomiri session (aok-utouch)
Conflicts=getty@tty1.service
After=systemd-user-sessions.service seatd.service systemd-logind.service
Wants=seatd.service

[Service]
Type=simple
User=phablet
Group=phablet
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_CURRENT_DESKTOP=Lomiri
Environment=QT_QPA_PLATFORM=ubuntumirclient
Environment=MIR_SERVER_PLATFORM_PATH=/usr/lib/aarch64-linux-gnu/mir/server-platform
Environment=LIBGL_ALWAYS_SOFTWARE=1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical.target
EOF

chroot "$MNT" systemctl set-default graphical.target
chroot "$MNT" systemctl enable aok-lomiri.service seatd.service systemd-networkd.service
chroot "$MNT" systemctl mask getty@tty1.service || true

cat > "$MNT/etc/systemd/network/10-wired.network" <<'EOF'
[Match]
Name=en* vd* eth*

[Network]
DHCP=yes
EOF
chroot "$MNT" systemctl enable systemd-networkd.service

cat > "$MNT/etc/fstab" <<'EOF'
/dev/vda2  /          ext4  defaults,noatime,errors=remount-ro  0 1
/dev/vda1  /boot/efi  vfat  umask=0077                            0 1
EOF

banner "trim"
chroot "$MNT" apt-get purge -y -qq snapd apport whoopsie unattended-upgrades \
    ubuntu-report modemmanager bluez wpa_supplicant tracker tracker-miner-fs \
    cloud-init >/dev/null 2>&1 || true
chroot "$MNT" apt-get autoremove -y -qq >/dev/null

banner "bootloader"
mkdir -p "$MNT/boot/efi/EFI/BOOT"
cat > "$MNT/etc/default/grub" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=1
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyAMA0,115200 console=tty1 rootwait rw quiet splash video=Virtual-1:${VIDEO:-1280x720@60}"
GRUB_TERMINAL=console
EOF
chroot "$MNT" update-initramfs -u -k all >/dev/null
chroot "$MNT" grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --bootloader-id=aok-utouch --removable --no-nvram
chroot "$MNT" update-grub >/dev/null
ls -l "$MNT/boot/efi/EFI/BOOT/" | head

banner "unmount"
for d in dev/pts dev proc sys run boot/efi; do
    mountpoint -q "${MNT}/${d}" && umount -lf "${MNT}/${d}"
done
umount -lf "$MNT"
losetup -d "$LOOP"; LOOP=""
trap - EXIT

banner "result"
ls -lh "$OUT"
e2fsck -fn "${OUT}" 2>/dev/null | head -3 || true
if [ "$KEEP_ROOT" = 1 ]; then
    echo "root tree kept at $ROOTDIR (delete it before re-running debootstrap)"
else
    rm -rf "$ROOTDIR"
fi
echo
echo "Copy $(basename "$OUT") into the app's Documents (Files app, or the import button)."
