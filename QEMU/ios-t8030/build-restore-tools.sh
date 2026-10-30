#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# build-restore-tools.sh -- run INSIDE the Debian chroot. Builds everything the
# automatic restore step (restore-ios.sh) needs, into /opt/inferno-restore:
#
#   * libimobiledevice stack from source at pinned commits (ChefKiss: "the
#     latest releases are outdated, we must build the tools from source"):
#     libplist, libimobiledevice-glue, libusbmuxd, libtatsu, libimobiledevice,
#     libirecovery, usbmuxd, idevicerestore (+ ChefKiss's idevicerestore.patch)
#   * libusb 1.0.29 built WITHOUT udev, so usbmuxd sees hotplug events through
#     kernel netlink inside the tiny USB-host VM (there is no udevd there)
#   * InfernoFSPatcher (dyld cache patch needed before restore stage 2)
#   * the USB-host ("companion") VM: Debian's own arm64 kernel (apt), the
#     linux-apfs-rw module built against its headers, and a busybox initramfs
#
# Why a USB-host VM at all: Inferno's emulated iPhone USB port can only be
# plugged into another QEMU's "usb-tcp-remote" device (ChefKiss "Companion VM
# Setup"). There is no host-side USB stack on Android to plug it into, so a
# small aarch64 "virt" VM (same Inferno qemu-system-aarch64, TCG) plays the
# USB host and runs usbmuxd; idevicerestore runs natively here in the chroot.
#   * vhci-bridge: when the Larry kernel has USBIP VHCI, exports Inferno's
#     usb-tcp device into this chroot so usbmuxd needs no companion VM
#
# Re-runs are cheap: every part is skipped if it is already built at the same
# pinned commit. FORCE=1 rebuilds everything.
set -eu
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

PREFIX="${PREFIX:-/opt/inferno-restore}"
SRC="${SRC_DIR:-/root/restore-tools-src}"
HERE=$(cd "$(dirname "$0")" && pwd)
JOBS="${JOBS:-$(nproc)}"

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# name  repo-url  pinned-commit (libimobiledevice master, 2026-10-19)
REPOS="
libplist              https://github.com/libimobiledevice/libplist              fe3dc34dc3484006e12b403f7ceb06f0ad40b6f4
libimobiledevice-glue https://github.com/libimobiledevice/libimobiledevice-glue 10ddafa16458a012bcbd3e83a6ab36a032dc84d8
libusbmuxd            https://github.com/libimobiledevice/libusbmuxd            93eb168bf6b07472d17781328c21df0c60300524
libtatsu              https://github.com/libimobiledevice/libtatsu              e7d6ad13ef928aa609d0ccdfc586f7d6e8e049bf
libimobiledevice      https://github.com/libimobiledevice/libimobiledevice      fa0f79190142bc309307967c058f89c1b36eb6b8
libirecovery          https://github.com/libimobiledevice/libirecovery          93c117c29b1f6669bc4ceca8b84e1df06449fe33
usbmuxd               https://github.com/libimobiledevice/usbmuxd               3ded00c9985a5108cfc7591a309f9a23d57a8cba
idevicerestore        https://github.com/libimobiledevice/idevicerestore        4b3e847e1d9a1210049a9e3f1d1caa38650c6617
InfernoFSPatcher      https://git.chefkiss.dev/AppleHax/InfernoFSPatcher        3008aaaa0909824a71ee3040c9edc58703c250f5
linux-apfs-rw         https://github.com/linux-apfs/linux-apfs-rw               03187127cd2e62cf78321cdb942eb3a7b17981f9
"
LIBUSB_VER=1.0.29
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v$LIBUSB_VER/libusb-$LIBUSB_VER.tar.bz2"
LIBUSB_SHA256=5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85

# Debian bookworm (arm64) packages needed here. setup-build-deps.sh (step 2)
# installs the same list; this re-check means step 2 does not have to be re-run.
APT_PKGS="git build-essential pkg-config autoconf automake libtool libtool-bin m4 \
  libssl-dev libcurl4-openssl-dev libzip-dev zlib1g-dev libreadline-dev \
  busybox-static cpio kmod usbutils bc bison flex libelf-dev \
  curl ca-certificates xz-utils bzip2 python3 file \
  dnsmasq-base nftables tcpdump"

