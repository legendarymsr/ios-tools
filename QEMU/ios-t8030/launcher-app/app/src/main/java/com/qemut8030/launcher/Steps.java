package com.qemut8030.launcher;

public final class Steps {
    public static final String BANNER =
        "iOS t8030 (iPhone 11) emulator launcher — Inferno / ex-QEMUAppleSilicon.\n"
      + "Bundled: Debian-chroot setup + Inferno build + Apple IPSW auto-download.\n"
      + "TCG only: SLOW, no GPU, bring-up quality. iOS 14.x supported.\n"
      + "Kernel jailbreak patches (AMFI/codesign) are applied by Inferno on every boot;\n"
      + "step 7 adds the bootstrap + root shell once the guest has been restored.\n"
      + "IPSW is downloaded from Apple's CDN at runtime (~5.5 GB) — nothing Apple\n"
      + "is shipped in this app. Legal to download for yourself; do not redistribute.";

    public static final class Step {
        public final String label; public final String command;
        public Step(String l, String c) { label = l; command = c; }
    }

    public static final Step[] STEPS = new Step[] {
        new Step("1. Set up Debian chroot",
            "ROOTFS=/data/local/debian sh {P}/setup-debian-chroot.sh"),
        new Step("2. Install build deps (chroot)",
            "cp {P}/setup-build-deps.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh 'bash /root/setup-build-deps.sh'"),
        new Step("3. Build Inferno (chroot, long)",
            "cp {P}/build-inferno.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh 'bash /root/build-inferno.sh'"),
        new Step("4. Download & Configure (Apple IPSW)",
            // Copy scripts in, then run the downloader inside the chroot so
            // qemu-img / python3 / pip / make are available. Progress streams
            // back through the app log. ~5.5 GB download — needs Wi-Fi + space.
            "cp {P}/download-and-configure.sh {P}/prepare-ios-files.sh {P}/run-t8030.sh "
          + "{P}/jailbreak-prep.sh {P}/patch-launchd.py "
          + "/data/local/debian/root/ 2>/dev/null; "
          + "chmod 0755 /data/local/debian/root/jailbreak-prep.sh /data/local/debian/root/patch-launchd.py "
          + "/data/local/debian/root/download-and-configure.sh "
          + "/data/local/debian/root/prepare-ios-files.sh "
          + "/data/local/debian/root/run-t8030.sh; "
          + "sh /data/local/enter-debian.sh "
          + "'DATA=/root/InfernoData bash /root/download-and-configure.sh'"),
        new Step("5. Boot iOS (t8030)",
            "cp {P}/run-t8030.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh "
          + "'cd /root/InfernoData && bash /root/run-t8030.sh'"),
        new Step("6. Show READY status",
            "if [ -f /data/local/debian/root/InfernoData/READY ]; then "
          + "echo '--- READY ---'; cat /data/local/debian/root/InfernoData/READY; "
          + "echo; echo '--- NEXT_STEPS ---'; "
          + "cat /data/local/debian/root/InfernoData/NEXT_STEPS.txt 2>/dev/null; "
          + "else echo 'Not configured yet — run step 4 (Download & Configure).'; fi; "
          + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/jailbreak-prep.sh status' 2>/dev/null"),
        new Step("7. Jailbreak bootstrap (after restore)",
            // Inferno patches AMFI/codesign in-kernel on every boot; this adds
            // the userland bootstrap + root shell to the restored System volume.
            "cp {P}/jailbreak-prep.sh {P}/patch-launchd.py {P}/run-t8030.sh /data/local/debian/root/ 2>/dev/null; "
          + "chmod 0755 /data/local/debian/root/jailbreak-prep.sh /data/local/debian/root/patch-launchd.py; "
          + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/jailbreak-prep.sh stage'"),
    };
    private Steps() {}
}
