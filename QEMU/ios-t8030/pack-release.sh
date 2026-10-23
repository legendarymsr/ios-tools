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
mkdir -p "$STAGE/META-INF/com/google/android" "$STAGE/app" "$STAGE/payload"
# module bits from last zip template if present, else recreate
# (newest committed zip that still carries update-binary + service.sh)
TEMPLATE=
for z in $(ls "$HERE"/qemu-t8030-launcher-v*.zip 2>/dev/null | grep -v "v${VER}\.zip$" | sort -Vr); do
  if unzip -l "$z" | grep 'update-binary' >/dev/null && unzip -l "$z" | grep ' service\.sh$' >/dev/null; then
    TEMPLATE=$z; break
  fi
done
if [ -n "$TEMPLATE" ]; then
  echo "module template: $(basename "$TEMPLATE")"
  unzip -qo "$TEMPLATE" META-INF/* customize.sh service.sh -d "$STAGE"
else
  printf '#MAGISK\n' > "$STAGE/META-INF/com/google/android/updater-script"
fi
# Always rewrite customize/module.prop for this version
cat > "$STAGE/module.prop" <<PROP
id=qemu_t8030_launcher
name=iOS VM launcher (HackiOS)
version=v${VER}
versionCode=${VC}
author=legendarymsr
description=v${VER}: installs the iOS VM (HackiOS) launcher app - iOS 16.5 on XNU in QEMU virt (HackiOS by OOSEX GANG, github.com/oosexgang) in a Debian chroot. Not affiliated with Apple or OOSEX GANG.
PROP
cat > "$STAGE/customize.sh" <<'CUS'
#!/system/bin/sh
SKIPUNZIP=0
ui_print "- iOS VM launcher (HackiOS by OOSEX GANG - github.com/oosexgang)"
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
chmod 0755 /data/local/tmp/qemu-t8030/* 2>/dev/null
ui_print "- Bundled scripts staged at /data/local/tmp/qemu-t8030"
ui_print "- v@VER@: HackiOS only (the Inferno t8030 steps are gone); viewer buttons are the iPhone's Home/Lock/Volume"
set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0644 "$APK" 2>/dev/null
ui_print "- Done."
CUS
sed -i "s/@VER@/${VER}/" "$STAGE/customize.sh"
cp "$APK" "$STAGE/app/qemu-t8030-launcher.apk"
# payload: the chroot installer and hackios.sh
PAYLOAD=(hackios.sh setup-debian-chroot.sh xz-arm64 LICENSE-xz)
for f in "${PAYLOAD[@]}"; do
  cp -a "$HERE/$f" "$STAGE/payload/"
done
OUT="$HERE/qemu-t8030-launcher-v${VER}.zip"
rm -f "$OUT"
( cd "$STAGE" && zip -qr "$OUT" META-INF module.prop customize.sh service.sh app payload )
echo "Wrote $OUT ($(du -h "$OUT" | awk '{print $1}')) versionCode=$VC"
