#!/usr/bin/env bash
#
# setup-debian-chroot.sh
# Set up a real Debian (glibc) chroot on a rooted Android phone so we can run
# Debian's qemu-system-x86_64 (macOS guests are x86_64; host is aarch64, so
# this is TCG-only — no KVM across architectures).
#
# Run AS ROOT on the phone. Shared with the other QEMU modules in ios-tools.
# Bundles xz-arm64 because Android's toybox tar cannot decompress .xz archives.
set -eu

ROOTFS="${ROOTFS:-/data/local/debian}"
SUITE="${SUITE:-bookworm}"
ARCH="${ARCH:-arm64}"

echo "[*] Target rootfs: $ROOTFS  (Debian $SUITE $ARCH)"
if [ "$(id -u)" != "0" ]; then
  echo "    ERROR: run this as root (su)." >&2
  exit 1
fi

HERE=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------------------
# v1.1.2 / v1.0.2 rewrite of download + extract.
#
# Root cause of "can't create $ROOTFS/etc/resolv.conf: No such file or
# directory": the linuxcontainers.org Debian rootfs ships /etc/resolv.conf as an
# ABSOLUTE symlink to /run/systemd/resolve/stub-resolv.conf. Writing through it
# from the Android side follows the link to the phone's own /run/systemd/...,
# which does not exist, so the shell reports the error against resolv.conf even
# though the extract worked. We now remove that symlink before writing.
#
# Also hardened:
#   - the archive is extracted into a staging dir ($ROOTFS.staging) and only
#     moved into place after etc/os-release + usr/bin/sh exist,
#   - xz and tar run as separate steps so each exit code is checked + logged,
#   - any failure wipes the incomplete tree (after unmounting stale binds) and
#     exits non-zero with a clear message,
#   - re-runs clean leftover staging dirs / archives / half-extracted trees.
# ---------------------------------------------------------------------------

STAGING="${ROOTFS}.staging"
ARCHIVE="$(dirname "$ROOTFS")/debian-rootfs.tar.xz"
TARFILE="$(dirname "$ROOTFS")/debian-rootfs.tar"

log()  { echo "[*] $*"; }
fail() {
  echo "    ERROR: $*" >&2
  echo "    Nothing usable was left behind; fix the cause above and re-run step 1." >&2
  exit 1
}

# Unmount anything still bound under a dir (dev/proc/sys from enter-debian.sh)
# so a cleanup can never rm -rf through into the phone's real /dev or /sys.
unmount_under() {
  local d="$1" mp
  [ -d "$d" ] || return 0
  # deepest mount points first
  for mp in $(awk -v d="$d" '$2 == d || index($2, d"/") == 1 {print $2}' /proc/mounts 2>/dev/null | sort -r); do
    umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || busybox umount -l "$mp" 2>/dev/null || true
  done
  if awk -v d="$d" '$2 == d || index($2, d"/") == 1 {f=1} END {exit !f}' /proc/mounts 2>/dev/null; then
    echo "    ERROR: still-mounted paths under $d; refusing to delete it:" >&2
    awk -v d="$d" '$2 == d || index($2, d"/") == 1 {print "      " $2}' /proc/mounts >&2
    return 1
  fi
  return 0
}

wipe_dir() {
  local d="$1"
  [ -n "$d" ] && [ "$d" != "/" ] || return 1
  [ -e "$d" ] || [ -L "$d" ] || return 0
  unmount_under "$d" || return 1
  rm -rf "$d"
}

rootfs_ok() {
  # os-release is a relative symlink (../usr/lib/os-release) in Debian images;
  # -e follows it inside the tree, which is what we want.
  [ -e "$1/etc/os-release" ] && [ -e "$1/usr/lib/os-release" ] \
    && { [ -e "$1/usr/bin/sh" ] || [ -e "$1/bin/sh" ]; } \
    && [ -d "$1/etc" ]
}

resolve_rootfs_url() {
  if [ -n "${URL:-}" ]; then
    echo "$URL"
    return 0
  fi
  local base="https://images.linuxcontainers.org/images/debian/${SUITE}/arm64/default"
  local html latest
  if command -v curl >/dev/null 2>&1; then
    html=$(curl -fsSL --max-time 60 "$base/" 2>/dev/null || true)
  elif command -v wget >/dev/null 2>&1; then
    html=$(wget -qO- --timeout=60 "$base/" 2>/dev/null || true)
  else
    html=""
  fi
  latest=$(printf '%s\n' "$html" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | sort -u | tail -n 1)
  [ -n "$latest" ] || latest="20261018_11:44"
  echo "${base}/${latest}/rootfs.tar.xz"
}

