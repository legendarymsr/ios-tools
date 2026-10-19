#!/usr/bin/env bash
#
# setup-debian-chroot.sh
# Set up a real Debian (glibc) chroot on a rooted Android phone, with /dev/kvm
# passed through so QEMU inside it can use hardware KVM acceleration.
#
# WHY A CHROOT AND NOT proot: proot emulates syscalls in userspace via ptrace,
# which (a) can't reliably expose a working /dev/kvm and (b) adds per-syscall
# overhead that kills QEMU performance. With KERNEL root you can do a real
# chroot and bind-mount the device nodes, so KVM actually works.
#
# Run this AS ROOT in a root shell on the phone (e.g. `su` from Termux, or the
# KernelSU/Magisk root shell). It does NOT run on a PC.
#
# Requires: a custom kernel with CONFIG_KVM=y that exposes /dev/kvm (see
# README.md "Enabling KVM"). busybox or toybox (wget/tar) available on device.
set -eu

ROOTFS="${ROOTFS:-/data/local/debian}"
SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"
# Pinned rootfs source: Debian's official container rootfs tarballs.
URL="${URL:-https://github.com/debuerreotype/docker-debian-artifacts/raw/dist-${ARCH}/${SUITE}/rootfs.tar.xz}"

echo "[*] Target rootfs: $ROOTFS  (Debian $SUITE $ARCH)"
if [ "$(id -u)" != "0" ]; then
  echo "    ERROR: run this as root (su)." >&2
  exit 1
fi

mkdir -p "$ROOTFS"
if [ ! -e "$ROOTFS/etc/os-release" ]; then
  echo "[*] Downloading Debian rootfs..."
  cd "$ROOTFS"
  # Use whichever downloader exists on the device.
  if command -v curl >/dev/null 2>&1; then curl -L -o rootfs.tar.xz "$URL";
  elif command -v wget >/dev/null 2>&1; then wget -O rootfs.tar.xz "$URL";
  else echo "    Need curl or wget on device." >&2; exit 1; fi
  echo "[*] Extracting (this takes a minute)..."
  tar -xJf rootfs.tar.xz
  rm -f rootfs.tar.xz
fi

echo "[*] Copying helper scripts into chroot /root (if present)"
for f in install-qemu.sh run-arm64-linux.sh run-woa.sh setup-build-deps.sh build-inferno.sh run-t8030.sh prepare-ios-files.sh; do
  [ -f "$(dirname "$0")/$f" ] && cp -f "$(dirname "$0")/$f" "$ROOTFS/root/" 2>/dev/null || true
done
chmod +x "$ROOTFS"/root/*.sh 2>/dev/null || true

echo "[*] Writing resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"

cat > "$ROOTFS/root/.inside-notes" <<'NOTE'
You are inside the Debian chroot. Next steps:
  apt-get update
  # Part A (iOS t8030):      /root/build-inferno.sh
  # Part B (general KVM):    /root/install-qemu.sh   then run-*.sh
NOTE

echo "[*] Installing enter helper at $ROOTFS/../enter-debian.sh"
cat > "$(dirname "$ROOTFS")/enter-debian.sh" <<ENTER
#!/system/bin/sh
# Enter the Debian chroot with /dev, /proc, /sys and /dev/kvm bind-mounted.
ROOTFS="$ROOTFS"
busybox mount --bind /dev     "\$ROOTFS/dev"     2>/dev/null || mount -o bind /dev     "\$ROOTFS/dev"
busybox mount --bind /dev/pts "\$ROOTFS/dev/pts" 2>/dev/null || mount -o bind /dev/pts "\$ROOTFS/dev/pts"
busybox mount --bind /proc    "\$ROOTFS/proc"    2>/dev/null || mount -o bind /proc    "\$ROOTFS/proc"
busybox mount --bind /sys     "\$ROOTFS/sys"     2>/dev/null || mount -o bind /sys     "\$ROOTFS/sys"
# /dev/kvm comes through the /dev bind above. Make sure it is accessible:
[ -e /dev/kvm ] && chmod 666 /dev/kvm 2>/dev/null || echo "WARN: /dev/kvm missing - see README (no custom kernel?)"
if [ "\$#" -gt 0 ]; then exec chroot "\$ROOTFS" /bin/bash -lc "\$*"; else exec chroot "\$ROOTFS" /bin/bash -l; fi
ENTER
chmod +x "$(dirname "$ROOTFS")/enter-debian.sh"

echo
echo "[done] Enter the chroot any time with:"
echo "    su -c $(dirname "$ROOTFS")/enter-debian.sh"
echo
echo "Then inside: apt-get update && apt-get install -y curl ca-certificates xz-utils"
