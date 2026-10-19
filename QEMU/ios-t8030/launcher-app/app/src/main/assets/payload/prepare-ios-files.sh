#!/usr/bin/env bash
#
# prepare-ios-files.sh  --  lay out the files Inferno needs to boot an iPhone 11
# (t8030). Run INSIDE the Debian chroot, in a data folder (NOT in the Inferno
# source tree). Needs the built qemu-img (from build-inferno.sh).
#
# Preferred path: use download-and-configure.sh, which downloads the IPSW from
# Apple, calls this script, forges tickets, prepares SEP, and writes run.env.
#
# Reference target is iOS 14.0 beta 5 for iPhone12,1
# (iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw). Inferno supports iOS 14.x
# on t8030 today. Nothing copyrighted is shipped in the repo.
#
# See: https://chefkiss.dev/guides/inferno/file-setup/
set -eu
QEMU_IMG="${QEMU_IMG:-/root/Inferno/build/qemu-img}"
DATA="${DATA:-$PWD}"
IPSW="${1:-}"

[ -x "$QEMU_IMG" ] || { echo "qemu-img not found at $QEMU_IMG (build Inferno first)"; exit 1; }
cd "$DATA"

create_if_missing() {
  local name="$1" size="$2"
  if [ -e "$name" ]; then
    echo "[*] keep existing $name"
  else
    echo "[*] create $name ($size)"
    "$QEMU_IMG" create -f raw "$name" "$size"
  fi
}

echo "[*] Ensuring raw backing disks in $DATA"
create_if_missing root       32G
create_if_missing firmware   8M
create_if_missing syscfg     128K
create_if_missing ctrl_bits  8K
create_if_missing nvram      8K
create_if_missing effaceable 4K
create_if_missing panic_log  1M
create_if_missing sep_nvram  64K
create_if_missing sep_ssc    128K

if [ -n "$IPSW" ] && [ -f "$IPSW" ]; then
  if [ -f Restore/BuildManifest.plist ]; then
    echo "[*] Restore/ already extracted — skipping unzip"
  else
    echo "[*] Extracting IPSW $IPSW into ./Restore"
    mkdir -p Restore && ( cd Restore && unzip -o "$IPSW" )
    echo "[*] Done. Largest .dmg (main OS image) is only needed by the companion VM;"
    echo "    you may delete it here to save space (do NOT modify the ipsw itself)."
  fi
else
  echo "[!] No IPSW given. Prefer: ./download-and-configure.sh"
  echo "    Or re-run: ./prepare-ios-files.sh /path/to/iPhone...Restore.ipsw"
fi

echo "[*] Disks ready in $DATA"
