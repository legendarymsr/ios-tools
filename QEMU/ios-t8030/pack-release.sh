#!/usr/bin/env bash
# Pack qemu-t8030-launcher-vX.Y.Z.zip from the current tree + built APK.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VER=$(python3 -c "import pathlib,re; t=pathlib.Path('$HERE/launcher-app/app/build.gradle.kts').read_text(); print(re.search(r'versionName\s*=\s*\"([^\"]+)\"',t).group(1))")
VC=$(python3 -c "import pathlib,re; t=pathlib.Path('$HERE/launcher-app/app/build.gradle.kts').read_text(); print(re.search(r'versionCode\s*=\s*(\d+)',t).group(1))")
APK=${1:-$HERE/launcher-app/app/build/outputs/apk/debug/app-debug.apk}
[ -f "$APK" ] || { echo "missing APK: $APK"; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/META-INF/com/google/android" "$STAGE/app" "$STAGE/payload/vhci-bridge"
# module bits from last zip template if present, else recreate
if [ -f "$HERE/qemu-t8030-launcher-v1.3.2.zip" ]; then
  unzip -qo "$HERE/qemu-t8030-launcher-v1.3.2.zip" META-INF/* customize.sh service.sh -d "$STAGE"
else
  printf '#MAGISK\n' > "$STAGE/META-INF/com/google/android/updater-script"
fi
# Always rewrite customize/module.prop for this version
cat > "$STAGE/module.prop" <<PROP
id=qemu_t8030_launcher
name=iOS t8030 Emulator Launcher
version=v${VER}
versionCode=${VC}
author=legendarymsr
description=v${VER}: VHCI USB path (no companion VM when Larry kernel has USBIP/VHCI); companion VM kept as fallback + for APFS FS patches. Inferno t8030 is still TCG-only. Installs the iOS Emu (t8030) launcher app.
PROP
cat > "$STAGE/customize.sh" <<'CUS'
#!/system/bin/sh
SKIPUNZIP=0
ui_print "- iOS t8030 Emulator Launcher"
APK="$MODPATH/app/qemu-t8030-launcher.apk"
ui_print "- Installing launcher app (com.qemut8030.launcher) ..."
if [ -f "$APK" ]; then
  (pm install -r -g "$APK" || pm install -r "$APK") >/dev/null 2>&1 \
    && ui_print "- App installed. Open it from your launcher." \
    || ui_print "- pm install failed now; it will retry at next boot (service.sh)."
else
  ui_print "- ERROR: bundled APK missing."
fi
mkdir -p /data/local/tmp/qemu-t8030
cp -f "$MODPATH"/payload/* /data/local/tmp/qemu-t8030/ 2>/dev/null
# nested vhci-bridge sources
if [ -d "$MODPATH/payload/vhci-bridge" ]; then
  mkdir -p /data/local/tmp/qemu-t8030/vhci-bridge
  cp -f "$MODPATH"/payload/vhci-bridge/* /data/local/tmp/qemu-t8030/vhci-bridge/ 2>/dev/null
fi
chmod 0755 /data/local/tmp/qemu-t8030/* 2>/dev/null
chmod 0755 /data/local/tmp/qemu-t8030/vhci-bridge 2>/dev/null || true
ui_print "- Bundled scripts staged at /data/local/tmp/qemu-t8030"
ui_print "- v1.4.0: VHCI USB when the Larry kernel has USBIP; else companion VM fallback."
set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0644 "$APK" 2>/dev/null
ui_print "- Done."
CUS
cp "$APK" "$STAGE/app/qemu-t8030-launcher.apk"
# payload scripts + patches
PAYLOAD=(
  build-inferno.sh build-restore-tools.sh check-sep.py companion-init.sh companion-vm.sh
  download-and-configure.sh idevicerestore-inferno.patch idevicerestore-tcg-timeouts.patch
  inferno-dart-error-lock.patch inferno-usb-tcp-host-retry.patch inferno-usb-tcp-host-retry-v1211.patch
  inferno-usb-tcp-host-retry-v130.patch inferno-usb-tcp-remote-async.patch
  inferno-usb-tcp-remote-async-v1210.patch inferno-usb-tcp-remote-async-v129.patch
  inferno-usb-tcp-remote-async-v130.patch inferno-usb-tcp-remote-fix.patch
  jailbreak-prep.sh libirecovery-no-usb.patch patch-launchd.py prepare-ios-files.sh
  restore-ios.sh run-t8030.sh setup-build-deps.sh setup-debian-chroot.sh
  vhci-usb.sh LICENSE-xz xz-arm64
)
for f in "${PAYLOAD[@]}"; do
  [ -e "$HERE/$f" ] && cp -a "$HERE/$f" "$STAGE/payload/"
done
mkdir -p "$STAGE/payload/vhci-bridge"
cp -a "$HERE/vhci-bridge/"* "$STAGE/payload/vhci-bridge/"
OUT="$HERE/qemu-t8030-launcher-v${VER}.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" META-INF module.prop customize.sh service.sh app payload )
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}')) versionCode=$VC"
