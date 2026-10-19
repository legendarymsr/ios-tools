#!/usr/bin/env bash
#
# run-woa.sh  --  boot Windows on ARM (ARM64) with KVM acceleration.
# Run INSIDE the Debian chroot, as root, with /dev/kvm present.
#
# You supply:
#   - a qcow2 disk you created (qemu-img create -f qcow2 win.qcow2 64G)
#   - the Windows-on-ARM install ISO (build your own from a Windows ARM64 image,
#     e.g. via UUP dump; not distributed here)
#   - VirtIO drivers ISO (virtio-win) so Windows sees the disk/net
#
# Usage: ./run-woa.sh win.qcow2 Win11_ARM64.iso virtio-win.iso
set -eu
DISK="${1:?usage: run-woa.sh <win.qcow2> <windows.iso> [virtio.iso]}"
ISO="${2:?need windows ARM64 iso}"
VIRTIO="${3:-}"

ACCEL="tcg"; CPU="cortex-a76"
if [ -e /dev/kvm ] && qemu-system-aarch64 -accel help 2>/dev/null | grep -qw kvm; then
  ACCEL="kvm"; CPU="host"; echo "[*] KVM on."
else
  echo "[!] No KVM -> TCG; Windows on ARM under TCG is extremely slow."
fi

FW_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
[ -f "$FW_CODE" ] || FW_CODE=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
cp -n /usr/share/AAVMF/AAVMF_VARS.fd ./WOA_VARS.fd 2>/dev/null || \
  qemu-img create -f raw WOA_VARS.fd 64M

VIRTIO_ARGS=""
[ -n "$VIRTIO" ] && VIRTIO_ARGS="-drive file=$VIRTIO,media=cdrom,if=none,id=virtio -device usb-storage,drive=virtio"

exec qemu-system-aarch64 \
  -machine virt,gic-version=3,virtualization=on,highmem=off \
  -accel "$ACCEL" -cpu "$CPU" \
  -smp 4 -m 4096 \
  -drive file="$FW_CODE",if=pflash,format=raw,readonly=on \
  -drive file=./WOA_VARS.fd,if=pflash,format=raw \
  -device ramfb -device qemu-xhci -device usb-kbd -device usb-tablet \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -drive file="$DISK",if=virtio \
  -drive file="$ISO",media=cdrom,if=none,id=cd -device usb-storage,drive=cd \
  $VIRTIO_ARGS \
  ${DISPLAY_QEMU:--display vnc=127.0.0.1:0}