retry() { local n="$1"; shift; local i; for i in $(seq 1 "$n"); do "$@" && return 0; warn "attempt $i/$n failed: $*"; sleep $((i * 5)); done; return 1; }

apt_ok() { [ "$(dpkg-query -W -f='${Status}\n' "$@" 2>/dev/null | grep -c 'install ok installed')" = "$#" ]; }

ensure_apt() {
  # shellcheck disable=SC2086
  if apt_ok $APT_PKGS; then log "apt packages already installed"; return 0; fi
  log "installing apt packages: $APT_PKGS"
  retry 3 apt-get update || die "apt-get update failed"
  # shellcheck disable=SC2086
  if ! retry 3 apt-get install -y --no-install-recommends $APT_PKGS; then
    dpkg --configure -a || true; apt-get -f install -y || true
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends $APT_PKGS || die "apt-get install failed - see the package error above"
  fi
}

# fetch NAME URL COMMIT -> $SRC/NAME at exactly COMMIT (git, else GitHub tarball)
fetch() {
  local name="$1" url="$2" ref="$3" d="$SRC/$1"
  if [ -d "$d/.git" ] && [ "$(git -C "$d" rev-parse HEAD 2>/dev/null)" = "$ref" ]; then
    git -C "$d" reset -q --hard && git -C "$d" clean -qfdx && return 0
  fi
  if [ -f "$d/.ios-tools-ref" ] && [ "$(cat "$d/.ios-tools-ref")" = "$ref" ]; then return 0; fi
  rm -rf "$d"; mkdir -p "$d"
  local i
  for i in 1 2 3 4; do
    if git -C "$d" init -q && git -C "$d" -c http.version=HTTP/1.1 fetch -q --depth 1 "$url" "$ref" \
       && git -C "$d" checkout -q FETCH_HEAD; then
      [ "$(git -C "$d" rev-parse HEAD)" = "$ref" ] && return 0
    fi
    warn "git fetch of $name failed (attempt $i/4)"; rm -rf "$d"; mkdir -p "$d"; sleep $((i * 5))
  done
  case "$url" in
    https://github.com/*)
      log "falling back to the GitHub source tarball for $name"
      if retry 3 curl -fL --retry 3 -o "$SRC/$name.tar.gz" "$url/archive/$ref.tar.gz"; then
        tar -xzf "$SRC/$name.tar.gz" -C "$d" --strip-components=1 && rm -f "$SRC/$name.tar.gz"
        # git-version-gen falls back to .tarball-version without a .git dir
        [ -f "$d/NEWS" ] && sed -n '1,/RE/s/Version \(.*\)/\1/p' "$d/NEWS" | head -n1 > "$d/.tarball-version"
        echo "$ref" > "$d/.ios-tools-ref"
        return 0
      fi ;;
  esac
  die "could not download $name ($url @ $ref)"
}

repo_field() { echo "$REPOS" | awk -v n="$1" -v f="$2" '$1==n{print $f}'; }
stamp_ok() { [ "${FORCE:-0}" != 1 ] && [ "$(cat "$PREFIX/.built-$1" 2>/dev/null)" = "$2" ]; }
stamp()    { mkdir -p "$PREFIX"; echo "$2" > "$PREFIX/.built-$1"; }

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export LDFLAGS="-Wl,-rpath,$PREFIX/lib -L$PREFIX/lib"
export CPPFLAGS="-I$PREFIX/include"

