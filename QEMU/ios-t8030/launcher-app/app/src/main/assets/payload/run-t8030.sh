#!/usr/bin/env bash
#
# run-t8030.sh  --  boot the emulated iPhone 11 (t8030) in Inferno.
# Run INSIDE the Debian chroot, from the data folder prepared by
# prepare-ios-files.sh. TCG only (the guest is an Apple A13) => SLOW, no GPU
# accel, bring-up quality. Expect multi-minute boots and a strong phone.
#
# Adjust the firmware component filenames to match YOUR ipsw (the 038-xxxxx
# trustcache/ramdisk numbers differ per build). Defaults match iOS 14.0 beta 5.
set -eu
QEMU="${QEMU:-/root/Inferno/build/qemu-system-aarch64}"
DATA="${DATA:-$PWD}"
RESTORE="${RESTORE:-$DATA/Restore}"

TRUSTCACHE="${TRUSTCACHE:-$RESTORE/Firmware/038-44135-124.dmg.trustcache}"
KERNEL="${KERNEL:-$RESTORE/kernelcache.research.iphone12b}"
DTB="${DTB:-$RESTORE/Firmware/all_flash/DeviceTree.n104ap.im4p}"
TICKET="${TICKET:-$DATA/root_ticket.der}"
SEPFW="${SEPFW:-$DATA/sep-firmware.n104.RELEASE.new.img4}"
SEPROM="${SEPROM:-$DATA/AppleSEPROM-Cebu-B1}"
RAMDISK="${RAMDISK:-}"   # set to the Erase/Upgrade RAM disk .dmg to restore

[ -x "$QEMU" ] || { echo "qemu-system-aarch64 not found at $QEMU (build Inferno first)"; exit 1; }
for f in "$TICKET" "$SEPFW" "$SEPROM" "$KERNEL" "$DTB"; do
  [ -f "$f" ] || echo "[!] missing: $f  (see prepare-ios-files.sh)"
done

INITRD=""
[ -n "$RAMDISK" ] && INITRD="-initrd $RAMDISK"

exec "$QEMU" \
  -M t8030,trustcache="$TRUSTCACHE",ticket="$TICKET",sep-fw="$SEPFW",sep-rom="$SEPROM",kaslr-off=true \
  -kernel "$KERNEL" -dtb "$DTB" \
  -append "tlto_us=-1 mtxspin=-1 agm-genuine=1 agm-authentic=1 agm-trusted=1 serial=3 wdt=-1 -vm_compressor_wk_sw" \
  -smp 6 -m 4G -serial mon:stdio \
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
