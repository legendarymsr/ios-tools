#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Edit OSX-KVM's OpenCore config.plist so the picker boots on its own.

Usage: oc-config.py <in config.plist> <out config.plist>

- Misc/Boot/Timeout 5: boot the default entry after 5 seconds; any key or
  pointer event at the picker stops the countdown.
- Misc/Security/ScanPolicy 0x301 (OC_SCAN_FILE_SYSTEM_LOCK | ALLOW_FS_APFS |
  ALLOW_FS_HFS): list only APFS and HFS volumes. Upstream (0) also lists
  OpenCore's own ESP as "EFI"; that entry becomes the default and booting it
  goes nowhere, so the picker waited for input. BaseSystem.img (GPT, Apple_HFS)
  and the macOS disk (APFS) are still listed.
- ShowPicker and HideAuxiliary stay on, so the picker shows the countdown and
  the installer is the only entry until macOS is on the disk.
"""
import plistlib
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    cfg = plistlib.load(f)
boot = cfg["Misc"]["Boot"]
sec = cfg["Misc"]["Security"]
# Refuse to edit a config that no longer looks like the one this was made for
assert boot["ShowPicker"] is True and boot["HideAuxiliary"] is True, "upstream picker settings changed"
assert sec["ScanPolicy"] == 0, "upstream ScanPolicy changed"
boot["Timeout"] = 5
sec["ScanPolicy"] = 0x301
with open(dst, "wb") as f:
    plistlib.dump(cfg, f, sort_keys=False)
