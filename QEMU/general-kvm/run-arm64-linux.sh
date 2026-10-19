#!/usr/bin/env bash
#
# run-arm64-linux.sh  --  boot an ARM64 Linux guest with KVM acceleration.
# Run INSIDE the Debian chroot, as root, with /dev/kvm present.
#
# Usage:
#   ./run-arm64-linux.sh <disk-or-iso.img> [extra qemu args...]
#
# Example (install Debian/Ubuntu ARM64 from an ISO onto a fresh disk):
#   qemu-img create -f qcow2 guest.qcow2 16G
#   ./run-arm64-linux.sh ubuntu-24.04-arm64.iso -drive file=guest.qcow2,if=virtio
set -eu
IMG="${1:?usage: run-arm64-linux.sh <disk-or-iso> [extra args]}"
shift || true

ACCEL="tcg"; CPU="cortex-a76"
if [ -e /dev/kvm ] && qemu-system-aarch64 -accel help 2>/dev/null | grep -qw kvm; then
  ACCEL="kvm"; CPU="host"
  echo "[*] KVM available -> -enable-kvm -cpu host (near-native)"
else
  echo "[!] /dev/kvm not usable -> falling back to slow TCG emulation."
  echo "    See README 'Enabling KVM' (needs a custom kernel)."
fi

FW=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
[ -f "$FW" ] || FW=/usr/share/AAVMF/AAVMF_CODE.fd

exec qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -accel "$ACCEL" -cpu "$CPU" \
  -smp 4 -m 3072 \
  -bios "$FW" \
  -device virtio-gpu-pci ${DISPLAY_QEMU:--display vnc=127.0.0.1:0} \
  -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -drive file="$IMG",format=raw,if=virtio,media=cdrom \
  "$@"
