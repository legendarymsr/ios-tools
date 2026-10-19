#!/usr/bin/env bash
#
# prepare-ios-files.sh  --  lay out the files Inferno needs to boot an iPhone 11
# (t8030). Run INSIDE the Debian chroot, in a data folder (NOT in the Inferno
# source tree). Needs the built qemu-img (from build-inferno.sh).
#
# YOU MUST SUPPLY, legally, a supported IPSW yourself. Nothing copyrighted is
# shipped here. The reference target is iOS 14.0 beta 5 for iPhone12,1
# (iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw). Inferno supports iOS 14.x
# on t8030 today.
#
# You also need, from the ChefKiss guide/tooling:
#   - create_apticket.py          (forges the AP ticket for unsigned iOS)
#   - a SEP ROM dump "AppleSEPROM-Cebu-B1"  (for t8030 / iPhone 11)
#   - the img4 utility + SEP firmware prep steps
# See: https://chefkiss.dev/guides/inferno/file-setup/
set -eu
QEMU_IMG="${QEMU_IMG:-/root/Inferno/build/qemu-img}"
DATA="${DATA:-$PWD}"
IPSW="${1:-}"

[ -x "$QEMU_IMG" ] || { echo "qemu-img not found at $QEMU_IMG (build Inferno first)"; exit 1; }
cd "$DATA"

echo "[*] Creating raw backing disks in $DATA"
"$QEMU_IMG" create -f raw root       32G
"$QEMU_IMG" create -f raw firmware   8M
"$QEMU_IMG" create -f raw syscfg     128K
"$QEMU_IMG" create -f raw ctrl_bits  8K
"$QEMU_IMG" create -f raw nvram      8K
"$QEMU_IMG" create -f raw effaceable 4K
"$QEMU_IMG" create -f raw panic_log  1M
"$QEMU_IMG" create -f raw sep_nvram  64K
"$QEMU_IMG" create -f raw sep_ssc    128K

if [ -n "$IPSW" ] && [ -f "$IPSW" ]; then
  echo "[*] Extracting IPSW $IPSW into ./Restore"
  mkdir -p Restore && ( cd Restore && (unzip -o "$OLDPWD/$IPSW" || tar -xf "$OLDPWD/$IPSW") )
  echo "[*] Done. Largest .dmg (main OS image) is only needed by the companion VM;"
  echo "    you may delete it here to save space (do NOT modify the ipsw itself)."
else
  echo "[!] No IPSW given. Re-run: ./prepare-ios-files.sh /path/to/iPhone...Restore.ipsw"
fi

cat <<'NEXT'

Still to do (see https://chefkiss.dev/guides/inferno/file-setup/):
  1. pip install pyasn1 pyasn1-modules
  2. python3 create_apticket.py n104ap Restore/BuildManifest.plist ticket.shsh2 root_ticket.der
  3. Place SEP ROM dump  AppleSEPROM-Cebu-B1  here (t8030/iPhone 11 = Cebu B1).
  4. Build img4 and prepare  sep-firmware.n104.RELEASE.new.img4
Then boot with:  ./run-t8030.sh
NEXT
