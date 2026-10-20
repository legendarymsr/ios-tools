package com.qemut8030.launcher;

public final class Steps {
    public static final String BANNER =
        "iOS t8030 (iPhone 11) emulator launcher — Inferno / ex-QEMUAppleSilicon.\n"
      + "Bundled: Debian-chroot setup + Inferno build + Apple IPSW auto-download.\n"
      + "TCG only: SLOW, no GPU, bring-up quality. iOS 14.x supported.\n"
      + "Kernel jailbreak patches (AMFI/codesign) are applied by Inferno on every boot;\n"
      + "Step 5 restores the IPSW automatically (idevicerestore + VHCI USB or a USB-host VM);\n"
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

    // Sync every payload file the chroot scripts reference. Flat cp of named
    // files used to drop nested dirs (vhci-bridge/) and new patches — keep this
    // wholesale so step 5+ always see the same tree the Magisk module installs.
    static final String SYNC =
        "DEST=/data/local/debian/root; "
      + "mkdir -p \"$DEST\"; "
      + "cp -f {P}/*.sh {P}/*.py {P}/*.patch \"$DEST\"/ 2>/dev/null; "
      + "if [ -x {P}/xz-arm64 ]; then cp -f {P}/xz-arm64 \"$DEST\"/; fi; "
      + "if [ -d {P}/vhci-bridge ]; then "
      + "  rm -rf \"$DEST\"/vhci-bridge; "
      + "  cp -a {P}/vhci-bridge \"$DEST\"/; "
      + "fi; "
      + "chmod 0755 \"$DEST\"/*.sh \"$DEST\"/xz-arm64 2>/dev/null; "
      + "chmod 0755 \"$DEST\"/vhci-bridge 2>/dev/null; "
      + "true; ";

    public static final Step[] STEPS = new Step[] {
        new Step("1. Install & update Debian (chroot)",
            "ROOTFS=/data/local/debian sh {P}/setup-debian-chroot.sh"),
        new Step("2. Install build deps (chroot)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/setup-build-deps.sh'"),
        new Step("3. Compile Inferno / qemu-t8030 in the chroot (long)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/build-inferno.sh'"),
        new Step("4. Download & Configure (Apple IPSW)",
            // Progress streams back through the app log. ~5.5 GB — needs Wi-Fi + space.
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'DATA=/root/InfernoData bash /root/download-and-configure.sh'"),
        new Step("5. Restore iOS (automatic, long)",
            // Builds idevicerestore/usbmuxd + vhci-bridge (or companion USB VM),
            // boots the restore ramdisk, runs idevicerestore, applies ChefKiss
            // FS patches, marks RESTORED. Detached; tapping again re-attaches.
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/restore-ios.sh'"),
        new Step("6. Boot iOS (t8030)",
            SYNC
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
            // (written by linux-apfs-rw inside the step-5 USB-host / VHCI path).
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/jailbreak-prep.sh stage'"),
    };
    private Steps() {}
}