download_rootfs() {
  local dest="$1" url="$2" rc
  rm -f "$dest" "${dest}.partial"
  if command -v curl >/dev/null 2>&1; then
    rc=0; curl -fL --retry 3 --retry-delay 2 -o "${dest}.partial" "$url" || rc=$?
    log "curl exit code: $rc"
  elif command -v wget >/dev/null 2>&1; then
    rc=0; wget -O "${dest}.partial" "$url" || rc=$?
    log "wget exit code: $rc"
  else
    echo "    ERROR: need curl or wget on device." >&2
    return 1
  fi
  if [ "$rc" != "0" ]; then rm -f "${dest}.partial"; return 1; fi
  mv -f "${dest}.partial" "$dest"
}

describe_archive() {
  local f="$1"
  log "archive: $(ls -l "$f" 2>&1 | head -n 1)"
  log "download size: $(wc -c < "$f" | tr -d ' ') bytes"
  if command -v file >/dev/null 2>&1; then
    log "file: $(file "$f" 2>&1 | head -n 1)"
  fi
  log "first bytes: $(dd if="$f" bs=16 count=1 2>/dev/null | od -An -tx1 | tr -s ' ' | head -n 1)"
}

verify_rootfs_archive() {
  local f="$1" min_bytes=5000000 sz magic
  [ -f "$f" ] || { echo "    ERROR: download missing: $f" >&2; return 1; }
  sz=$(wc -c < "$f" | tr -d ' ')
  if [ "$sz" -lt "$min_bytes" ]; then
    echo "    ERROR: rootfs download too small (${sz} bytes; expected >= ${min_bytes})." >&2
    echo "    Likely a bad URL or an HTML error page. First lines:" >&2
    head -c 300 "$f" 2>/dev/null | head -n 5 >&2 || true
    return 1
  fi
  magic=$(dd if="$f" bs=6 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  case "$magic" in
    fd377a585a00) log "OK: xz archive, ${sz} bytes" ;;
    1f8b*)        log "OK: gzip archive, ${sz} bytes" ;;
    *) echo "    ERROR: not an xz/gzip archive (magic=$magic)." >&2; return 1 ;;
  esac
}

find_xz() {
  if [ -x "$HERE/xz-arm64" ]; then echo "$HERE/xz-arm64"; return 0; fi
  if command -v xz >/dev/null 2>&1; then command -v xz; return 0; fi
  if command -v busybox >/dev/null 2>&1 && busybox xz --help >/dev/null 2>&1; then
    echo "busybox xz"; return 0
  fi
  return 1
}

