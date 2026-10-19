package com.qemut8030.launcher;

public final class Steps {
    public static final String BANNER =
        "iOS t8030 (iPhone 11) emulator launcher — Inferno / ex-QEMUAppleSilicon.\n"
      + "Bundled: Debian-chroot setup + Inferno build + iOS file-prep/run scripts.\n"
      + "TCG only: SLOW, no GPU, bring-up quality. iOS 14.x supported.\n"
      + "You MUST supply your own legal IPSW; nothing Apple is shipped here.";

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
        new Step("4. Show iOS file-prep steps",
            "sed -n '1,60p' {P}/prepare-ios-files.sh"),
        new Step("5. Show t8030 run command",
            "sed -n '1,40p' {P}/run-t8030.sh"),
    };
    private Steps() {}
}
