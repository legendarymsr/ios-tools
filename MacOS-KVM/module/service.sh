#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# late_start service: retry app install if flash-time pm failed.
MODDIR=${0%/*}
if ! pm path com.macoskvm.launcher >/dev/null 2>&1; then
  pm install -r -g "$MODDIR/app/macos-kvm-launcher.apk" >/dev/null 2>&1 || true
fi