autotools_build() {
  local name="$1"; shift
  local ref url sref; url=$(repo_field "$name" 2); ref=$(repo_field "$name" 3); sref="$ref"
  # idevicerestore: rebuild when our TCG timeout patch changes
  [ "$name" = idevicerestore ] && sref="$ref tcg1"
  [ "$name" = libirecovery ] && sref="$ref nousb1"
  if stamp_ok "$name" "$sref"; then log "$name already built (${ref:0:12})"; return 0; fi
  log "building $name @ ${ref:0:12}"
  fetch "$name" "$url" "$ref"
  if [ "$name" = libirecovery ]; then
    # ios-tools: if libusb cannot start in this chroot (no usbfs / uevent
    # netlink denied on Android), idevicerestore crashed (SIGSEGV) in
    # libirecovery's event thread before even looking at usbmuxd.
    ( cd "$SRC/$name" && git apply "$HERE/libirecovery-no-usb.patch" 2>/dev/null \
        || patch -p1 --forward < "$HERE/libirecovery-no-usb.patch" ) \
      || die "could not apply libirecovery-no-usb.patch"
    grep -q 'usb_ok' "$SRC/$name/src/libirecovery.c" || die "libirecovery patch not present after apply"
  fi
  if [ "$name" = idevicerestore ]; then
    # ChefKiss Companion VM Setup: "For idevicerestore, you must apply the
    # following small patch" (https://chefkiss.dev/Extras/Inferno/idevicerestore.patch).
    # The emulated iPhone reports a *DEV hardware model; map it to *AP.
    ( cd "$SRC/$name" && git apply "$HERE/idevicerestore-inferno.patch" 2>/dev/null \
        || patch -p1 --forward < "$HERE/idevicerestore-inferno.patch" ) \
      || die "could not apply idevicerestore-inferno.patch"
    grep -q 'strstr(model, "DEV")' "$SRC/$name/src/restore.c" || die "idevicerestore patch not present after apply"
    # ios-tools: longer USB/ASR timeouts - everything is far slower under TCG
    # (ASR's 5 s receive default, 60 s ASR connect, 10 s reconnect window).
    ( cd "$SRC/$name" && git apply "$HERE/idevicerestore-tcg-timeouts.patch" 2>/dev/null \
        || patch -p1 --forward < "$HERE/idevicerestore-tcg-timeouts.patch" ) \
      || die "could not apply idevicerestore-tcg-timeouts.patch"
    grep -q 'IDEVICERESTORE_ASR_TIMEOUT_MS' "$SRC/$name/src/asr.c" || die "idevicerestore TCG patch not present after apply"
  fi
  ( cd "$SRC/$name" \
    && NOCONFIGURE=1 ./autogen.sh \
    && ./configure --prefix="$PREFIX" --disable-static "$@" \
    && make -j"$JOBS" \
    && make install ) || die "$name build failed (see the compiler output above)"
  stamp "$name" "$sref"
}

build_libusb() {
  if stamp_ok libusb "$LIBUSB_VER-noudev"; then log "libusb $LIBUSB_VER (no udev) already built"; return 0; fi
  log "building libusb $LIBUSB_VER without udev"
  mkdir -p "$SRC"; rm -rf "$SRC/libusb-$LIBUSB_VER" "$SRC/libusb.tar.bz2"
  retry 3 curl -fL --retry 3 -o "$SRC/libusb.tar.bz2" "$LIBUSB_URL" || die "libusb download failed"
  echo "$LIBUSB_SHA256  $SRC/libusb.tar.bz2" | sha256sum -c - >/dev/null || die "libusb checksum mismatch"
  tar -xjf "$SRC/libusb.tar.bz2" -C "$SRC"
  ( cd "$SRC/libusb-$LIBUSB_VER" && ./configure --prefix="$PREFIX" --disable-static --disable-udev \
    && make -j"$JOBS" && make install ) || die "libusb build failed"
  stamp libusb "$LIBUSB_VER-noudev"
}

build_fspatcher() {
  local ref url; url=$(repo_field InfernoFSPatcher 2); ref=$(repo_field InfernoFSPatcher 3)
  if stamp_ok InfernoFSPatcher "$ref" && [ -x "$PREFIX/bin/inferno_fs_patcher" ]; then log "InfernoFSPatcher already built"; return 0; fi
  log "building InfernoFSPatcher @ ${ref:0:12}"
  fetch InfernoFSPatcher "$url" "$ref"
  mkdir -p "$PREFIX/bin"
  g++ -std=c++17 -O2 -o "$PREFIX/bin/inferno_fs_patcher" "$SRC/InfernoFSPatcher/src/main.cpp" \
    || die "InfernoFSPatcher build failed"
  stamp InfernoFSPatcher "$ref"
}

