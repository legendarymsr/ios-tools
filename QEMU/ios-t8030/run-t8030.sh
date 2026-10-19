#!/usr/bin/env bash
#
# run-t8030.sh  --  boot the emulated iPhone 11 (t8030) in Inferno.
# Run INSIDE the Debian chroot, from the data folder prepared by
# download-and-configure.sh / prepare-ios-files.sh.
#
# Accel: Inferno's t8030 machine (ChefKiss/Inferno @ cc4302a) is TCG-only in
# practice. The machine hardcodes TYPE_APPLE_A13 CPUs with Apple IMPDEF
# sysregs (apple_a13_cp_reginfo_tcg), sets minimum_page_bits=14 (16 KiB pages),
# and cannot use -cpu host. KVM on a generic ARM64 Android host cannot run
# that guest CPU model, so we always pass -accel tcg. We still probe /dev/kvm
# and log clearly so you can see whether host KVM exists for other guests.
#
# Expect multi-minute boots and a strong phone.
#
# If run.env exists (written by download-and-configure.sh), it is sourced and
# supplies KERNEL/DTB/TRUSTCACHE/TICKET/SEPFW/SEPROM/RAMDISK automatically.
# Otherwise defaults match iOS 14.0 beta 5 filenames.
#
# Restore: step 5 (restore-ios.sh) runs this with RESTORE_MODE=1 and the USB
# connection options, and marks the disk RESTORED when done; after that a
# plain run boots iOS normally.
set -eu
QEMU="${QEMU:-/root/Inferno/build/qemu-system-aarch64}"
DATA="${DATA:-$PWD}"

if [ -f "$DATA/run.env" ]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1090
  . "$DATA/run.env"
  set +a
  echo "[*] loaded $DATA/run.env"
fi

RESTORE="${RESTORE:-$DATA/Restore}"
TRUSTCACHE="${TRUSTCACHE:-$RESTORE/Firmware/038-44135-124.dmg.trustcache}"
KERNEL="${KERNEL:-$RESTORE/kernelcache.research.iphone12b}"
DTB="${DTB:-$RESTORE/Firmware/all_flash/DeviceTree.n104ap.im4p}"
TICKET="${TICKET:-$DATA/root_ticket.der}"
SEPFW="${SEPFW:-$DATA/sep-firmware.n104.RELEASE.new.img4}"
SEPROM="${SEPROM:-$DATA/AppleSEPROM-Cebu-B1}"
RAMDISK="${RAMDISK:-}"   # set to the Erase/Upgrade RAM disk .dmg to restore

[ -x "$QEMU" ] || { echo "qemu-system-aarch64 not found at $QEMU (build Inferno first)"; exit 1; }

# QEMU data dir (keymaps for -display vnc, firmware ROMs). A build-tree
# qemu-system-aarch64 that was never "make install"ed can't find
# keymaps/en-us ("could not read keymap file: 'en-us'"), so locate one at
# runtime and pass it with -L. Falls back to copying the keymaps that ship in
# the Inferno source tree (pc-bios/keymaps) next to the build.
qemu_datadir() {
  local qd src d
  qd=$(cd "$(dirname "$QEMU")" 2>/dev/null && pwd) || qd=""
  src="${INFERNO_SRC:-$(dirname "$qd")}"
  for d in "${QEMU_DATADIR:-}" "$qd/qemu-bundle/usr/local/share/qemu" "$qd/pc-bios" \
           "$qd/ios-tools-qemu-data" /usr/local/share/qemu /usr/share/qemu "$src/pc-bios"; do
    [ -n "$d" ] && [ -f "$d/keymaps/en-us" ] && { echo "$d"; return 0; }
  done
  if [ -f "$src/pc-bios/keymaps/en-us" ] && [ -n "$qd" ]; then
    mkdir -p "$qd/ios-tools-qemu-data" && cp -r "$src/pc-bios/keymaps" "$qd/ios-tools-qemu-data/" \
      && [ -f "$qd/ios-tools-qemu-data/keymaps/en-us" ] && { echo "$qd/ios-tools-qemu-data"; return 0; }
  fi
  return 1
}
QDATA=$(qemu_datadir) || { echo "[ERROR] no QEMU keymaps (keymaps/en-us) found next to $QEMU, in /usr/local/share/qemu or the Inferno source - re-run step 3"; exit 1; }
echo "[*] QEMU data dir: $QDATA"
missing=0
for f in "$TICKET" "$SEPFW" "$SEPROM" "$KERNEL" "$DTB" "$TRUSTCACHE"; do
  if [ ! -f "$f" ]; then
    echo "[!] missing: $f  (run download-and-configure.sh first)"
    missing=1
  fi
