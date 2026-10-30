#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""
patch-launchd.py - edit an iOS launchd.plist (launch service cache) for an
Inferno t8030 guest, following the ChefKiss Inferno guide:

  * "Filesystem Patches": disable services that break on the emulator
    (vmd, CommCenter*, locationd) by adding Disabled=true.
  * "Jailbreak Utility Bootstrap": add a root /bin/bash daemon on
    /dev/console so the serial console gives you a root shell.

Works on binary or XML plists (stdlib plistlib only; runs on Linux or macOS).
Writes XML, which is what the guide does. Idempotent: re-running is a no-op.
After this, the guest MUST boot with the launchd_unsecure_cache=1 boot-arg
(run-t8030.sh adds it automatically when JAILBREAK_APPLIED exists).

usage: patch-launchd.py LAUNCHD_PLIST [--out OUT] [--no-bash] [--no-disable]
"""
import argparse
import os
import plistlib
import sys

DISABLE_LABELS = [
    "com.apple.voicemail.vmd",
    "com.apple.CommCenter",
    "com.apple.CommCenterMobileHelper",
    "com.apple.CommCenterRootHelper",
    "com.apple.locationd",
]

BASH_KEY = "/System/Library/LaunchDaemons/bash.plist"
BASH_ENTRY = {
    "EnablePressuredExit": False,
    "Label": "com.apple.bash",
    "POSIXSpawnType": "Interactive",
    "ProgramArguments": ["/bin/bash"],
    "RunAtLoad": True,
    "StandardErrorPath": "/dev/console",
    "StandardInPath": "/dev/console",
    "StandardOutPath": "/dev/console",
    "Umask": 0,
    "UserName": "root",
}

FIRSTBOOT_KEY = "/System/Library/LaunchDaemons/ios-tools.firstboot.plist"
FIRSTBOOT_ENTRY = {
    "Label": "ios-tools.firstboot",
    "ProgramArguments": ["/bin/bash", "/usr/libexec/ios-tools-firstboot.sh"],
    "RunAtLoad": True,
    "UserName": "root",
    "POSIXSpawnType": "Interactive",
    "EnablePressuredExit": False,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("plist")
    ap.add_argument("--out", default=None, help="output path (default: in place)")
    ap.add_argument("--no-bash", action="store_true", help="do not add the bash daemon")
    ap.add_argument("--firstboot", action="store_true", help="add the one-shot uicache daemon")
    ap.add_argument("--no-disable", action="store_true", help="do not disable broken services")
    a = ap.parse_args()

    with open(a.plist, "rb") as f:
        data = plistlib.load(f)

    daemons = data.get("LaunchDaemons")
    if not isinstance(daemons, dict):
        print("ERROR: no LaunchDaemons dict - is this System/Library/xpc/launchd.plist?", file=sys.stderr)
        return 1

    changed = 0
    if not a.no_disable:
        found = set()
        for key, entry in daemons.items():
            if isinstance(entry, dict) and entry.get("Label") in DISABLE_LABELS:
                found.add(entry["Label"])
                if entry.get("Disabled") is not True:
                    entry["Disabled"] = True
                    changed += 1
                    print(f"[*] disabled {entry['Label']}  ({key})")
        for lbl in DISABLE_LABELS:
            if lbl not in found:
                print(f"[!] {lbl} not present in this launchd.plist (ok on some builds)")

    if not a.no_bash:
        if daemons.get(BASH_KEY) != BASH_ENTRY:
            daemons[BASH_KEY] = dict(BASH_ENTRY)
            changed += 1
            print(f"[*] added root bash daemon on /dev/console ({BASH_KEY})")

    if a.firstboot and daemons.get(FIRSTBOOT_KEY) != FIRSTBOOT_ENTRY:
        daemons[FIRSTBOOT_KEY] = dict(FIRSTBOOT_ENTRY)
        changed += 1
        print(f"[*] added one-shot icon refresh daemon (uicache) ({FIRSTBOOT_KEY})")

    out = a.out or a.plist
    # Write a new file and rename it over the old one: on iOS the plist is
    # usually an APFS-compressed (decmpfs) file, and linux-apfs-rw refuses to
    # open compressed files for writing (EOPNOTSUPP). A new inode is plain.
    st = os.stat(a.plist)
    tmp = out + ".ios-tools.tmp"
    with open(tmp, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_XML)
        f.flush()
        os.fsync(f.fileno())
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except OSError:
        pass
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, out)
    print(f"[*] wrote {out} ({changed} change(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
