#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# install-qemu-x86.sh
# Install qemu-system-x86 (and helpers) inside the Debian chroot.
# Run INSIDE the chroot (or via enter-debian.sh 'bash /root/install-qemu-x86.sh').
#
# QEMU comes from <codename>-backports when that suite has it (bookworm:
# QEMU 10.0). The iOS VM module (qemu-t8030) installs qemu-system-arm from
# bookworm-backports into the same chroot, and every qemu-system-* package
# needs the exact same qemu-system-common version, so mixing bookworm's
# QEMU 7.2 with backports' QEMU 10 cannot be installed. Nothing is removed
# or downgraded: apt runs with --no-remove.
set -eu

APT_ETC="${APT_ETC:-/etc/apt}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
export DEBIAN_FRONTEND=noninteractive

CODENAME=""
if [ -r "$OS_RELEASE" ]; then
  CODENAME=$(. "$OS_RELEASE"; echo "${VERSION_CODENAME:-}")
fi
echo "[*] Debian release: ${CODENAME:-unknown}"

if [ "$CODENAME" = "bookworm" ]; then
  if grep -rqs 'bookworm-backports' "$APT_ETC/sources.list" "$APT_ETC/sources.list.d/"; then
    echo "[*] bookworm-backports source already present"
  else
    echo "[*] Adding bookworm-backports source (same line as the iOS VM module)"
    mkdir -p "$APT_ETC/sources.list.d"
    echo 'deb http://deb.debian.org/debian bookworm-backports main' > "$APT_ETC/sources.list.d/bookworm-backports.list"
  fi
fi

echo "[*] apt-get update"
apt-get update

# Which QEMU is already installed (e.g. by the iOS VM module)?
COMMON_VER=$(dpkg-query -W -f='${Status} ${Version}\n' qemu-system-common 2>/dev/null \
  | awk '$3=="installed"{print $4}' || true)
[ -n "$COMMON_VER" ] && echo "[*] qemu-system-common already installed: $COMMON_VER"

TARGET=()
if [ -n "$CODENAME" ] && apt-cache madison qemu-system-x86 2>/dev/null | grep -q " $CODENAME-backports/"; then
  TARGET=(-t "$CODENAME-backports")
  echo "[*] Using QEMU from $CODENAME-backports"
else
  case "$COMMON_VER" in
    *~bpo*)
      echo "ERROR: QEMU $COMMON_VER from backports is installed, but qemu-system-x86 is not" >&2
      echo "       available from ${CODENAME:-?}-backports (apt-get update failed for it?)." >&2
      echo "       Not installing bookworm's older QEMU over it. Check the network and run this step again." >&2
      exit 1 ;;
  esac
  echo "[*] Using QEMU from the main ${CODENAME:-Debian} archive"
fi

# Every installed qemu-system-* has to move to the same version as
# qemu-system-common, so list them too (upgrade only, never removal).
QEMU_PKGS=(qemu-system-x86 qemu-utils)
for p in $(dpkg-query -W -f='${Status} ${Package}\n' 'qemu-system-*' 2>/dev/null \
            | awk '$3=="installed"{print $4}'); do
  case "$p" in
    qemu-system-common|qemu-system-data|qemu-system-gui|qemu-system-x86) ;;
    *) QEMU_PKGS+=("$p") ;;
  esac
done

echo "[*] Installing ${QEMU_PKGS[*]} ${TARGET[*]}"
apt-get install -y --no-install-recommends --no-remove "${TARGET[@]}" "${QEMU_PKGS[@]}"

echo "[*] Installing helpers (python3, dmg2img, wget, ...) from the main archive"
apt-get install -y --no-install-recommends --no-remove \
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