done
[ "$missing" = "0" ] || exit 1
# ChefKiss troubleshooting: "at24c-eeprom: Backing file size 65536 != 2048"
[ -f "$DATA/sep_nvram" ] && truncate -c -s 64K "$DATA/sep_nvram" 2>/dev/null || true

# Which boot: RESTORE_MODE=1 forces the restore ramdisk (used by
# restore-ios.sh), RESTORE_MODE=0 forces a normal boot. "auto" (default) boots
# normally once step 5 (restore-ios.sh) has marked the disk RESTORED, and
# refuses to boot a blank or half-restored disk (booting a blank disk without
# the ramdisk panics, and booting the ramdisk without idevicerestore does
# nothing useful).
root_blank() {
  [ -f "$DATA/root" ] || return 0
  [ "$(head -c 1048576 "$DATA/root" | tr -d '\000' | wc -c)" = "0" ]
}
INITRD=""
MODE="${RESTORE_MODE:-auto}"
if [ "$MODE" = "auto" ]; then
  if [ -f "$DATA/RESTORED" ]; then
    MODE=0
  elif root_blank; then
    echo "[ERROR] the iOS disk is blank: run step 5 'Restore iOS (automatic)' first"
    echo "        (RESTORE_MODE=1 boots the restore ramdisk by hand)"
    exit 1
  else
    st=$(cat "$DATA/restore/state" 2>/dev/null || echo unknown)
    if [ "$st" = "unknown" ]; then
      echo "[*] root disk has data but no RESTORED marker (restored by hand?): normal boot"
      MODE=0
    else
      echo "[ERROR] the restore did not finish (state: $st) - run step 5 'Restore iOS (automatic)' again"
      echo "        (RESTORE_MODE=0 boots it anyway)"
      exit 1
    fi
  fi
fi
if [ "$MODE" = "1" ]; then
  if [ -n "$RAMDISK" ] && [ -f "$RAMDISK" ]; then
    INITRD="-initrd $RAMDISK"
    echo "[*] restore mode: booting the restore ramdisk $(basename "$RAMDISK")"
  else
    echo "[ERROR] restore mode but no restore ramdisk found (RAMDISK in run.env) - re-run step 4"
    exit 1
  fi
else
  echo "[*] normal boot (restored disk; the first boot finishes data migration and is slow)"
fi

# USB: the emulated iPhone's USB port connects to a USB-host VM
# (companion-vm.sh / ChefKiss companion VM). restore-ios.sh sets
# USB_CONN_TYPE=unix USB_CONN_ADDR=<socket>; otherwise Inferno's default
# (UNIX socket /tmp/InfernoUSBRemote) is used.
USBOPT=""
[ -n "${USB_CONN_TYPE:-}" ] && USBOPT="$USBOPT,usb-conn-type=$USB_CONN_TYPE"
[ -n "${USB_CONN_ADDR:-}" ] && USBOPT="$USBOPT,usb-conn-addr=$USB_CONN_ADDR"
[ -n "${USB_CONN_PORT:-}" ] && USBOPT="$USBOPT,usb-conn-port=$USB_CONN_PORT"

