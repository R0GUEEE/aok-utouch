#!/usr/bin/env bash
# Build the Ubuntu Touch guest: Ubuntu 24.04 (noble) arm64 plus the UBports
# 24.04-1.x suite, with Lomiri, on a GPT disk with an EFI system partition and
# an ext4 root, ready for QEMU's virt machine and its edk2 firmware.
#
# This is the heavy guest. scripts/20-make-alpine-image.sh builds the small one;
# both produce an image the app can bundle, and 30-build-app.sh decides which.
#
# Needs: Linux arm64 host, root, ~14 GB free. Debian/Ubuntu host:
#   apt install debootstrap parted dosfstools e2fsprogs grub-efi-arm64-bin
#
#   sudo ./scripts/20-make-ut-image.sh [output.img]   (default build/guest/ut.img)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-${ROOT}/build/guest/ut.img}"
SIZE="${SIZE:-5G}"
ESP_MB="${ESP_MB:-512}"
ARCH=arm64
MIRROR="${MIRROR:-http://ports.ubuntu.com/ubuntu-ports}"
SUITE="${SUITE:-noble}"
UT_SUITE="${UT_SUITE:-24.04-1.x}"
UT_KEY_URL="https://repo.ubports.com/keyring.gpg"

WORK="$(dirname "$OUT")"
MNT="${WORK}/mnt"
LOOP=""

banner() { printf '\n== %s\n' "$*"; }

# du walks /proc and /sys too, where entries vanish while it reads them; that
# makes it exit non-zero and, under set -e, takes the build with it.
root_used_mb() {
    du -sm --exclude=proc --exclude=sys --exclude=dev --exclude=run "$MNT" 2>/dev/null \
        | cut -f1 || echo 0
}

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

mkdir -p "$MNT"
mount "$ROOTDEV" "$MNT"
mkdir -p "$MNT/boot/efi"
mount "$ESPDEV" "$MNT/boot/efi"

banner "debootstrap ${SUITE}/${ARCH}"
# Straight onto the image's root, and no --foreign: the host is arm64 and so is
# the target, so the second stage runs here. A staging directory would have to
# be copied onto the mount afterwards, and a forgotten copy is exactly the kind
# of failure that shows up three minutes into a 25-minute job.
debootstrap --arch="$ARCH" --variant=minbase "$SUITE" "$MNT" "$MIRROR"

banner "apt sources"
cat > "$MNT/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main restricted universe multiverse
deb ${MIRROR} ${SUITE}-updates main restricted universe multiverse
deb ${MIRROR} ${SUITE}-security main restricted universe multiverse
EOF

# The UBports archive is HTTPS and the freshly bootstrapped root has no CA
# store yet, so its source is added after ca-certificates is installed.
# snapd is not optional here: ubuntu-touch-core depends on it, and pinning it
# away made the entire Lomiri stack uninstallable. It is installed and then
# masked - the VM does not want a background snap daemon.

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
    ca-certificates curl gnupg \
    systemd systemd-sysv initramfs-tools dbus dbus-user-session \
    linux-image-generic \
    grub-efi-arm64 grub-efi-arm64-bin \
    locales tzdata sudo less nano \
    systemd-timesyncd systemd-resolved network-manager \
    seatd libgl1-mesa-dri libegl1 libgles2 mesa-utils \
    fonts-ubuntu fontconfig udev kmod \
    >/dev/null

# linux-modules-extra has no meta package on arm64; take the newest ABI build
# if one exists. Nothing on the virtio path lives there — it is insurance for
# exotic drivers a user might blacklist their way into needing.
EXTRA_MODULES="$(chroot "$MNT" sh -c \
    "apt-cache search --names-only '^linux-modules-extra-[0-9].*-generic$' \
     | awk '{print \$1}' | sort -V | tail -1")"
if [ -n "$EXTRA_MODULES" ]; then
    chroot "$MNT" apt-get install -y -qq --no-install-recommends "$EXTRA_MODULES" >/dev/null
    echo "  + $EXTRA_MODULES"
fi

banner "UBports archive"
curl -fsSL "$UT_KEY_URL" -o "$MNT/tmp/ubports.gpg"
install -Dm644 "$MNT/tmp/ubports.gpg" "$MNT/etc/apt/trusted.gpg.d/ubports.gpg"
cat > "$MNT/etc/apt/sources.list.d/ubports.list" <<EOF
deb https://repo.ubports.com/ ${UT_SUITE} main
EOF
chroot "$MNT" apt-get update -qq

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
if ! chroot "$MNT" apt-get install -y --no-install-recommends "${UT_PKGS[@]}" \
        2>&1 | tee "$WORK/ut-apt.log"; then
    # A batch install tells you "held broken packages" and nothing else. Retry
    # per package so the log names the culprit, then carry on: a bootable image
    # with three missing UI packages is worth more than no image.
    echo "warning: batch install failed, retrying individually" >&2
    for pkg in "${UT_PKGS[@]}"; do
        chroot "$MNT" apt-get install -y --no-install-recommends "$pkg" \
            >"$WORK/ut-$pkg.log" 2>&1 || echo "  ! $pkg failed ($WORK/ut-$pkg.log)"
    done
