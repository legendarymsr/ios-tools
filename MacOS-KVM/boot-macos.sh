#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# boot-macos.sh
# Boot macOS (default: macOS 26 Tahoe) under QEMU using the OSX-KVM
# OpenCore + OVMF stack, adapted for an aarch64 Android host.
#
#   MACOS_VERSION=tahoe   (default) macOS 26 Tahoe
#   MACOS_VERSION=sequoia macOS 15 Sequoia
#   MACOS_VERSION=sonoma  macOS 14 Sonoma
#
# On the phone the guest is x86_64 and the host aarch64, so KVM cannot help:
# QEMU runs under TCG (pure software emulation). This is extremely slow, and
# a full install under TCG on a phone is unlikely to be practical.
# On an x86_64 host with a usable /dev/kvm the script uses KVM instead
# (override with ACCEL=tcg or ACCEL=kvm).
#
# Run INSIDE the Debian chroot with /data/local/osx-kvm bind-mounted.
# Display defaults to VNC on 127.0.0.1:5900.
set -eu

WORKDIR="${WORKDIR:-/data/local/osx-kvm}"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/macos-versions.sh" ]; then
  . "$HERE/macos-versions.sh"
else
  . "$WORKDIR/macos-versions.sh"
fi
cd "$WORKDIR"

ALLOCATED_RAM="${ALLOCATED_RAM:-3072}"   # MiB - Flip 4 has 8 GB; leave headroom
CPU_CORES="${CPU_CORES:-2}"
CPU_THREADS="${CPU_THREADS:-2}"
CPU_MODEL="${CPU_MODEL:-$MACOS_CPU_DEFAULT}"
MY_OPTIONS="+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"
# Display: VNC by default so the app's viewer can attach. Override with
# DISPLAY_QEMU='-nographic' or '-display sdl' if you have an X server.
DISPLAY_QEMU="${DISPLAY_QEMU:--display vnc=127.0.0.1:0}"
MONITOR="${MONITOR:-stdio}"

if [ -z "${ACCEL:-}" ]; then
  if [ "$(uname -m)" = "x86_64" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    ACCEL=kvm
  else
    ACCEL=tcg
  fi
fi
case "$ACCEL" in
  kvm) ACCEL_ARGS=(-enable-kvm); CPU_KVM=",kvm=on"
       echo "[*] accel=kvm  reason: x86_64 host with /dev/kvm" ;;
  tcg) ACCEL_ARGS=(-accel tcg,thread=multi); CPU_KVM=""
       echo "[*] accel=tcg  reason: macOS guest is x86_64; KVM on an ARM64 host cannot accelerate cross-arch guests" ;;
  *)   echo "ERROR: ACCEL must be kvm or tcg" >&2; exit 2 ;;
esac

# The module (customize.sh) stages a new OpenCore.qcow2 in assets/ on every
# flash; use it even if step 3 was not run again (the VM opens it read-only
# with snapshot=on, so the copy here is never changed by booting).
if [ -f assets/OpenCore.qcow2 ] && ! cmp -s assets/OpenCore.qcow2 OpenCore.qcow2; then
  echo "[*] Updating OpenCore.qcow2 from the module's assets"
  cp -f assets/OpenCore.qcow2 OpenCore.qcow2
  [ -f assets/config.plist ] && cp -f assets/config.plist config.plist
fi

for f in OVMF_CODE_4M.fd OVMF_VARS-1024x768.fd OpenCore.qcow2; do
  [ -f "$f" ] || { echo "ERROR: missing $f - run step 3 (Stage OSX-KVM assets) first." >&2; exit 1; }
done
[ -s "$MACOS_IMG" ] || { echo "ERROR: missing $MACOS_IMG - run the Fetch $MACOS_NAME recovery step first." >&2; exit 1; }
[ -f mac_hdd_ng.img ] || { echo "ERROR: missing mac_hdd_ng.img - run step 3 (Stage OSX-KVM assets) first." >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || {
  echo "ERROR: qemu-system-x86_64 not in PATH - run install-qemu-x86.sh inside the chroot." >&2
  exit 1
}

echo "[*] Booting $MACOS_NAME (recovery: $MACOS_IMG)"
echo "    RAM=${ALLOCATED_RAM}MiB  CPU=${CPU_MODEL} ${CPU_THREADS}t/${CPU_CORES}c"
echo "    Display: $DISPLAY_QEMU"
[ "$ACCEL" = tcg ] && echo "    This will be VERY slow. Ctrl-C in this shell to stop."
echo

# Based on OSX-KVM OpenCore-Boot.sh (commit 4c378a4). The isa-applesmc osk
# string is the public constant used by upstream OSX-KVM.
args=(
  "${ACCEL_ARGS[@]}"
  -m "$ALLOCATED_RAM"
  -cpu "$CPU_MODEL$CPU_KVM",vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,"$MY_OPTIONS"
  -machine q35
  -smp "$CPU_THREADS",cores="$CPU_CORES",sockets=1
  -device qemu-xhci,id=xhci
  -device usb-kbd,bus=xhci.0
  -device usb-tablet,bus=xhci.0
  -device usb-ehci,id=ehci
  -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
  -drive if=pflash,format=raw,readonly=on,file="$WORKDIR/OVMF_CODE_4M.fd"
  -drive if=pflash,format=raw,file="$WORKDIR/OVMF_VARS-1024x768.fd"
  -smbios type=2
  -device ich9-intel-hda -device hda-duplex
  -device ich9-ahci,id=sata
  -drive id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file="$WORKDIR/OpenCore.qcow2"
  -device ide-hd,bus=sata.2,drive=OpenCoreBoot
  # The macOS disk sits on the port before the installer: OpenCore's default
  # entry is the first bootable volume it finds, so a blank disk falls through
  # to the installer, and once macOS (or its installer stage) is on the disk,
  # that is booted instead.
  -drive id=MacHDD,if=none,file="$WORKDIR/mac_hdd_ng.img",format=qcow2
  -device ide-hd,bus=sata.3,drive=MacHDD
  -drive id=InstallMedia,if=none,file="$WORKDIR/$MACOS_IMG",format=raw
  -device ide-hd,bus=sata.4,drive=InstallMedia
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
  -monitor "$MONITOR"
  -device vmware-svga
)

# shellcheck disable=SC2086
exec qemu-system-x86_64 "${args[@]}" $DISPLAY_QEMU
