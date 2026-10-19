#!/usr/bin/env bash
#
# jailbreak-prep.sh - set an Inferno t8030 guest up as a jailbroken-style iOS VM,
# following ChefKiss's documented Inferno flow:
#   https://chefkiss.dev/guides/inferno/fs-patches/
#   https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/
#
# WHAT "JAILBROKEN" MEANS ON INFERNO
#   Inferno already patches the iOS kernel inside QEMU on EVERY boot
#   (hw/arm/apple-silicon/kernel_patches.c @ cc4302a): AMFI trust-cache bypass
#   (every binary treated as trusted), code-signature + pmap_cs bypass, unsigned
#   img4 allowed, rootfs remount + union mounts allowed, APFS update snapshot
#   disabled. So the kernel side of a jailbreak is always on; no amfi boot-arg
#   is needed. palera1n / checkra1n cannot run here (no SecureROM / iBoot / DFU
#   path in the emulator). What is missing is the USERLAND: a bootstrap (bash,
#   apt, coreutils, ...) on the System volume and a launchd entry that spawns a
#   root shell. That is what this script adds.
#
# WHEN IT CAN RUN
#   Only after the guest has been RESTORED (step 5, restore-ios.sh) - before
#   that the "root" disk is empty. Applying it needs the restored APFS System
#   volume mounted READ-WRITE, and the VM must be off. ChefKiss documents doing
#   that on macOS (hdiutil/diskutil); Linux needs the out-of-tree linux-apfs-rw
#   driver (experimental writes). Stock Android kernels have no APFS driver, so
#   on the phone this boots the small USB-host VM from step 5 (Debian kernel +
#   linux-apfs-rw, companion-vm.sh apfs-run) and applies everything there. If
#   the phone kernel itself lists "apfs" in /proc/filesystems, that is used.
#
# MODES
#   jailbreak-prep.sh            stage: download the checkra1n core bootstrap
#                                (from checkra.in at runtime), build
#                                InfernoFSPatcher, write apply-on-mac.sh, then
#                                try a Linux apply if an APFS rw driver exists.
#   SYSVOL=/mnt/System jailbreak-prep.sh apply
#                                apply to an already mounted rw System volume.
#   SYSVOL=... jailbreak-prep.sh apply-only
#                                same, without staging (used inside the VM).
#   jailbreak-prep.sh status     show what is staged / applied.
#
# Env: DATA (default /root/InfernoData), WITH_CYDIA=1 also stage Cydia.app,
#      SKIP_FS_PATCHES=1 skip the dyld-cache software-rendering patch.
#
# Nothing copyrighted is stored in the repo: the bootstrap comes from
# checkra.in's CDN and InfernoFSPatcher (AGPL-3.0) from git.chefkiss.dev, both
# fetched on your device at runtime.
set -eu

DATA="${DATA:-/root/InfernoData}"
JB="$DATA/jailbreak"
HERE=$(cd "$(dirname "$0")" && pwd)
CHECKRA1N_CONFIG="${CHECKRA1N_CONFIG:-https://assets.checkra.in/loader/config.json}"
FSPATCHER_REPO="${FSPATCHER_REPO:-https://git.chefkiss.dev/AppleHax/InfernoFSPatcher}"
DYLD_REL="System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
LAUNCHD_REL="System/Library/xpc/launchd.plist"
MARK_FS=".ios-tools-fs-patched"
MARK_JB=".ios-tools-bootstrapped"

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

mkdir -p "$JB"

json_get() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2]) or "")' "$1" "$2"; }

