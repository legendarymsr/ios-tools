#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Pack macos-kvm-launcher-vX.Y.Z.zip from the current tree + built APK.
#
#   OSXKVM=/path/to/OSX-KVM ./pack-release.sh [path/to/app-debug.apk]
#
# OSXKVM must be a kholia/OSX-KVM checkout at the pinned commit below (the
# OVMF, OpenCore and fetch-macOS-v2.py files come from there). The
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

cp "$OSXKVM/OVMF_CODE_4M.fd" "$OSXKVM/OVMF_VARS-1024x768.fd" "$OSXKVM/OVMF_VARS-1920x1080.fd" \
   "$OSXKVM/OVMF_VARS.fd" "$OSXKVM/OVMF-notes.txt" "$OSXKVM/fetch-macOS-v2.py" \
   "$OSXKVM/CREDITS.md" "$OSXKVM/OpenCore/OpenCore.qcow2" "$OSXKVM/OpenCore/config.plist" \
   "$STAGE/payload/assets/"
cp "$OSXKVM/README.md" "$STAGE/payload/assets/OSX-KVM-README.md"

OUT="$HERE/macos-kvm-launcher-v${VER}.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" META-INF module.prop customize.sh service.sh app payload )
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}')) versionCode=$VC"