# ---------- USB-host VM: Debian kernel + apfs module + initramfs --------------
CVM="$PREFIX/companion"
# Modules the VM needs (Debian builds all of these as =m; deps are resolved
# from modules.dep). virtio-pci/net/blk + 9p for the shared folders, EHCI for
# the emulated iPhone, apfs for the restored System volume.
# nf_tables/nft_chain_nat/nft_masq: NAT for the routed reverse tethering
# (companion-vm.sh net); "?" marks modules the VM can live without.
WANT_MODS="virtio_pci virtio_net virtio_blk 9pnet_virtio 9p usbcore ehci_hcd ehci_pci cdc_ncm bridge ?nf_tables ?nft_chain_nat ?nft_masq"

# cdc_ncm for the USB-host VM with the link up from the start. The stock
# driver (FLAG_LINK_INTR) keeps carrier off until the device sends a CDC
# NETWORK_CONNECTION notification; if the emulated iPhone never sends one,
# nothing it sends gets through. Real notifications are still honoured. The
# source is the exact upstream stable file for the Debian kernel (version from
# its changelog), built against the Debian headers like apfs.ko. Prints the
# .ko path on success; any failure keeps the stock module. NCM_STOCK=1 skips it.
build_ncm_linkup() {
  local deb="$1" kdir="$2" kver="$3" w="$SRC/cdc_ncm_linkup" cl up
  [ "${NCM_STOCK:-0}" = 1 ] && return 1
  # Upstream version: the image package's Version (6.1.176-1), else the
  # first changelog line (linux-signed-arm64 (6.1.176+1) ...).
  up=$(dpkg-deb -f "$(ls "$deb"/../linux-image-*.deb 2>/dev/null | head -n1)" Version 2>/dev/null \
       | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$up" ]; then
    cl=$(ls "$deb"/usr/share/doc/linux-image-*/changelog.Debian.gz 2>/dev/null | head -n1)
    up=$( [ -n "$cl" ] && zcat "$cl" | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  fi
  [ -n "$up" ] || { warn "cdc_ncm link-up: kernel upstream version unknown - stock cdc_ncm"; return 1; }
  rm -rf "$w"; mkdir -p "$w"
  retry 3 curl -fsSL -o "$w/cdc_ncm.c" \
    "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain/drivers/net/usb/cdc_ncm.c?h=v$up" \
    || { warn "cdc_ncm link-up: could not fetch cdc_ncm.c v$up - stock cdc_ncm"; return 1; }
  python3 - "$w/cdc_ncm.c" <<'PYNCM' || { warn "cdc_ncm link-up: patch did not apply to v$up - stock cdc_ncm"; return 1; }
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r"static const struct driver_info cdc_ncm_info = \{.*?\n\};", s, re.S)
if not m or "FLAG_LINK_INTR" not in m.group(0):
    sys.exit(1)
blk = re.sub(r"\s*\|\s*FLAG_LINK_INTR", "", m.group(0))
open(p, "w").write(s[:m.start()] + blk + s[m.end():])
PYNCM
  echo 'obj-m += cdc_ncm.o' > "$w/Makefile"
  make -C "$kdir" M="$w" -j"$JOBS" modules >&2 \
    || { warn "cdc_ncm link-up: module build failed - stock cdc_ncm"; return 1; }
  [ "$(modinfo -F vermagic "$w/cdc_ncm.ko" 2>/dev/null | awk '{print $1}')" = "$kver" ] \
    || { warn "cdc_ncm link-up: vermagic mismatch - stock cdc_ncm"; return 1; }
  log "cdc_ncm link-up module built from upstream v$up (carrier on without a NETWORK_CONNECTION notification)" >&2
  echo "$w/cdc_ncm.ko"
}

build_companion() {
  local kpkg kver
  kpkg=$(apt-cache depends linux-image-arm64 2>/dev/null | sed -n 's/^ *Depends: \(linux-image-[0-9][^ ]*\)$/\1/p' | head -n1)
  [ -n "$kpkg" ] || { retry 3 apt-get update >/dev/null || true;
    kpkg=$(apt-cache depends linux-image-arm64 2>/dev/null | sed -n 's/^ *Depends: \(linux-image-[0-9][^ ]*\)$/\1/p' | head -n1); }
  [ -n "$kpkg" ] || die "could not resolve Debian's current arm64 kernel package (apt-cache depends linux-image-arm64)"
  kver=${kpkg#linux-image-}
  local apfsref; apfsref=$(repo_field linux-apfs-rw 3)
  if stamp_ok companion "$kver $apfsref v6" && [ -s "$CVM/vmlinuz" ] && [ -s "$CVM/initrd.img" ]; then
    log "USB-host VM kernel/initramfs already built ($kver)"; return 0
  fi
  log "USB-host VM: Debian kernel $kver"
  local w="$SRC/companion"; rm -rf "$w"; mkdir -p "$w/deb" "$CVM"
  ( cd "$w" && retry 3 apt-get download "$kpkg" ) || die "apt-get download $kpkg failed"
  dpkg-deb -x "$w"/linux-image-*.deb "$w/deb" || die "could not unpack $kpkg"
  [ -s "$w/deb/boot/vmlinuz-$kver" ] || die "no vmlinuz-$kver in $kpkg"
  local mdir="$w/deb/lib/modules/$kver"
  [ -d "$mdir" ] || mdir="$w/deb/usr/lib/modules/$kver"
  [ -f "$mdir/modules.dep" ] || depmod -b "$w/deb" "$kver" || true
  [ -f "$mdir/modules.dep" ] || die "no modules.dep for $kver"

  log "building linux-apfs-rw @ ${apfsref:0:12} against linux-headers-$kver"
  if ! dpkg-query -W -f='${Status}' "linux-headers-$kver" 2>/dev/null | grep -q 'install ok installed'; then
    retry 3 apt-get install -y --no-install-recommends "linux-headers-$kver" || die "apt-get install linux-headers-$kver failed"
  fi
  local kdir="/usr/src/linux-headers-$kver"
  [ -d "$kdir" ] || die "kernel headers missing at $kdir"
  fetch linux-apfs-rw "$(repo_field linux-apfs-rw 2)" "$apfsref"
  ( cd "$SRC/linux-apfs-rw" && { [ -d .git ] || git init -q; } && ./genver.sh \
    && make -C "$kdir" M="$SRC/linux-apfs-rw" -j"$JOBS" modules ) || die "linux-apfs-rw module build failed"
  [ -s "$SRC/linux-apfs-rw/apfs.ko" ] || die "apfs.ko was not produced"
  local vm; vm=$(modinfo -F vermagic "$SRC/linux-apfs-rw/apfs.ko" 2>/dev/null | awk '{print $1}')
  [ "$vm" = "$kver" ] || die "apfs.ko vermagic '$vm' does not match kernel $kver"

  # Resolve module dependencies (deps first) from modules.dep, plus softdeps
  # ("pre:") via modules.softdep/modules.alias. apfs needs libcrc32c, whose init
  # allocates the "crc32c" crypto hash; with no modprobe in the initramfs that is
  # crc32c_generic and must be loaded first (v1.4.7 missed it -> apfs failed).
  local apfsdeps order
  apfsdeps=$(modinfo -F depends "$SRC/linux-apfs-rw/apfs.ko" | tr ',' ' ')
  order=$(python3 - "$mdir" $WANT_MODS crc32c_generic $apfsdeps <<'PY'
import os, sys
mdir, want = sys.argv[1], sys.argv[2:]
norm = lambda n: os.path.basename(n).split(".ko")[0].replace("-", "_")
builtin = set()
try:
    for line in open(os.path.join(mdir, "modules.builtin")):
        builtin.add(norm(line.strip()))
except OSError:
    pass
deps = {}
for line in open(os.path.join(mdir, "modules.dep")):
    mod, _, rest = line.partition(":")
    deps[mod.strip()] = rest.split()
byname = {norm(m): m for m in deps}
alias = {}
try:
    for line in open(os.path.join(mdir, "modules.alias")):
        f = line.split()
        if len(f) == 3 and f[0] == "alias": alias.setdefault(f[1].replace("-", "_"), norm(f[2]))
except OSError:
    pass
soft = {}
try:
    for line in open(os.path.join(mdir, "modules.softdep")):
        f = line.split()
        if len(f) > 2 and f[0] == "softdep":
            pre, mode = [], None
            for t in f[2:]:
                if t in ("pre:", "post:"): mode = t
                elif mode == "pre:": pre.append(t)
            soft[f[1].replace("-", "_")] = pre
except OSError:
    pass
soft.setdefault("libcrc32c", ["crc32c"])
alias.setdefault("crc32c", "crc32c_generic")
out, seen = [], set()
def visit(m):
    if m in seen: return
    seen.add(m)
    for p in soft.get(norm(m), []):
        p = p.replace("-", "_"); p = p if p in byname else alias.get(p, p)
        if p in byname: visit(byname[p])
    for d in deps.get(m, []): visit(d)
    out.append(m)
for n in want:
    optional = n.startswith("?")
    n = n.lstrip("?").replace("-", "_")
    if n not in byname:
        if n in builtin or optional:
            continue  # built into the kernel (=y), or not needed
        sys.exit("missing module: " + n)
    visit(byname[n])
print("\n".join(out))
PY
) || die "could not resolve kernel modules: $order"
  local ird="$w/initrd"; mkdir -p "$ird/bin" "$ird/modules" "$ird/proc" "$ird/sys" "$ird/dev" "$ird/host"
  : > "$ird/modules/order"
  local m b
  for m in $order; do
    b=$(basename "$m"); b=${b%.ko*}
    case "$m" in
      *.ko.xz) xz -dc "$mdir/$m" > "$ird/modules/$b.ko" ;;
      *.ko.zst) zstd -dcq "$mdir/$m" > "$ird/modules/$b.ko" ;;
      *) cp "$mdir/$m" "$ird/modules/$b.ko" ;;
    esac
    echo "$b" >> "$ird/modules/order"
  done
  grep -qx crc32c_generic "$ird/modules/order" || grep -q crc32c_generic "$mdir/modules.builtin" 2>/dev/null \
    || die "crc32c_generic missing from the USB-host VM initramfs - apfs would fail to load (libcrc32c needs it)"
  cp "$SRC/linux-apfs-rw/apfs.ko" "$ird/modules/apfs.ko"; echo apfs >> "$ird/modules/order"
  local ncm
  if ncm=$(build_ncm_linkup "$w/deb" "$kdir" "$kver") && [ -f "$ird/modules/cdc_ncm.ko" ]; then
    cp "$ncm" "$ird/modules/cdc_ncm.ko"
  fi
  cp /bin/busybox "$ird/bin/busybox" || die "busybox-static missing (/bin/busybox)"
  busybox_static=$(file -b "$ird/bin/busybox")
  case "$busybox_static" in *static*) ;; *) die "/bin/busybox is not static ($busybox_static) - install busybox-static";; esac
  cp "$HERE/companion-init.sh" "$ird/init" && chmod 0755 "$ird/init" || die "companion-init.sh missing next to this script"
  ( cd "$ird" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$CVM/initrd.img.new" || die "cpio failed"
  cp "$w/deb/boot/vmlinuz-$kver" "$CVM/vmlinuz.new"
  mv -f "$CVM/vmlinuz.new" "$CVM/vmlinuz"; mv -f "$CVM/initrd.img.new" "$CVM/initrd.img"
  echo "$kver" > "$CVM/KVER"
  rm -rf "$w"
  stamp companion "$kver $apfsref v6"
  log "USB-host VM ready: $CVM/vmlinuz + initrd.img (kernel $kver, $(echo $order | wc -w) modules + apfs)"
}