# extract_rootfs ARCHIVE DESTDIR — decompress to a plain .tar first so the
# decompressor's and tar's exit codes are both visible (no pipe masking).
extract_rootfs() {
  local archive="$1" dest="$2" xzbin rc head2
  mkdir -p "$dest" || return 1
  rm -f "$TARFILE"
  head2=$(dd if="$archive" bs=2 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$head2" = "1f8b" ]; then
    log "decompressing gzip archive..."
    rc=0; gzip -dc "$archive" > "$TARFILE" 2>/dev/null || busybox gzip -dc "$archive" > "$TARFILE" || rc=$?
    log "gzip exit code: $rc"
  else
    if ! xzbin=$(find_xz); then
      echo "    ERROR: need xz to unpack rootfs.tar.xz (Android toybox tar cannot)." >&2
      echo "    Expected bundled xz-arm64 next to this script ($HERE)." >&2
      return 1
    fi
    [ "$xzbin" = "busybox xz" ] || chmod 0755 "$xzbin" 2>/dev/null || true
    log "decompressing with $xzbin ..."
    rc=0
    if [ "$xzbin" = "busybox xz" ]; then
      busybox xz -dc "$archive" > "$TARFILE" || rc=$?
    else
      "$xzbin" -dc "$archive" > "$TARFILE" || rc=$?
    fi
    log "xz exit code: $rc"
  fi
  if [ "$rc" != "0" ]; then rm -f "$TARFILE"; return 1; fi
  log "tar size: $(wc -c < "$TARFILE" | tr -d ' ') bytes"
  log "extracting tar into $dest ..."
  rc=0
  ( cd "$dest" && tar -xf "$TARFILE" ) || rc=$?
  log "tar exit code: $rc"
  rm -f "$TARFILE"
  [ "$rc" = "0" ] || return 1
  log "extracted top level: $(ls "$dest" 2>/dev/null | tr '\n' ' ')"
  return 0
}

# ---------- clean bad state from earlier runs ----------
rm -f "$ARCHIVE" "${ARCHIVE}.partial" "$TARFILE" \
      "$ROOTFS/rootfs.tar.xz" "$ROOTFS/rootfs.tar.xz.partial" 2>/dev/null || true
if [ -e "$STAGING" ]; then
  log "removing leftover staging dir $STAGING"
  wipe_dir "$STAGING" || fail "could not remove $STAGING"
fi
if [ -e "$ROOTFS" ] && ! rootfs_ok "$ROOTFS"; then
  log "incomplete rootfs at $ROOTFS (no etc/os-release / usr/bin/sh) - wiping for a clean retry"
  wipe_dir "$ROOTFS" || fail "could not clean $ROOTFS"
fi

# ---------- download + extract (only if no good rootfs yet) ----------
if ! rootfs_ok "$ROOTFS"; then
  mkdir -p "$(dirname "$ROOTFS")"
  log "resolving Debian rootfs URL..."
  RESOLVED=$(resolve_rootfs_url)
  log "URL: $RESOLVED"
  log "downloading Debian rootfs (~95 MB; needs Wi-Fi)..."
  if ! download_rootfs "$ARCHIVE" "$RESOLVED"; then
    rm -f "$ARCHIVE" "${ARCHIVE}.partial"
    fail "download failed (network / URL)."
  fi
  describe_archive "$ARCHIVE"
  if ! verify_rootfs_archive "$ARCHIVE"; then
    rm -f "$ARCHIVE"
    fail "downloaded file is not a usable rootfs archive."
  fi
  log "extracting into staging dir (takes a minute)..."
  if ! extract_rootfs "$ARCHIVE" "$STAGING"; then
    rm -f "$ARCHIVE" "$TARFILE"
    wipe_dir "$STAGING" || true
    fail "extract failed (see xz/tar exit codes above). Check free space: $(df -h "$(dirname "$ROOTFS")" 2>/dev/null | tail -n 1)"
  fi
  rm -f "$ARCHIVE"
  if ! rootfs_ok "$STAGING"; then
    echo "    staging contents: $(ls -la "$STAGING" 2>&1 | head -n 20)" >&2
    wipe_dir "$STAGING" || true
    fail "extract finished but etc/os-release or usr/bin/sh is missing - bad archive?"
  fi
  wipe_dir "$ROOTFS" || fail "could not clear old $ROOTFS"
  mv "$STAGING" "$ROOTFS" || { wipe_dir "$STAGING" || true; fail "could not move staging dir into $ROOTFS"; }
  log "rootfs in place: $(cat "$ROOTFS/usr/lib/os-release" 2>/dev/null | grep '^PRETTY_NAME=' || echo '?')"
else
  log "existing rootfs looks good ($ROOTFS/etc/os-release present) - not re-downloading"
fi

# From here on $ROOTFS is a verified Debian tree.
mkdir -p "$ROOTFS/etc" "$ROOTFS/root" "$ROOTFS/usr/local/bin" \
         "$ROOTFS/dev" "$ROOTFS/dev/pts" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/tmp"
chmod 1777 "$ROOTFS/tmp" 2>/dev/null || true

echo "[*] Copying helper scripts into chroot /root (if present)"
for f in install-qemu-x86.sh setup-osx-kvm.sh fetch-sonoma.sh boot-macos14.sh; do
  [ -f "$HERE/$f" ] && cp -f "$HERE/$f" "$ROOTFS/root/" 2>/dev/null || true
done
[ -x "$HERE/xz-arm64" ] && cp -f "$HERE/xz-arm64" "$ROOTFS/usr/local/bin/xz" 2>/dev/null || true
chmod +x "$ROOTFS"/root/*.sh 2>/dev/null || true

echo "[*] Writing resolv.conf"
# Debian images ship etc/resolv.conf as an absolute symlink into
# /run/systemd/... ; remove it so we write a real file inside the chroot
# instead of following the link onto the Android host.
rm -f "$ROOTFS/etc/resolv.conf"
mkdir -p "$ROOTFS/etc"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf" \
  || fail "could not write $ROOTFS/etc/resolv.conf"

echo "[*] Installing enter helper at $ROOTFS/../enter-debian.sh"
cat > "$(dirname "$ROOTFS")/enter-debian.sh" <<ENTER
#!/system/bin/sh
# Enter the Debian chroot with /dev, /proc, /sys bind-mounted.
ROOTFS="$ROOTFS"
[ -e "\$ROOTFS/etc/os-release" ] || { echo "Debian chroot not set up at \$ROOTFS - run step 1 first"; exit 1; }
mkdir -p "\$ROOTFS/dev" "\$ROOTFS/proc" "\$ROOTFS/sys"
grep -q " \$ROOTFS/dev " /proc/mounts || { busybox mount --bind /dev "\$ROOTFS/dev" 2>/dev/null || mount -o bind /dev "\$ROOTFS/dev"; }
grep -q " \$ROOTFS/dev/pts " /proc/mounts || { busybox mount --bind /dev/pts "\$ROOTFS/dev/pts" 2>/dev/null || mount -o bind /dev/pts "\$ROOTFS/dev/pts"; }
grep -q " \$ROOTFS/proc " /proc/mounts || { busybox mount --bind /proc "\$ROOTFS/proc" 2>/dev/null || mount -o bind /proc "\$ROOTFS/proc"; }
grep -q " \$ROOTFS/sys " /proc/mounts || { busybox mount --bind /sys "\$ROOTFS/sys" 2>/dev/null || mount -o bind /sys "\$ROOTFS/sys"; }
# Also bind the OSX-KVM working dir so qemu inside the chroot can see it.
mkdir -p "\$ROOTFS/data/local/osx-kvm"
busybox mount --bind /data/local/osx-kvm "\$ROOTFS/data/local/osx-kvm" 2>/dev/null \
  || mount -o bind /data/local/osx-kvm "\$ROOTFS/data/local/osx-kvm" 2>/dev/null || true
# Start from a clean Debian environment: Android's PATH (/system/bin...) does
# not exist inside the chroot and made /etc/profile print "id: command not found".
CENV="/usr/bin/env -i HOME=/root TERM=\${TERM:-xterm-256color} LANG=C.UTF-8 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [ "\$#" -gt 0 ]; then exec chroot "\$ROOTFS" \$CENV /bin/bash -lc "\$*"; else exec chroot "\$ROOTFS" \$CENV /bin/bash -l; fi
ENTER
chmod +x "$(dirname "$ROOTFS")/enter-debian.sh"

# ---------- install + update Debian packages inside the chroot ----------
# Android kernels only let the inet group (3003) open sockets, so apt's
# unprivileged _apt download user can fail with "Could not create socket".
# Download as root instead.
mkdir -p "$ROOTFS/etc/apt/apt.conf.d"
printf 'APT::Sandbox::User "root";\n' > "$ROOTFS/etc/apt/apt.conf.d/01android-sandbox" \
  || fail "could not write apt sandbox config"

ENTER_SH="$(dirname "$ROOTFS")/enter-debian.sh"
apt_fail() {
  echo "    ERROR: $*" >&2
  echo "    The Debian rootfs itself is installed; check Wi-Fi/DNS and re-run step 1 to retry the update." >&2
  exit 1
}
log "Updating Debian: apt-get update"
ok=0
for i in 1 2 3; do
  if sh "$ENTER_SH" 'DEBIAN_FRONTEND=noninteractive apt-get update'; then ok=1; break; fi
  log "apt-get update failed (attempt $i/3), retrying in 5s..."
  sleep 5
done
[ "$ok" = 1 ] || apt_fail "apt-get update failed inside the chroot (see apt errors above)."
log "Updating Debian: apt-get upgrade -y"
sh "$ENTER_SH" 'DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade' \
  || apt_fail "apt-get upgrade failed inside the chroot (see apt errors above)."
log "Debian is installed and up to date: $(grep '^PRETTY_NAME=' "$ROOTFS/usr/lib/os-release" 2>/dev/null || echo '?')"

echo
echo "[done] Enter the chroot any time with:"
echo "    su -c $(dirname "$ROOTFS")/enter-debian.sh"