stage() {
  command -v curl >/dev/null || die "need curl (run inside the Debian chroot)"
  command -v python3 >/dev/null || die "need python3"

  log "fetching checkra1n loader config (bootstrap URLs)"
  curl -fsSL --retry 3 -o "$JB/config.json" "$CHECKRA1N_CONFIG" || die "could not fetch $CHECKRA1N_CONFIG"
  STRAP_URL=$(json_get "$JB/config.json" core_bootstrap_tar)
  [ -n "$STRAP_URL" ] || die "core_bootstrap_tar missing in checkra1n config"
  if [ -s "$JB/strap.tar.lzma" ] && [ "$(cat "$JB/strap.url" 2>/dev/null)" = "$STRAP_URL" ]; then
    log "strap.tar.lzma already downloaded"
  else
    log "downloading core bootstrap: $STRAP_URL"
    curl -fL --retry 3 -o "$JB/strap.tar.lzma.partial" "$STRAP_URL" || die "bootstrap download failed"
    mv -f "$JB/strap.tar.lzma.partial" "$JB/strap.tar.lzma"
    echo "$STRAP_URL" > "$JB/strap.url"
  fi
  if command -v xz >/dev/null; then
    xz --format=lzma -dc "$JB/strap.tar.lzma" | tar -tf - >/dev/null || die "strap.tar.lzma is corrupt; delete $JB/strap.tar.lzma and re-run"
    log "bootstrap archive OK ($(wc -c < "$JB/strap.tar.lzma" | tr -d ' ') bytes)"
  fi

  if [ "${WITH_CYDIA:-0}" = "1" ]; then
    CYDIA_URL=$(python3 -c 'import json,sys;b=json.load(open(sys.argv[1]))["bootstraps"];print(next((x["bootstrap_tar"] for x in b if x.get("label")=="Cydia"),""))' "$JB/config.json")
    if [ -n "$CYDIA_URL" ] && [ ! -s "$JB/cydia.tar.lzma" ]; then
      log "downloading Cydia bootstrap: $CYDIA_URL"
      curl -fL --retry 3 -o "$JB/cydia.tar.lzma" "$CYDIA_URL" || warn "Cydia download failed (optional)"
    fi
  fi

  cp -f "$HERE/patch-launchd.py" "$JB/patch-launchd.py" 2>/dev/null || true
  chmod +x "$JB/patch-launchd.py" 2>/dev/null || true

  if [ "${SKIP_FS_PATCHES:-0}" != "1" ]; then
    if [ ! -x "$JB/inferno_fs_patcher" ] && [ ! -x /opt/inferno-restore/bin/inferno_fs_patcher ]; then
      log "building InfernoFSPatcher (dyld cache patch for software rendering)"
      if command -v git >/dev/null && command -v g++ >/dev/null; then
        rm -rf "$JB/InfernoFSPatcher"
        git clone -q --depth 1 "$FSPATCHER_REPO" "$JB/InfernoFSPatcher" \
          && g++ -std=c++17 -O2 -o "$JB/inferno_fs_patcher" "$JB/InfernoFSPatcher/src/main.cpp" \
          && log "built $JB/inferno_fs_patcher" \
          || warn "InfernoFSPatcher build failed (needed only for the Linux apply path)"
      else
        warn "need git + g++ to build InfernoFSPatcher (run step 2 build deps)"
      fi
    fi
  fi

  write_mac_script
  log "staged in $JB"
}

write_mac_script() {
  cat > "$JB/apply-on-mac.sh" <<'MAC'
#!/bin/bash
# apply-on-mac.sh - run on a Mac (or macOS VM) with the Inferno "root" disk
# image copied next to this folder. VM must be OFF. Follows ChefKiss's
# "Filesystem Patches" + "Jailbreak Utility Bootstrap" pages.
#   usage: sudo ./apply-on-mac.sh /path/to/InfernoData/root
set -eu
ROOTIMG="${1:?usage: sudo $0 /path/to/root}"
HERE=$(cd "$(dirname "$0")" && pwd)
hdiutil attach -imagekey diskimage-class=CRawDiskImage -blocksize 4096 -noverify -noautofsck "$ROOTIMG" || true
# A "Data can't be unlocked" popup is normal (Data is SEP-encrypted).
[ -d /Volumes/System ] || { echo "System volume did not mount"; exit 1; }
diskutil enableownership /Volumes/System
mount -urw /Volumes/System
SYS=/Volumes/System
if [ ! -e "$SYS/.ios-tools-fs-patched" ]; then
  if [ ! -x "$HERE/InfernoFSPatcher/build/inferno_fs_patcher" ]; then
    git clone --depth 1 https://git.chefkiss.dev/AppleHax/InfernoFSPatcher "$HERE/InfernoFSPatcher" 2>/dev/null || true
    (cd "$HERE/InfernoFSPatcher" && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build)
  fi
  "$HERE/InfernoFSPatcher/build/inferno_fs_patcher" "$SYS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
  touch "$SYS/.ios-tools-fs-patched"
fi
[ -f "$HERE/launchd.plist.orig" ] || cp "$SYS/System/Library/xpc/launchd.plist" "$HERE/launchd.plist.orig"
if [ ! -e "$SYS/.ios-tools-bootstrapped" ]; then
  tar -xpf "$HERE/strap.tar.lzma" -C "$SYS"
  [ -f "$HERE/cydia.tar.lzma" ] && tar -xpf "$HERE/cydia.tar.lzma" -C "$SYS" || true
  touch "$SYS/.ios-tools-bootstrapped"
fi
python3 "$HERE/patch-launchd.py" "$SYS/System/Library/xpc/launchd.plist"
diskutil eject /Volumes/System || hdiutil detach /Volumes/System
echo "Done. Copy 'root' back to InfernoData on the phone and also create"
echo "InfernoData/JAILBREAK_APPLIED (empty file) so run-t8030.sh adds launchd_unsecure_cache=1."
MAC
  chmod +x "$JB/apply-on-mac.sh"
}

