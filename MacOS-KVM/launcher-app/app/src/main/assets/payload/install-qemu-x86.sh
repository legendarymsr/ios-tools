#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install-qemu-x86.sh
# Install qemu-system-x86 (and helpers) inside the Debian chroot.
# Run INSIDE the chroot (or via enter-debian.sh 'bash /root/install-qemu-x86.sh').
set -eu

echo "[*] apt-get update"
apt-get update

echo "[*] Installing qemu-system-x86 + helpers (python3, dmg2img, wget, ...)"
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  qemu-system-x86 qemu-utils \
  python3 python3-urllib3 \
  wget curl ca-certificates \
  dmg2img p7zip-full genisoimage \
  net-tools procps

echo "[*] qemu-system-x86_64: $(command -v qemu-system-x86_64)"
qemu-system-x86_64 --version | head -3
echo
echo "[done] QEMU x86_64 ready. NOTE: on an aarch64 phone this runs under TCG"
echo "       (software emulation). There is NO KVM acceleration for x86 guests"
echo "       on ARM. macOS will be VERY slow; a full install may take many hours"
echo "       or fail under TCG. See the module README."
