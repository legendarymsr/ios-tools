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

# Restore ramdisk only while the root disk is still blank (or RESTORE_MODE=1).
# Booting a restored disk with the Erase ramdisk would just start another
# restore; booting a blank disk without it panics ("cannot find IOAESAccelerator").
root_blank() {
  [ -f "$DATA/root" ] || return 0
  [ "$(head -c 1048576 "$DATA/root" | tr -d '\000' | wc -c)" = "0" ]
}
INITRD=""
if [ "${RESTORE_MODE:-auto}" = "1" ] || { [ "${RESTORE_MODE:-auto}" = "auto" ] && root_blank; }; then
  if [ -n "$RAMDISK" ] && [ -f "$RAMDISK" ]; then
    INITRD="-initrd $RAMDISK"
    echo "[*] root disk is blank: booting the restore ramdisk $(basename "$RAMDISK") (start idevicerestore from the companion VM)"
  else
    echo "[!] root disk is blank and no restore ramdisk found - re-run step 4"
  fi
else
  echo "[*] root disk has data: normal boot (RESTORE_MODE=1 forces the restore ramdisk)"
fi

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

echo "[*] booting t8030 (VNC on 127.0.0.1:5900 by default — connect a viewer)"
exec "$QEMU" \
  -accel "$ACCEL" \
  -M t8030,trustcache="$TRUSTCACHE",ticket="$TICKET",sep-fw="$SEPFW",sep-rom="$SEPROM",kaslr-off=true \
  -kernel "$KERNEL" -dtb "$DTB" \
  -append "$BOOTARGS" \
  -smp "${SMP:-6}" -m "${MEM:-4G}" -serial mon:stdio \
  ${DISPLAY_QEMU:--display vnc=127.0.0.1:0,show-cursor=on} \
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