# apply_to SYSVOL  - SYSVOL is a mounted, writable iOS System volume
apply_to() {
  local sys="$1"
  [ "$(id -u)" = "0" ] || die "apply needs root"
  [ -f "$sys/$LAUNCHD_REL" ] || die "$sys does not look like an iOS System volume (no $LAUNCHD_REL)"
  touch "$sys/.ios-tools-write-test" 2>/dev/null && rm -f "$sys/.ios-tools-write-test" \
    || die "$sys is not writable - mount it read-write first"
  [ -s "$JB/strap.tar.lzma" ] || stage

  if [ "${SKIP_FS_PATCHES:-0}" != "1" ] && [ ! -e "$sys/$MARK_FS" ]; then
    local fsp="$JB/inferno_fs_patcher"
    [ -x "$fsp" ] || fsp=/opt/inferno-restore/bin/inferno_fs_patcher
    [ -x "$fsp" ] || die "inferno_fs_patcher not built (see stage output), or set SKIP_FS_PATCHES=1"
    log "patching dyld shared cache (software rendering)"
    "$fsp" "$sys/$DYLD_REL" || die "InfernoFSPatcher failed"
    touch "$sys/$MARK_FS"
  fi

  [ -f "$JB/launchd.plist.orig" ] || cp -f "$sys/$LAUNCHD_REL" "$JB/launchd.plist.orig"

  if [ ! -e "$sys/$MARK_JB" ]; then
    log "extracting checkra1n core bootstrap into System volume"
    xz --format=lzma -dc "$JB/strap.tar.lzma" | tar --keep-directory-symlink -xpf - -C "$sys" || die "bootstrap extract failed"
    if [ -s "$JB/cydia.tar.lzma" ]; then
      xz --format=lzma -dc "$JB/cydia.tar.lzma" | tar --keep-directory-symlink -xpf - -C "$sys" || warn "Cydia extract failed"
    fi
    touch "$sys/$MARK_JB"
  else
    log "bootstrap already on the volume"
  fi

  log "patching launchd.plist (disable broken services + root bash on console)"
  python3 "$JB/patch-launchd.py" "$sys/$LAUNCHD_REL" || die "launchd patch failed"
  sync
  date > "$DATA/JAILBREAK_APPLIED"
  log "applied. run-t8030.sh will now add launchd_unsecure_cache=1."
}

# Linux path: only if the running kernel has an APFS driver with write support
# (linux-apfs-rw). Untested by ChefKiss; a sparse backup of 'root' is made first.
try_linux_apply() {
  if ! grep -qw apfs /proc/filesystems 2>/dev/null; then
    warn "this kernel has no APFS driver ('apfs' not in /proc/filesystems)."
    warn "The restored System volume can't be written from the phone; use"
    warn "  $JB/apply-on-mac.sh   (copy InfernoData/root + the jailbreak/ folder to a Mac)"
    return 1
  fi
  [ -f "$DATA/root" ] || { warn "no $DATA/root disk"; return 1; }
  if pgrep -f qemu-system-aarch64 >/dev/null 2>&1; then
    warn "an emulator is running - power the VM off first"; return 1
  fi
  local mnt="$JB/mnt" v found=""
  mkdir -p "$mnt"
  for v in 0 1 2 3 4 5 6 7; do
    if mount -t apfs -o ro,loop,vol="$v" "$DATA/root" "$mnt" 2>/dev/null; then
      if [ -f "$mnt/$LAUNCHD_REL" ]; then found="$v"; fi
      umount "$mnt" 2>/dev/null || true
      [ -n "$found" ] && break
    fi
  done
  [ -n "$found" ] || { warn "no APFS volume with $LAUNCHD_REL in $DATA/root (not restored yet?)"; return 1; }
  if [ ! -f "$DATA/root.pre-jailbreak" ]; then
    log "backing up root disk (sparse) to root.pre-jailbreak"
    cp --sparse=always "$DATA/root" "$DATA/root.pre-jailbreak" || { warn "backup failed"; return 1; }
  fi
  mount -t apfs -o readwrite,loop,vol="$found" "$DATA/root" "$mnt" || { warn "rw mount failed"; return 1; }
  local rc=0
  ( apply_to "$mnt" ) || rc=$?
  umount "$mnt" || umount -l "$mnt" || true
  return $rc
}