# Locate vhci-bridge sources. Prefer dir, then flat amalgamation, then tarball,
# then Magisk staging path. Prints the .c path to compile on stdout.
resolve_vhci_bridge_c() {
  local c
  for c in \
      "$HERE/vhci-bridge/bridge.c" \
      "$HERE/vhci-bridge.c" \
      /root/vhci-bridge/bridge.c \
      /root/vhci-bridge.c \
      /data/local/tmp/qemu-t8030/vhci-bridge/bridge.c \
      /data/local/tmp/qemu-t8030/vhci-bridge.c
  do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  local tgz
  for tgz in "$HERE/vhci-bridge.tgz" "$HERE/vhci-bridge.tar.gz" /root/vhci-bridge.tgz /root/vhci-bridge.tar.gz /data/local/tmp/qemu-t8030/vhci-bridge.tgz /data/local/tmp/qemu-t8030/vhci-bridge.tar.gz; do
    if [ -f "$tgz" ]; then
      mkdir -p "$HERE"
      tar -xzf "$tgz" -C "$HERE" 2>/dev/null || true
      [ -f "$HERE/vhci-bridge/bridge.c" ] && { echo "$HERE/vhci-bridge/bridge.c"; return 0; }
    fi
  done
  return 1
}

build_vhci_bridge() {
  if stamp_ok vhci-bridge "4"; then log "vhci-bridge already built"; return 0; fi
  log "building vhci-bridge (Inferno usb-tcp <-> Linux VHCI)"
  local srcc srcdir
  srcc=$(resolve_vhci_bridge_c) || {
    echo "[ERROR] vhci-bridge source missing. Searched:" >&2
    echo "  $HERE/vhci-bridge/bridge.c  $HERE/vhci-bridge.c  $HERE/vhci-bridge.tgz" >&2
    echo "  /root/vhci-bridge...  /data/local/tmp/qemu-t8030/vhci-bridge..." >&2
    echo "--- ls $HERE ---" >&2
    ls -la "$HERE" 2>/dev/null | head -40 >&2
    echo "--- ls $HERE/vhci-bridge ---" >&2
    ls -la "$HERE/vhci-bridge" 2>/dev/null | head -20 >&2
    die "vhci-bridge source missing (reinstall qemu-t8030 v1.4.4+ module/app)"
  }
  srcdir=$(dirname "$srcc")
  log "vhci-bridge source: $srcc"
  mkdir -p "$PREFIX/bin"
  if [ "$(basename "$srcc")" = "vhci-bridge.c" ]; then
    gcc -O2 -Wall -pthread -o "$PREFIX/bin/vhci-bridge" "$srcc" \
      || die "vhci-bridge build failed ($srcc)"
  else
    gcc -O2 -Wall -pthread -o "$PREFIX/bin/vhci-bridge" -I"$srcdir" "$srcc" \
      || die "vhci-bridge build failed ($srcc)"
  fi
  "$PREFIX/bin/vhci-bridge" -h >/dev/null 2>&1 || true
  stamp vhci-bridge "4"
}

check_tools() {
  local b
  for b in bin/idevicerestore bin/idevice_id sbin/usbmuxd bin/inferno_fs_patcher bin/vhci-bridge companion/vmlinuz companion/initrd.img; do
    [ -s "$PREFIX/$b" ] || die "missing $PREFIX/$b after build"
  done
  "$PREFIX/bin/idevicerestore" -v || die "idevicerestore does not run"
  "$PREFIX/sbin/usbmuxd" -V || die "usbmuxd does not run"
  ldd "$PREFIX/sbin/usbmuxd" | grep -q "$PREFIX/lib/libusb-1.0" || die "usbmuxd is not linked against the no-udev libusb in $PREFIX/lib"
}

mkdir -p "$SRC" "$PREFIX"
ensure_apt
build_libusb
autotools_build libplist --without-cython
autotools_build libimobiledevice-glue
autotools_build libusbmuxd
autotools_build libtatsu
autotools_build libimobiledevice
autotools_build libirecovery --without-udev
autotools_build usbmuxd --without-systemd --with-udevrulesdir="$PREFIX/lib/udev/rules.d"
autotools_build idevicerestore
build_fspatcher
build_companion
build_vhci_bridge
check_tools
echo "[done] restore tools ready in $PREFIX"
