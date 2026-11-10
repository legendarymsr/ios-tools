#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# fetch-macos.sh
# Download a macOS recovery image (default: macOS 26 Tahoe) with OSX-KVM's
# fetch-macOS-v2.py and convert BaseSystem.dmg -> BaseSystem-<version>.img.
#
#   MACOS_VERSION=tahoe   (default) macOS 26 Tahoe
#   MACOS_VERSION=sequoia macOS 15 Sequoia
#   MACOS_VERSION=sonoma  macOS 14 Sonoma
#
# Run INSIDE the Debian chroot (needs python3 + dmg2img + network), with
# /data/local/osx-kvm bind-mounted. Does NOT commit/ship Apple images.
#
# Apple EULA applies to anything you download. You must be legally entitled
# to use macOS (typically: owning a Mac). This script only automates the
# public recovery download that OSX-KVM already documents.
set -eu

WORKDIR="${WORKDIR:-/data/local/osx-kvm}"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$HERE/macos-versions.sh" ]; then
  . "$HERE/macos-versions.sh"
else
  . "$WORKDIR/macos-versions.sh"
fi
cd "$WORKDIR"

# The module (customize.sh) stages a new fetch-macOS-v2.py in assets/ on
# every flash; use it even if step 3 was not run again.
if [ -f assets/fetch-macOS-v2.py ] && ! cmp -s assets/fetch-macOS-v2.py fetch-macOS-v2.py; then
  echo "[*] Updating fetch-macOS-v2.py from the module's assets"
  cp -f assets/fetch-macOS-v2.py fetch-macOS-v2.py
  chmod 0755 fetch-macOS-v2.py
fi

if [ ! -f fetch-macOS-v2.py ]; then
  echo "ERROR: fetch-macOS-v2.py missing in $WORKDIR - run step 3 (Stage OSX-KVM assets) first." >&2
  exit 1
fi

if [ -s "$MACOS_IMG" ]; then
  echo "[*] $MACOS_IMG already present ($(du -h "$MACOS_IMG" | awk '{print $1}')). Skipping download."
  echo "    Delete it to re-fetch."
  exit 0
fi

command -v dmg2img >/dev/null || { echo "ERROR: dmg2img missing - run step 2 (Install qemu-system-x86) again." >&2; exit 1; }

# Earlier versions of this module wrote BaseSystem.img. It was fetched with
# "--action download --shortname sonoma", but fetch-macOS-v2.py ignores
# --shortname together with --action, so that image is the recovery Apple
# serves for the script's default board (the same one as Sequoia's entry),
# not Sonoma. It is left alone; delete it yourself to free the space.
if [ -f BaseSystem.img ]; then
  echo "[!] Old BaseSystem.img from module v1.0.x found ($(du -h BaseSystem.img | awk '{print $1}')). It is not used any more;"
  echo "    delete $WORKDIR/BaseSystem.img to free the space."
fi

DL="$WORKDIR/.dl-$MACOS_VERSION"

# Check BaseSystem.dmg against BaseSystem.chunklist with fetch-macOS-v2.py's
# own verify_image(): Apple's RSA signature on the chunklist, then the
# SHA-256 of every chunk, then the total size.
verify_dl() {
  python3 - "$WORKDIR/fetch-macOS-v2.py" "$DL/BaseSystem.dmg" "$DL/BaseSystem.chunklist" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("fetch_macos", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.verify_image(sys.argv[2], sys.argv[3])
except Exception as err:
    print(f"\nImage verification failed. ({type(err).__name__}: {err})")
    sys.exit(1)
PY
}

HAVE_DMG=0
if [ -s "$DL/BaseSystem.dmg" ] && [ -s "$DL/BaseSystem.chunklist" ]; then
  echo "[*] Found an earlier download in $DL ($(du -h "$DL/BaseSystem.dmg" | awk '{print $1}')); verifying it instead of downloading again"
  if verify_dl; then
    HAVE_DMG=1
  else
    echo "[!] The earlier download did not verify; downloading again"
  fi
fi

if [ "$HAVE_DMG" = 0 ]; then
  rm -rf "$DL"
  mkdir -p "$DL"
  echo "[*] Fetching $MACOS_NAME recovery (board $MACOS_BOARD, os=$MACOS_OS_TYPE)"
  # fetch-macOS-v2.py checks the image against Apple's chunklist and exits
  # non-zero on a mismatch. If only that check fails, the files stay in $DL
  # and the next run verifies them again without downloading.
  python3 fetch-macOS-v2.py \
    --action download \
    --board-id "$MACOS_BOARD" \
    --mlb "$MACOS_MLB" \
    --os-type "$MACOS_OS_TYPE" \
    --outdir "$DL" \
    --basename BaseSystem
  [ -s "$DL/BaseSystem.dmg" ] || { echo "ERROR: BaseSystem.dmg not downloaded. Check network / Apple CDN / output above." >&2; exit 1; }
fi

echo "[*] Converting BaseSystem.dmg -> $MACOS_IMG (dmg2img)"
rm -f "$MACOS_IMG.part"
dmg2img -i "$DL/BaseSystem.dmg" -o "$MACOS_IMG.part"
[ -s "$MACOS_IMG.part" ] || { echo "ERROR: dmg2img produced no image." >&2; exit 1; }
mv -f "$MACOS_IMG.part" "$MACOS_IMG"
rm -rf "$DL"

echo
echo "[done] $MACOS_IMG ready: $(du -h "$MACOS_IMG" | awk '{print $1}')"
echo "       Apple software is subject to Apple's software license agreement."
echo "       Next: Boot $MACOS_NAME (TCG - expect it to be VERY slow)."
