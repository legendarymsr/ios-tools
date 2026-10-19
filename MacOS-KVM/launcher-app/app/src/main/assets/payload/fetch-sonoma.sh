#!/usr/bin/env bash
#
# fetch-sonoma.sh
# Download the macOS 14 (Sonoma) recovery image via OSX-KVM's fetch-macOS-v2.py
# and convert BaseSystem.dmg -> BaseSystem.img with dmg2img.
#
# Run INSIDE the Debian chroot (needs python3 + dmg2img + network), with
# /data/local/osx-kvm bind-mounted. Does NOT commit/ship Apple images.
#
# Apple EULA applies to anything you download. You must be legally entitled
# to use macOS (typically: owning a Mac). This script only automates the
# public recovery download that OSX-KVM already documents.
set -eu

WORKDIR="${WORKDIR:-/data/local/osx-kvm}"
cd "$WORKDIR"

if [ ! -f fetch-macOS-v2.py ]; then
  echo "ERROR: fetch-macOS-v2.py missing in $WORKDIR — run setup-osx-kvm.sh first." >&2
  exit 1
fi

if [ -f BaseSystem.img ] && [ -s BaseSystem.img ]; then
  echo "[*] BaseSystem.img already present ($(du -h BaseSystem.img | awk '{print $1}')). Skipping download."
  echo "    Delete it to re-fetch."
  exit 0
fi

echo "[*] Fetching macOS 14 (Sonoma) recovery via fetch-macOS-v2.py --shortname sonoma"
python3 fetch-macOS-v2.py \
  --action download \
  --shortname sonoma \
  --outdir "$WORKDIR" \
  --basename BaseSystem

# The script may write BaseSystem.dmg or BaseSystem.chunklist + .dmg depending on version.
if [ -f BaseSystem.dmg ] && [ ! -f BaseSystem.img ]; then
  echo "[*] Converting BaseSystem.dmg -> BaseSystem.img (dmg2img)"
  dmg2img BaseSystem.dmg BaseSystem.img
elif [ ! -f BaseSystem.img ]; then
  # Sometimes macrecovery names files after the remote asset; look for any .dmg
  DMG=$(ls -1 *.dmg 2>/dev/null | head -1 || true)
  if [ -n "$DMG" ]; then
    echo "[*] Converting $DMG -> BaseSystem.img (dmg2img)"
    dmg2img "$DMG" BaseSystem.img
  fi
fi

if [ ! -f BaseSystem.img ]; then
  echo "ERROR: BaseSystem.img not produced. Check network / Apple CDN / script output." >&2
  ls -la "$WORKDIR" | sed 's/^/    /'
  exit 1
fi

echo
echo "[done] BaseSystem.img ready: $(du -h BaseSystem.img | awk '{print $1}')"
echo "       Apple software is subject to Apple's software license agreement."
echo "       Next: Boot macOS 14 (TCG — expect it to be VERY slow)."
