#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
SKIPUNZIP=0
ui_print "- macOS KVM Launcher v@VER@ (OSX-KVM / macOS 26 Tahoe, Sonoma optional)"
ui_print "- HONEST WARNING: guest is x86_64 on aarch64 = TCG only, VERY slow."
APK="$MODPATH/app/macos-kvm-launcher.apk"
ui_print "- Installing launcher app (com.macoskvm.launcher) ..."
if [ -f "$APK" ]; then
  (pm install -r -g "$APK" || pm install -r "$APK") >/dev/null 2>&1 \
    && ui_print "- App installed. Open it from your launcher." \
    || ui_print "- pm install failed now; it will retry at next boot (service.sh)."
else
  ui_print "- ERROR: bundled APK missing."
fi

mkdir -p /data/local/osx-kvm/assets
mkdir -p /data/local/tmp/macos-kvm
cp -f "$MODPATH"/payload/*.sh "$MODPATH"/payload/xz-arm64 "$MODPATH"/payload/LICENSE-xz \
  /data/local/tmp/macos-kvm/ 2>/dev/null
cp -f "$MODPATH"/payload/*.sh "$MODPATH"/payload/xz-arm64 \
  /data/local/osx-kvm/ 2>/dev/null
cp -af "$MODPATH"/payload/assets/. /data/local/osx-kvm/assets/ 2>/dev/null
if [ -f "$MODPATH/payload/guest/debloat-macos.sh" ]; then
  mkdir -p /data/local/osx-kvm/guest /data/local/tmp/macos-kvm/guest
  cp -f "$MODPATH/payload/guest/debloat-macos.sh" /data/local/osx-kvm/guest/
  cp -f "$MODPATH/payload/guest/debloat-macos.sh" /data/local/tmp/macos-kvm/guest/
  chmod 0755 /data/local/osx-kvm/guest/debloat-macos.sh /data/local/tmp/macos-kvm/guest/debloat-macos.sh
fi
chmod 0755 /data/local/tmp/macos-kvm/* 2>/dev/null
chmod 0755 /data/local/osx-kvm/*.sh /data/local/osx-kvm/xz-arm64 /data/local/osx-kvm/assets/fetch-macOS-v2.py 2>/dev/null
ui_print "- Bundled scripts staged at /data/local/tmp/macos-kvm"
ui_print "- OSX-KVM assets staged at /data/local/osx-kvm/assets"
ui_print "- Guest debloat script staged at /data/local/osx-kvm/guest (run it inside macOS, not here)"
ui_print "- v@VER@: fixes the viewer crash on open (v1.1.5/v1.1.6). Recovery image and disk are kept. Rebooting stops a running VM. Do not run Boot again unless the VM has already stopped."
set_perm_recursive "$MODPATH" 0 0 0755 0644
chmod 0644 "$APK" 2>/dev/null
ui_print "- Done. Open 'macOS KVM', grant root, follow the buttons."
