#!/usr/bin/env bash
#
# setup-osx-kvm.sh
# Stage OSX-KVM assets (OVMF, OpenCore, fetch script) into the working dir and
# create an empty macOS HDD image. Does NOT download Apple images.
#
# Run AS ROOT on the phone. Assets come from the KernelSU module payload at
# /data/local/osx-kvm/assets (staged by customize.sh) or from {P}/assets.
set -eu

WORKDIR="${WORKDIR:-/data/local/osx-kvm}"
ASSETS="${ASSETS:-$WORKDIR/assets}"
# Fall back to the payload dir next to this script (app-extracted path).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$ASSETS" ] && [ -d "$SCRIPT_DIR/assets" ]; then
  ASSETS="$SCRIPT_DIR/assets"
fi
HDD_SIZE="${HDD_SIZE:-64G}"

echo "[*] Work dir: $WORKDIR"
echo "[*] Assets:   $ASSETS"
if [ "$(id -u)" != "0" ]; then
  echo "    ERROR: run as root." >&2
  exit 1
fi

mkdir -p "$WORKDIR"
if [ ! -f "$ASSETS/OVMF_CODE_4M.fd" ] || [ ! -f "$ASSETS/OpenCore.qcow2" ]; then
  echo "    ERROR: OSX-KVM assets missing under $ASSETS" >&2
  echo "    Expected OVMF_CODE_4M.fd and OpenCore.qcow2 (bundled by the module)." >&2
  exit 1
fi

# Copy (not symlink) so the chroot bind-mount always sees real files.
cp -f "$ASSETS/OVMF_CODE_4M.fd"            "$WORKDIR/"
cp -f "$ASSETS/OVMF_VARS-1024x768.fd"      "$WORKDIR/"
cp -f "$ASSETS/OVMF_VARS-1920x1080.fd"     "$WORKDIR/"
cp -f "$ASSETS/OVMF_VARS.fd"               "$WORKDIR/"
cp -f "$ASSETS/OpenCore.qcow2"             "$WORKDIR/"
cp -f "$ASSETS/config.plist"               "$WORKDIR/" 2>/dev/null || true
cp -f "$ASSETS/fetch-macOS-v2.py"          "$WORKDIR/"
cp -f "$ASSETS/CREDITS.md"                 "$WORKDIR/" 2>/dev/null || true
cp -f "$ASSETS/OSX-KVM-README.md"          "$WORKDIR/" 2>/dev/null || true
chmod 0755 "$WORKDIR/fetch-macOS-v2.py"

# Create an empty qcow2 HDD for the macOS install if missing.
# Prefer qemu-img from the Debian chroot if available.
if [ ! -f "$WORKDIR/mac_hdd_ng.img" ]; then
  echo "[*] Creating empty macOS HDD ($HDD_SIZE) at $WORKDIR/mac_hdd_ng.img"
  if [ -x /data/local/debian/usr/bin/qemu-img ]; then
    /data/local/enter-debian.sh "qemu-img create -f qcow2 /data/local/osx-kvm/mac_hdd_ng.img $HDD_SIZE"
  elif command -v qemu-img >/dev/null 2>&1; then
    qemu-img create -f qcow2 "$WORKDIR/mac_hdd_ng.img" "$HDD_SIZE"
  else
    echo "    WARN: qemu-img not found yet. Run 'Install QEMU in chroot' first,"
    echo "          then re-run this step (or create the image manually)."
  fi
else
  echo "[*] HDD already exists: $WORKDIR/mac_hdd_ng.img"
fi

echo
echo "[done] OSX-KVM tree ready at $WORKDIR"
echo "       Next: fetch macOS 14 recovery (Fetch Sonoma), then Boot macOS 14."
ls -lh "$WORKDIR" | sed 's/^/    /'
