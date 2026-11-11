#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pack macos-kvm-launcher-vX.Y.Z.zip from the current tree + built APK.
#
#   OSXKVM=/path/to/OSX-KVM ./pack-release.sh [path/to/app-debug.apk]
#
# OSXKVM must be a kholia/OSX-KVM checkout at the pinned commit below (the
# OVMF, OpenCore and fetch-macOS-v2.py files come from there; the patches in
# patches/ are applied to fetch-macOS-v2.py). The
# META-INF/update-binary is taken from the newest older module zip in this
# directory (Magisk's standard module installer).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OSXKVM_COMMIT=4c378a4b5e0b219783683012bec680325eb40719   # "Support for macOS Tahoe"
GRADLE="$HERE/launcher-app/app/build.gradle.kts"
VER=$(sed -n 's/.*versionName *= *"\([^"]*\)".*/\1/p' "$GRADLE")
VC=$(sed -n 's/.*versionCode *= *\([0-9]*\).*/\1/p' "$GRADLE")
APK=${1:-$HERE/launcher-app/app/build/outputs/apk/debug/app-debug.apk}
[ -f "$APK" ] || { echo "missing APK: $APK"; exit 1; }
: "${OSXKVM:?set OSXKVM to a kholia/OSX-KVM checkout}"
GOT=$(git -C "$OSXKVM" rev-parse HEAD)
[ "$GOT" = "$OSXKVM_COMMIT" ] || { echo "OSX-KVM is at $GOT, expected $OSXKVM_COMMIT"; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/app" "$STAGE/payload/assets"

TEMPLATE=
for z in $(ls "$HERE"/macos-kvm-launcher-v*.zip 2>/dev/null | grep -v "v${VER}\.zip$" | sort -Vr); do
  if unzip -l "$z" | grep -q 'META-INF/com/google/android/update-binary'; then TEMPLATE=$z; break; fi
done
[ -n "$TEMPLATE" ] || { echo "no older macos-kvm-launcher-v*.zip here to take META-INF from (gh release download macos-kvm-v1.0.4)"; exit 1; }
echo "META-INF from: $(basename "$TEMPLATE")"
unzip -qo "$TEMPLATE" 'META-INF/*' -d "$STAGE"

cat > "$STAGE/module.prop" <<PROP
id=macos_kvm_launcher
name=macOS KVM Launcher
version=v${VER}
versionCode=${VC}
author=legendarymsr
description=v${VER}: macOS 26 (Tahoe) by default, macOS 14 (Sonoma) still selectable. Installs the macOS KVM launcher app and stages OSX-KVM (OVMF/OpenCore) + scripts for a macOS QEMU VM. Guest is x86_64 on aarch64 host = TCG only (NO KVM); expect VERY slow. Based on kholia/OSX-KVM. No Apple images shipped.
PROP
sed "s/@VER@/${VER}/g" "$HERE/module/customize.sh" > "$STAGE/customize.sh"
cp "$HERE/module/service.sh" "$STAGE/service.sh"
cp "$APK" "$STAGE/app/macos-kvm-launcher.apk"

PAYLOAD=(setup-debian-chroot.sh install-qemu-x86.sh setup-osx-kvm.sh macos-versions.sh
         fetch-macos.sh boot-macos.sh xz-arm64)
for f in "${PAYLOAD[@]}"; do
  cp -a "$HERE/$f" "$STAGE/payload/"
  # the app runs its own copies (assets/payload); refuse an APK built from other files
  cmp -s "$HERE/$f" "$HERE/launcher-app/app/src/main/assets/payload/$f" \
    || { echo "launcher-app assets/payload/$f differs from $f: rebuild the APK (assembleDebug syncs it)"; exit 1; }
  unzip -p "$APK" "assets/payload/$f" | cmp -s - "$HERE/$f" \
    || { echo "the APK's assets/payload/$f is not this $f: rebuild the APK"; exit 1; }
done
cp -a "$HERE/launcher-app/app/src/main/assets/payload/LICENSE-xz" "$STAGE/payload/"

# Guest post-install script (run inside macOS, not on the phone).
# Kept out of PAYLOAD/APK assets so pack-release does not require a rebuild
# of the launcher just to change this file; the APK version still tracks
# the module version.
[ -f "$HERE/guest/debloat-macos.sh" ] || { echo "missing guest/debloat-macos.sh"; exit 1; }
bash -n "$HERE/guest/debloat-macos.sh" || { echo "guest/debloat-macos.sh failed bash -n"; exit 1; }
mkdir -p "$STAGE/payload/guest"
cp -a "$HERE/guest/debloat-macos.sh" "$STAGE/payload/guest/"
chmod 0755 "$STAGE/payload/guest/debloat-macos.sh"

cp "$OSXKVM/OVMF_CODE_4M.fd" "$OSXKVM/OVMF_VARS-1024x768.fd" "$OSXKVM/OVMF_VARS-1920x1080.fd" \
   "$OSXKVM/OVMF_VARS.fd" "$OSXKVM/OVMF-notes.txt" "$OSXKVM/fetch-macOS-v2.py" \
   "$OSXKVM/CREDITS.md" "$OSXKVM/OpenCore/OpenCore.qcow2" "$OSXKVM/OpenCore/config.plist" \
   "$STAGE/payload/assets/"
cp "$OSXKVM/README.md" "$STAGE/payload/assets/OSX-KVM-README.md"
# OpenCore boots the installer (or macOS) on its own: opencore/oc-config.py
# edits config.plist, which is then written into the image's ESP.
for t in qemu-img mcopy; do command -v $t >/dev/null || { echo "need $t (qemu-utils, mtools)"; exit 1; }; done
OCRAW="$STAGE/oc.raw"
qemu-img convert -O raw "$STAGE/payload/assets/OpenCore.qcow2" "$OCRAW"
OCESP="$OCRAW@@$((2048*512))"   # ESP starts at sector 2048
mcopy -n -i "$OCESP" ::/EFI/OC/config.plist "$STAGE/oc-embedded.plist"
cmp -s "$STAGE/oc-embedded.plist" "$STAGE/payload/assets/config.plist" \
  || { echo "OpenCore.qcow2's config.plist is not OpenCore/config.plist"; exit 1; }
python3 "$HERE/opencore/oc-config.py" "$STAGE/payload/assets/config.plist" "$STAGE/oc-new.plist"
cp "$STAGE/oc-new.plist" "$STAGE/payload/assets/config.plist"
mcopy -o -i "$OCESP" "$STAGE/oc-new.plist" ::/EFI/OC/config.plist
mcopy -n -i "$OCESP" ::/EFI/OC/config.plist - | cmp -s - "$STAGE/oc-new.plist" || { echo "config.plist write failed"; exit 1; }
qemu-img convert -c -O qcow2 "$OCRAW" "$STAGE/payload/assets/OpenCore.qcow2"
rm -f "$OCRAW" "$STAGE/oc-embedded.plist" "$STAGE/oc-new.plist"
# Local fixes to the upstream downloader (patches/*.patch, applied in order)
for p in "$HERE"/patches/fetch-macOS-v2-*.patch; do
  echo "patch: $(basename "$p")"
  patch --quiet --forward --no-backup-if-mismatch -d "$STAGE/payload/assets" -p1 < "$p"
done
# verify_image() must not need a terminal (the app runs scripts without one)
python3 - "$STAGE/payload/assets/fetch-macOS-v2.py" <<'PY'
import ast, sys
src = open(sys.argv[1]).read()
fn = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef) and n.name == "verify_image")
if "os.get_terminal_size" in ast.get_source_segment(src, fn):
    sys.exit("fetch-macOS-v2.py: verify_image() still calls os.get_terminal_size()")
PY
python3 -m py_compile "$STAGE/payload/assets/fetch-macOS-v2.py"
rm -rf "$STAGE/payload/assets/__pycache__"

OUT="$HERE/macos-kvm-launcher-v${VER}.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" META-INF module.prop customize.sh service.sh app payload )
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}')) versionCode=$VC"