# --- Accel selection ----------------------------------------------------------
# Probe host KVM for logging. Force TCG for t8030 regardless (see header).
ACCEL="tcg"
ACCEL_WHY="Inferno t8030 machine uses Apple A13 CPUs + 16KiB pages (TCG-only); -accel kvm / -cpu host are not usable for this guest"
if [ -e /dev/kvm ]; then
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    echo "[*] /dev/kvm present and accessible — useful for OTHER aarch64 guests (virt), NOT for t8030"
  else
    echo "[*] /dev/kvm exists but is not r/w (chmod/ownership?); irrelevant for t8030 anyway"
  fi
else
  echo "[*] /dev/kvm missing (need custom kernel with CONFIG_KVM host mode) — irrelevant for t8030"
fi
echo "[*] accel=$ACCEL  reason: $ACCEL_WHY"

# --- Jailbreak boot-args ------------------------------------------------------
# Inferno patches AMFI / code signing in the kernel on every boot already, so no
# amfi=... boot-arg is needed. Once jailbreak-prep.sh has installed the
# bootstrap and edited launchd.plist, launchd must accept the modified service
# cache: that needs launchd_unsecure_cache=1 (ChefKiss jailbreak-bootstrap page).
BOOTARGS="tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 -vm_compressor_wk_sw"
if [ -f "$DATA/JAILBREAK_APPLIED" ] || [ "${JAILBREAK:-0}" = "1" ]; then
  BOOTARGS="$BOOTARGS launchd_unsecure_cache=1"
  echo "[*] jailbreak bootstrap applied: adding launchd_unsecure_cache=1 (root bash on the serial console)"
fi
[ -n "${EXTRA_BOOTARGS:-}" ] && BOOTARGS="$BOOTARGS $EXTRA_BOOTARGS"
echo "[*] boot-args: $BOOTARGS"
# -smp: with SEP emulation Inferno takes ONE of the -smp CPUs for the SEP
# (t8030_real_cpu_count = smp - 1). ChefKiss's guide uses -smp 7 = the A13's
# 6 application cores + SEP; v1.2.1 and older passed 6 (only 5 AP cores).
echo "[*] -smp ${SMP:-7} (= $(( ${SMP:-7} - 1 )) A13 cores + 1 SEP core)"

echo "[*] booting t8030 (VNC on 127.0.0.1:5900 by default — connect a viewer)"
exec "$QEMU" -L "$QDATA" \
  -accel "$ACCEL" \
  -M t8030,trustcache="$TRUSTCACHE",ticket="$TICKET",sep-fw="$SEPFW",sep-rom="$SEPROM",kaslr-off=true$USBOPT \
  -kernel "$KERNEL" -dtb "$DTB" \
  -append "$BOOTARGS" \
  -smp "${SMP:-7}" -m "${MEM:-4G}" ${SERIAL_QEMU:--serial mon:stdio} \
  ${DISPLAY_QEMU:--display vnc=127.0.0.1:0} \
  $INITRD \
  -drive file="$DATA/sep_nvram,if=pflash,format=raw" \
  -drive file="$DATA/sep_ssc,if=pflash,format=raw" \
  -drive file="$DATA/root",format=raw,if=none,id=root       -device nvme-ns,drive=root,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096 \
  -drive file="$DATA/firmware",format=raw,if=none,id=firmware -device nvme-ns,drive=firmware,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096 \
  -drive file="$DATA/syscfg",format=raw,if=none,id=syscfg   -device nvme-ns,drive=syscfg,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096 \
  -drive file="$DATA/ctrl_bits",format=raw,if=none,id=ctrl_bits -device nvme-ns,drive=ctrl_bits,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096 \
  -drive file="$DATA/nvram",if=none,format=raw,id=nvram     -device apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096 \
  -drive file="$DATA/effaceable",format=raw,if=none,id=effaceable -device nvme-ns,drive=effaceable,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096 \
  -drive file="$DATA/panic_log",format=raw,if=none,id=panic_log -device nvme-ns,drive=panic_log,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096