fi

banner "user and session"
# Groups a minimal root does not have; useradd fails outright on a missing one.
for g in sudo video render input audio plugdev netdev bluetooth; do
    chroot "$MNT" getent group "$g" >/dev/null 2>&1 || chroot "$MNT" groupadd -r "$g"
done
chroot "$MNT" useradd -m -s /bin/bash \
    -G sudo,video,render,input,audio,plugdev,netdev,bluetooth \
    -c "Ubuntu Touch" phablet || true
# chpasswd goes through PAM, which is not fully configured in a chroot this
# young; write the hash straight into /etc/shadow instead.
PHABLET_HASH="$(openssl passwd -6 phablet)"
chroot "$MNT" usermod -p "$PHABLET_HASH" phablet
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

# Installed because a dependency demands it, masked because nothing in this VM
# should be refreshing snaps behind our back.
chroot "$MNT" systemctl mask snapd.service snapd.socket snapd.seeded.service || true
chroot "$MNT" systemctl disable snapd.service snapd.socket || true

chroot "$MNT" systemctl set-default graphical.target
chroot "$MNT" systemctl enable aok-lomiri.service seatd.service NetworkManager.service
chroot "$MNT" systemctl mask getty@tty1.service || true

# Ubuntu Touch's indicator talks to NetworkManager, and NM brings up the
# virtio NIC over DHCP from slirp without any configuration.
cat > "$MNT/etc/NetworkManager/conf.d/10-aok.conf" <<'EOF'
[main]
dns=default
[connection]
ipv6.method=disabled
EOF

cat > "$MNT/etc/fstab" <<'EOF'
/dev/vda2  /          ext4  defaults,noatime,errors=remount-ro  0 1
/dev/vda1  /boot/efi  vfat  umask=0077                            0 1
EOF

banner "trim"
# Trimming is an optimisation, never a reason to fail: Ubuntu Touch ships
# maintainer scripts that expect a running systemd and do not survive a purge in
# a chroot (bluez is one). Run the whole thing in a subshell with -e off and
# leave dpkg configured afterwards, so the rest of the build can continue.
(
    set +e
    for pkg in apport whoopsie unattended-upgrades ubuntu-report modemmanager \
               bluez wpa_supplicant tracker tracker-miner-fs cloud-init; do
        chroot "$MNT" dpkg -s "$pkg" >/dev/null 2>&1 || continue
        chroot "$MNT" apt-get purge -y -qq "$pkg" >/dev/null 2>&1 \
            || echo "  note: could not purge $pkg" >&2
        chroot "$MNT" dpkg --configure -a >/dev/null 2>&1
    done
    chroot "$MNT" apt-get autoremove -y -qq >/dev/null 2>&1
    chroot "$MNT" apt-get clean >/dev/null 2>&1
    # A half-configured package would make the image fail at first boot instead
    # of here, which is much harder to see.
    chroot "$MNT" dpkg --configure -a >/dev/null 2>&1
    chroot "$MNT" dpkg --audit 2>&1 | sed 's/^/  dpkg audit: /'
    true
)

banner "strip"
# A 5 GB image has no room for /usr/share/doc and a package cache, and neither
# survives compression well enough to be worth carrying.
chroot "$MNT" apt-get clean
rm -rf "$MNT"/var/lib/apt/lists/* "$MNT"/var/cache/apt/archives/*.deb
find "$MNT/usr/share/doc" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find "$MNT/usr/share/man" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find "$MNT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
echo "  rootfs now: $(root_used_mb) MB"

banner "manifest"
ROOT_MB="$(root_used_mb)"
cat > "${OUT%.img}.manifest" <<EOF
guest=ubuntu-touch
name=Ubuntu Touch 24.04-1.x (Lomiri)
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
root_used_mb=${ROOT_MB}
suite=${SUITE} ${UT_SUITE}
EOF
cat "${OUT%.img}.manifest" | sed 's/^/  /'

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
rm -rf "$MNT"
echo
echo "Bundle it with: GUEST_IMAGE=$OUT bash scripts/30-build-app.sh"
echo "(or let CI do it: workflow_dispatch with guest=ut)"
