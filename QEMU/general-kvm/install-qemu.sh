#!/usr/bin/env bash
#
# install-qemu.sh  --  run INSIDE the Debian chroot (see setup-debian-chroot.sh).
#
# Installs Debian's prebuilt, glibc QEMU. These are real aarch64 Linux ELF
# binaries that run fine in the chroot and can use /dev/kvm when it is exposed.
# This is the fast, reliable path; there is no usable Android/bionic QEMU build.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  qemu-system-arm qemu-system-x86 qemu-utils \
  qemu-efi-aarch64 seabios ipxe-qemu \
  ovmf 2>/dev/null || apt-get install -y qemu-system-arm qemu-system-x86 qemu-utils qemu-efi-aarch64

echo
echo "Installed:"
for b in qemu-system-aarch64 qemu-system-x86_64 qemu-img; do
  if command -v $b >/dev/null 2>&1; then printf '  %-22s %s\n' "$b" "$(command -v $b)"; fi
done
echo
echo "Check KVM:  qemu-system-aarch64 -accel help   (should list 'kvm')"
echo "UEFI firmware for aarch64 guests: /usr/share/qemu-efi-aarch64/QEMU_EFI.fd"
