package com.qemut8030.launcher;

public final class Steps {
    public static final String BANNER =
        "iOS t8030 (iPhone 11) emulator launcher — Inferno / ex-QEMUAppleSilicon.\n"
      + "Bundled: Debian-chroot setup + Inferno build + Apple IPSW auto-download.\n"
      + "TCG only: SLOW, no GPU, bring-up quality. iOS 14.x supported.\n"
      + "Kernel jailbreak patches (AMFI/codesign) are applied by Inferno on every boot;\n"
      + "Step 5 restores the IPSW automatically (idevicerestore + a small USB-host VM);\n"
      + "step 8 adds the bootstrap + root shell once the guest has been restored.\n"
      + "IPSW is downloaded from Apple's CDN at runtime (~5.5 GB) — nothing Apple\n"
      + "is shipped in this app. Legal to download for yourself; do not redistribute.";

    public static final class Step {
        public final String label; public final String command;
        public Step(String l, String c) { label = l; command = c; }
    }

    // Run long jobs outside the app's cgroup. Android's phantom-process killer
    // and its per-app process-group kill only look at processes in the app's
    // cgroup (uid_N/pid_M); a CPU-heavy QEMU left there gets SIGKILLed when
    // the app goes to the background (e.g. while you watch the VNC viewer).
    static final String DETACH =
        "for c in /sys/fs/cgroup /acct; do [ -w \"$c/cgroup.procs\" ] && echo $$ > \"$c/cgroup.procs\"; done 2>/dev/null; ";

    public static final Step[] STEPS = new Step[] {
        new Step("1. Install & update Debian (chroot)",
            "ROOTFS=/data/local/debian sh {P}/setup-debian-chroot.sh"),
        new Step("2. Install build deps (chroot)",
            "cp {P}/setup-build-deps.sh /data/local/debian/root/ 2>/dev/null; "
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/setup-build-deps.sh'"),
        new Step("3. Compile Inferno / qemu-t8030 in the chroot (long)",
            "cp {P}/build-inferno.sh {P}/inferno-usb-tcp-remote-fix.patch {P}/inferno-usb-tcp-remote-async.patch {P}/inferno-usb-tcp-remote-async-v129.patch {P}/inferno-usb-tcp-remote-async-v1210.patch {P}/inferno-usb-tcp-host-retry.patch {P}/inferno-dart-error-lock.patch /data/local/debian/root/ 2>/dev/null; "
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/build-inferno.sh'"),
        new Step("4. Download & Configure (Apple IPSW)",
            // Copy scripts in, then run the downloader inside the chroot so
            // qemu-img / python3 / pip / make are available. Progress streams
            // back through the app log. ~5.5 GB download — needs Wi-Fi + space.
            "cp {P}/download-and-configure.sh {P}/prepare-ios-files.sh {P}/run-t8030.sh "
          + "{P}/jailbreak-prep.sh {P}/patch-launchd.py {P}/check-sep.py "
          + "/data/local/debian/root/ 2>/dev/null; "
          + "chmod 0755 /data/local/debian/root/jailbreak-prep.sh /data/local/debian/root/patch-launchd.py "
          + "/data/local/debian/root/download-and-configure.sh "
          + "/data/local/debian/root/prepare-ios-files.sh "
          + "/data/local/debian/root/run-t8030.sh; "
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'DATA=/root/InfernoData bash /root/download-and-configure.sh'"),
        new Step("5. Restore iOS (automatic, long)",
            // Builds idevicerestore/usbmuxd + a tiny USB-host VM on first run,
            // boots the restore ramdisk, runs idevicerestore, applies the
            // ChefKiss filesystem patches, and marks the disk RESTORED. Runs
            // detached inside the chroot; tapping again re-attaches.
            "cp {P}/restore-ios.sh {P}/companion-vm.sh {P}/companion-init.sh "
          + "{P}/build-restore-tools.sh {P}/idevicerestore-inferno.patch "
          + "{P}/run-t8030.sh {P}/patch-launchd.py {P}/check-sep.py /data/local/debian/root/ 2>/dev/null; "
          + "chmod 0755 /data/local/debian/root/restore-ios.sh /data/local/debian/root/companion-vm.sh "
          + "/data/local/debian/root/build-restore-tools.sh /data/local/debian/root/run-t8030.sh; "
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/restore-ios.sh'"),
        new Step("6. Boot iOS (t8030)",
            "cp {P}/run-t8030.sh {P}/check-sep.py /data/local/debian/root/ 2>/dev/null; "
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'cd /root/InfernoData && bash /root/run-t8030.sh'"),
        new Step("7. Show READY / restore status",
            "if [ -f /data/local/debian/root/InfernoData/READY ]; then "
          + "echo '--- READY ---'; cat /data/local/debian/root/InfernoData/READY; "
          + "echo; echo '--- NEXT_STEPS ---'; "
          + "cat /data/local/debian/root/InfernoData/NEXT_STEPS.txt 2>/dev/null; "
          + "else echo 'Not configured yet — run step 4 (Download & Configure).'; fi; "
          + "echo '--- RESTORE ---'; "
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/restore-ios.sh status' 2>/dev/null "
          + "|| echo 'restore: not started (step 5)'; "
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/jailbreak-prep.sh status' 2>/dev/null"),
        new Step("8. Jailbreak bootstrap (after restore)",
            // Inferno patches AMFI/codesign in-kernel on every boot; this adds
            // the userland bootstrap + root shell to the restored System volume
            // (written by linux-apfs-rw inside the step-5 USB-host VM).
            "cp {P}/jailbreak-prep.sh {P}/patch-launchd.py {P}/run-t8030.sh {P}/companion-vm.sh /data/local/debian/root/ 2>/dev/null; "
          + "chmod 0755 /data/local/debian/root/jailbreak-prep.sh /data/local/debian/root/patch-launchd.py "
          + "/data/local/debian/root/companion-vm.sh; "
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/jailbreak-prep.sh stage'"),
    };
    private Steps() {}
}
