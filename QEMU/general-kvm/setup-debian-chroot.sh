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
# Bundles xz-arm64 because Android's toybox tar cannot decompress .xz archives.
set -eu

ROOTFS="${ROOTFS:-/data/local/debian}"
SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"
# Default URL resolved at runtime from linuxcontainers.org (see resolve_rootfs_url).
# Override with URL=... if you have a mirror. Old debuerreotype dist-arm64 URL is dead.

echo "[*] Target rootfs: $ROOTFS  (Debian $SUITE $ARCH)"
if [ "$(id -u)" != "0" ]; then
  echo "    ERROR: run this as root (su)." >&2
  exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)

resolve_rootfs_url() {
  if [ -n "${URL:-}" ]; then
    echo "$URL"
    return 0
  fi
  local base="https://images.linuxcontainers.org/images/debian/${SUITE}/arm64/default"
  local html dates latest
  if command -v curl >/dev/null 2>&1; then
    html=$(curl -fsSL --max-time 60 "$base/" 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    html=$(wget -qO- --timeout=60 "$base/" 2>/dev/null || true)
  else
    html=""
  fi
  dates=$(printf '%s\n' "$html" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | sort -u)
  latest=$(printf '%s\n' "$dates" | tail -n 1)
  if [ -z "$latest" ]; then
    latest="20261018_11:44"
  fi
  echo "${base}/${latest}/rootfs.tar.xz"
}

download_rootfs() {
  local dest="$1" url="$2"
  rm -f "$dest" "${dest}.partial"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "${dest}.partial" "$url" \
      || { rm -f "${dest}.partial"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${dest}.partial" "$url" \
      || { rm -f "${dest}.partial"; return 1; }
  else
    echo "    ERROR: need curl or wget on device." >&2
    return 1
  fi
  mv -f "${dest}.partial" "$dest"
}

verify_rootfs_archive() {
  local f="$1"
  local min_bytes=5000000
  local sz magic
  if [ ! -f "$f" ]; then
    echo "    ERROR: download missing: $f" >&2
    return 1
  fi
  sz=$(wc -c < "$f" | tr -d ' ')
  if [ "$sz" -lt "$min_bytes" ]; then
    echo "    ERROR: rootfs download too small (${sz} bytes; expected >= ${min_bytes})." >&2
    echo "    Likely a bad URL or an HTML error page. Removing partial/bad file." >&2
    return 1
  fi
  magic=$(dd if="$f" bs=6 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    fd377a585a00) ;;
    1f8b*) echo "    NOTE: gzip archive detected." ;;
    *)
      echo "    ERROR: not an xz/gzip archive (magic=$magic). Removing bad file." >&2
      return 1
      ;;
  esac
  echo "    OK: archive size=${sz} bytes, type magic=$magic"
  return 0
}

find_xz() {
  if [ -x "$HERE/xz-arm64" ]; then echo "$HERE/xz-arm64"; return 0; fi
  if command -v xz >/dev/null 2>&1; then command -v xz; return 0; fi
  if command -v busybox >/dev/null 2>&1 && busybox xz --help >/dev/null 2>&1; then
    echo "busybox xz"; return 0
  fi
  return 1
}

extract_rootfs() {
  local archive="$1"
  local xzbin
  local head2
  head2=$(dd if="$archive" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$head2" in
    1f8b)
      echo "[*] Extracting gzip rootfs with system tar..."
      tar -xzf "$archive" || return 1
      return 0
      ;;
  esac
  if ! xzbin=$(find_xz); then
    echo "    ERROR: need xz to unpack rootfs.tar.xz (Android toybox tar cannot)." >&2
    echo "    Expected bundled xz-arm64 next to this script." >&2
    return 1
  fi
  echo "[*] Extracting with $xzbin | tar ..."
  if [ "$xzbin" = "busybox xz" ]; then
    busybox xz -dc "$archive" | tar -xf - || return 1
  else
    "$xzbin" -dc "$archive" | tar -xf - || return 1
  fi
  return 0
}

mkdir -p "$ROOTFS"

# If a previous run left junk without a real rootfs, wipe and retry.
if [ -d "$ROOTFS" ] && [ ! -e "$ROOTFS/etc/os-release" ]; then
  if [ "$(ls -A "$ROOTFS" 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
    echo "[*] Incomplete rootfs detected (no /etc/os-release) — cleaning for retry..."
    # Only remove contents, not the mount point itself.
    find "$ROOTFS" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || \
      rm -rf "$ROOTFS"/* "$ROOTFS"/.[!.]* 2>/dev/null || true
  fi
fi

if [ ! -e "$ROOTFS/etc/os-release" ]; then
  echo "[*] Resolving Debian rootfs URL..."
  RESOLVED=$(resolve_rootfs_url)
  echo "    URL: $RESOLVED"
  echo "[*] Downloading Debian rootfs (multi-MB; needs Wi-Fi)..."
  cd "$ROOTFS"
  if ! download_rootfs rootfs.tar.xz "$RESOLVED"; then
    echo "    ERROR: download failed. Cleaned partial files; re-run when network is OK." >&2
    rm -f rootfs.tar.xz rootfs.tar.xz.partial
    exit 1
  fi
  if ! verify_rootfs_archive rootfs.tar.xz; then
    rm -f rootfs.tar.xz rootfs.tar.xz.partial
    # Also wipe any partial extract
    find "$ROOTFS" -mindepth 1 -maxdepth 1 ! -name 'rootfs.tar.xz' -exec rm -rf {} + 2>/dev/null || true
    exit 1
  fi
  echo "[*] Extracting (this takes a minute)..."
  if ! extract_rootfs rootfs.tar.xz; then
    echo "    ERROR: extract failed. Removing archive and partial tree so re-run works." >&2
    rm -f rootfs.tar.xz rootfs.tar.xz.partial
    find "$ROOTFS" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    exit 1
  fi
  rm -f rootfs.tar.xz rootfs.tar.xz.partial
  if [ ! -e "$ROOTFS/etc/os-release" ]; then
    echo "    ERROR: extract finished but /etc/os-release missing — bad archive?" >&2
    find "$ROOTFS" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    exit 1
  fi
fi

echo "[*] Copying helper scripts into chroot /root (if present)"
for f in install-qemu.sh run-arm64-linux.sh run-woa.sh; do
  [ -f "$HERE/$f" ] && cp -f "$HERE/$f" "$ROOTFS/root/" 2>/dev/null || true
done
# Also stage xz into chroot in case scripts need it later
[ -x "$HERE/xz-arm64" ] && cp -f "$HERE/xz-arm64" "$ROOTFS/usr/local/bin/xz" 2>/dev/null || true
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