# Phone path: the USB-host VM from step 5 has linux-apfs-rw.
try_companion_apply() {
  [ -f "$DATA/RESTORED" ] || { warn "the guest is not restored yet - run step 5 'Restore iOS (automatic)' first"; return 1; }
  [ -s /opt/inferno-restore/companion/initrd.img ] && [ -f "$HERE/companion-vm.sh" ] \
    || { warn "USB-host VM not built (step 5 builds it)"; return 1; }
  if pgrep -f 'qemu-system-aarch64.*-M t8030' >/dev/null 2>&1; then
    warn "an emulator is running - power the VM off first"; return 1
  fi
  if [ ! -f "$DATA/root.pre-jailbreak" ]; then
    local need avail
    need=$(du -k "$DATA/root" | awk '{print $1}'); avail=$(df -Pk "$DATA" | awk 'NR==2{print $4}')
    if [ "$avail" -gt $((need + 2097152)) ]; then
      log "backing up root disk (sparse, $((need / 1024)) MB) to root.pre-jailbreak"
      cp --sparse=always "$DATA/root" "$DATA/root.pre-jailbreak" || { warn "backup failed"; return 1; }
    else
      warn "not enough free space for a root.pre-jailbreak backup - continuing without one"
    fi
  fi
  cp -f "$HERE/jailbreak-prep.sh" "$JB/jailbreak-prep.sh"
  cp -f "$HERE/patch-launchd.py" "$JB/patch-launchd.py" 2>/dev/null || true
  log "booting the USB-host VM to write the bootstrap onto the System volume (a few minutes)"
  DATA="$DATA" bash "$HERE/companion-vm.sh" apfs-run "bash $JB/jailbreak-prep.sh apply-only"
}

status() {
  echo "staged bootstrap : $( [ -s "$JB/strap.tar.lzma" ] && echo yes || echo no )"
  echo "fs patcher built : $( [ -x "$JB/inferno_fs_patcher" ] && echo yes || echo no )"
  echo "mac helper       : $( [ -x "$JB/apply-on-mac.sh" ] && echo "$JB/apply-on-mac.sh" || echo no )"
  echo "applied to disk  : $( [ -f "$DATA/JAILBREAK_APPLIED" ] && cat "$DATA/JAILBREAK_APPLIED" || echo no )"
  echo "kernel patches   : always on (Inferno: AMFI/codesign/pmap_cs bypass)"
}

case "${1:-stage}" in
  stage)
    stage
    if [ -f "$DATA/JAILBREAK_APPLIED" ]; then
      log "already applied ($(cat "$DATA/JAILBREAK_APPLIED"))"
    elif grep -qw apfs /proc/filesystems 2>/dev/null && try_linux_apply; then
      :
    elif try_companion_apply; then
      :
    else
      warn "jailbreak bootstrap STAGED but not applied (see messages above)."
    fi
    status ;;
  apply)
    [ -n "${SYSVOL:-}" ] || die "set SYSVOL=/path/to/mounted/System"
    stage; apply_to "$SYSVOL"; status ;;
  apply-only)
    [ -n "${SYSVOL:-}" ] || die "set SYSVOL=/path/to/mounted/System"
    apply_to "$SYSVOL" ;;
  status) status ;;
  *) die "usage: $0 [stage|apply|apply-only|status]" ;;
esac
