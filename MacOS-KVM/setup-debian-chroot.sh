#!/usr/bin/env bash
#
# setup-debian-chroot.sh
# Set up a real Debian (glibc) chroot on a rooted Android phone so we can run
# Debian's qemu-system-x86_64 (macOS guests are x86_64; host is aarch64, so
# this is TCG-only — no KVM across architectures).
#
# Run AS ROOT on the phone. Shared with the other QEMU modules in ios-tools.
set -eu

ROOTFS="${ROOTFS:-/data/local/debian}"
SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"
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
  if command -v curl >/dev/null 2>&1; then curl -L -o rootfs.tar.xz "$URL";
  elif command -v wget >/dev/null 2>&1; then wget -O rootfs.tar.xz "$URL";
  else echo "    Need curl or wget on device." >&2; exit 1; fi
  echo "[*] Extracting (this takes a minute)..."
  tar -xJf rootfs.tar.xz
  rm -f rootfs.tar.xz
fi

echo "[*] Copying helper scripts into chroot /root (if present)"
for f in install-qemu-x86.sh setup-osx-kvm.sh fetch-sonoma.sh boot-macos14.sh; do
  [ -f "$(dirname "$0")/$f" ] && cp -f "$(dirname "$0")/$f" "$ROOTFS/root/" 2>/dev/null || true
done
chmod +x "$ROOTFS"/root/*.sh 2>/dev/null || true

echo "[*] Writing resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"

echo "[*] Installing enter helper at $ROOTFS/../enter-debian.sh"
cat > "$(dirname "$ROOTFS")/enter-debian.sh" <<ENTER
#!/system/bin/sh
# Enter the Debian chroot with /dev, /proc, /sys bind-mounted.
ROOTFS="$ROOTFS"
busybox mount --bind /dev     "\$ROOTFS/dev"     2>/dev/null || mount -o bind /dev     "\$ROOTFS/dev"
busybox mount --bind /dev/pts "\$ROOTFS/dev/pts" 2>/dev/null || mount -o bind /dev/pts "\$ROOTFS/dev/pts"
busybox mount --bind /proc    "\$ROOTFS/proc"    2>/dev/null || mount -o bind /proc    "\$ROOTFS/proc"
busybox mount --bind /sys     "\$ROOTFS/sys"     2>/dev/null || mount -o bind /sys     "\$ROOTFS/sys"
# Also bind the OSX-KVM working dir so qemu inside the chroot can see it.
mkdir -p "\$ROOTFS/data/local/osx-kvm"
busybox mount --bind /data/local/osx-kvm "\$ROOTFS/data/local/osx-kvm" 2>/dev/null \
  || mount -o bind /data/local/osx-kvm "\$ROOTFS/data/local/osx-kvm" 2>/dev/null || true
if [ "\$#" -gt 0 ]; then exec chroot "\$ROOTFS" /bin/bash -lc "\$*"; else exec chroot "\$ROOTFS" /bin/bash -l; fi
ENTER
chmod +x "$(dirname "$ROOTFS")/enter-debian.sh"

echo
echo "[done] Enter the chroot any time with:"
echo "    su -c $(dirname "$ROOTFS")/enter-debian.sh"
