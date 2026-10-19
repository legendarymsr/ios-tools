#!/usr/bin/env bash
#
# boot-macos14.sh
# Boot macOS 14 (Sonoma) under QEMU using the OSX-KVM OpenCore + OVMF stack,
# adapted for an aarch64 Android host.
#
# CRITICAL: guest is x86_64, host is aarch64 → NO -enable-kvm. Pure TCG.
# This will be extremely slow. A full Sonoma install under TCG on a phone is
# unlikely to be practical; the goal here is to wire up the stack honestly.
#
# Run INSIDE the Debian chroot with /data/local/osx-kvm bind-mounted.
# Display defaults to VNC on 127.0.0.1:5900 (connect with a VNC viewer app).
set -eu

WORKDIR="${WORKDIR:-/data/local/osx-kvm}"
cd "$WORKDIR"

ALLOCATED_RAM="${ALLOCATED_RAM:-3072}"   # MiB — Flip 4 has 8 GB; leave headroom
CPU_CORES="${CPU_CORES:-2}"
CPU_THREADS="${CPU_THREADS:-2}"
# Sonoma wants Haswell-noTSX (or newer) per OSX-KVM notes; Penryn is too old.
CPU_MODEL="${CPU_MODEL:-Haswell-noTSX}"
MY_OPTIONS="+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check"
# Display: VNC by default so a phone VNC client can attach. Override with
# DISPLAY_QEMU='-nographic' or '-display sdl' if you have an X server.
DISPLAY_QEMU="${DISPLAY_QEMU:--display vnc=127.0.0.1:0}"

for f in OVMF_CODE_4M.fd OVMF_VARS-1024x768.fd OpenCore.qcow2; do
  [ -f "$f" ] || { echo "ERROR: missing $f — run setup-osx-kvm.sh first." >&2; exit 1; }
done
[ -f BaseSystem.img ] || { echo "ERROR: missing BaseSystem.img — run fetch-sonoma.sh first." >&2; exit 1; }
[ -f mac_hdd_ng.img ] || { echo "ERROR: missing mac_hdd_ng.img — run setup-osx-kvm.sh first." >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null || {
  echo "ERROR: qemu-system-x86_64 not in PATH — run install-qemu-x86.sh inside the chroot." >&2
  exit 1
}

echo "[*] Booting macOS 14 under TCG (NO KVM — guest x86_64 on host aarch64)"
echo "    RAM=${ALLOCATED_RAM}MiB  CPU=${CPU_MODEL} ${CPU_THREADS}t/${CPU_CORES}c"
echo "    Display: $DISPLAY_QEMU"
echo "    VNC default = 127.0.0.1:5900  (connect from a VNC app on the phone)"
echo "    This will be VERY slow. Ctrl-C in this shell to stop."
echo

# Based on OSX-KVM OpenCore-Boot.sh, with -enable-kvm removed and CPU tuned
# for Sonoma. isa-applesmc osk string is the well-known public constant used
# by every QEMU Hackintosh guide (including upstream OSX-KVM).
args=(
  -accel tcg,thread=multi
  -m "$ALLOCATED_RAM"
  -cpu "$CPU_MODEL",vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,"$MY_OPTIONS"
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
  -drive id=InstallMedia,if=none,file="$WORKDIR/BaseSystem.img",format=raw
  -device ide-hd,bus=sata.3,drive=InstallMedia
  -drive id=MacHDD,if=none,file="$WORKDIR/mac_hdd_ng.img",format=qcow2
  -device ide-hd,bus=sata.4,drive=MacHDD
  -netdev user,id=net0,hostfwd=tcp::2222-:22
  -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
  -monitor stdio
  -device vmware-svga
)

# shellcheck disable=SC2086
qemu-system-x86_64 "${args[@]}" $DISPLAY_QEMU
