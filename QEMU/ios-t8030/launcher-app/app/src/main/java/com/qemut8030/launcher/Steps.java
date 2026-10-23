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
      + "is shipped in this app. Legal to download for yourself; do not redistribute.\n"
      + "H1-H3: HackiOS by OOSEX GANG (github.com/oosexgang) - iOS 16.5 on Apple's open-source\n"
      + "XNU kernel in QEMU's virt machine, with network. Their code is cloned at run time\n"
      + "(kernel APSL 2.0, userland MIT); iOS 16.5 comes from Apple's CDN. Not affiliated with Apple.";

    public static final class Step {
        public final String label; public final String command;
        public Step(String l, String c) { label = l; command = c; }
    }

    static final String DETACH =
        "for c in /sys/fs/cgroup /acct; do [ -w \"$c/cgroup.procs\" ] && echo $$ > \"$c/cgroup.procs\"; done 2>/dev/null; ";

    // Sync every payload file the chroot scripts reference. Prefer flat
    // vhci-bridge.c / vhci-bridge.tgz (AssetManager nested-dir safe), then
    // unpack into /root/vhci-bridge for the build scripts.
    static final String SYNC =
        "DEST=/data/local/debian/root; "
      + "P=\"{P}\"; "
      + "mkdir -p \"$DEST\"; "
      + "cp -f \"$P\"/*.sh \"$P\"/*.py \"$P\"/*.patch \"$DEST\"/ 2>/dev/null; "
      + "cp -f \"$P\"/vhci-bridge.c \"$P\"/vhci-bridge.tgz \"$DEST\"/ 2>/dev/null; "
      + "if [ -x \"$P\"/xz-arm64 ]; then cp -f \"$P\"/xz-arm64 \"$DEST\"/; fi; "
      + "rm -rf \"$DEST\"/vhci-bridge; "
      + "if [ -d \"$P\"/vhci-bridge ] && [ -f \"$P\"/vhci-bridge/bridge.c ]; then "
      + "  cp -a \"$P\"/vhci-bridge \"$DEST\"/; "
      + "elif [ -f \"$P\"/vhci-bridge.tgz ]; then "
      + "  tar -xzf \"$P\"/vhci-bridge.tgz -C \"$DEST\" "
      + "    || tar -xzf \"$DEST\"/vhci-bridge.tgz -C \"$DEST\"; "
      + "elif [ -f \"$P\"/vhci-bridge.c ]; then "
      + "  mkdir -p \"$DEST\"/vhci-bridge; "
      + "  cp -f \"$P\"/vhci-bridge.c \"$DEST\"/vhci-bridge/bridge.c; "
      + "fi; "
      + "chmod 0755 \"$DEST\"/*.sh \"$DEST\"/xz-arm64 2>/dev/null; "
      + "if [ ! -f \"$DEST\"/vhci-bridge/bridge.c ] && [ ! -f \"$DEST\"/vhci-bridge.c ]; then "
      + "  echo \"[ERROR] SYNC: no vhci-bridge source under $P (ls:)\"; "
      + "  ls -la \"$P\" 2>/dev/null | head -40; "
      + "  ls -la \"$P\"/vhci-bridge 2>/dev/null | head -20; "
      + "fi; "
      + "true; ";

    /** "Power off VM" button: monitor system_powerdown, ~20 s, quit, then kill. */
    public static final String POWER_OFF =
        "cp -f \"{P}\"/vm-power.sh \"{P}\"/hackios.sh /data/local/debian/root/ "
      + "&& chmod 0755 /data/local/debian/root/vm-power.sh /data/local/debian/root/hackios.sh; "
      + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/vm-power.sh off; bash /root/hackios.sh stop'";

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
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'DATA=/root/InfernoData bash /root/download-and-configure.sh'"),
        new Step("5. Restore iOS (automatic, long)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/restore-ios.sh'"),
        new Step("6. Boot iOS (t8030)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'cd /root/InfernoData && bash /root/run-t8030.sh'"),
        new Step("6b. Boot iOS with network (experimental: USB ethernet, may panic iOS 14.0)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'cd /root/InfernoData && NET=1 bash /root/run-t8030.sh'"),
        new Step("6c. Boot iOS, then connect network",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh "
          + "'DATA=/root/InfernoData bash /root/force-net.sh'"),
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
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'DATA=/root/InfernoData bash /root/jailbreak-prep.sh stage'"),
        // HackiOS (OOSEX GANG): iOS 16.5 on XNU in QEMU virt; hackios.sh clones their repositories.
        new Step("H1. HackiOS: install (by OOSEX GANG)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh setup'"),
        new Step("H2. HackiOS: download iOS 16.5 + build images (long)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh build'"),
        new Step("H3. HackiOS: Boot iOS 16.5 (VNC, network)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh run'"),
    };
    private Steps() {}
}
