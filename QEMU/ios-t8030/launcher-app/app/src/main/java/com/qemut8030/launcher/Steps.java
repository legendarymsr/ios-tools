// SPDX-License-Identifier: GPL-3.0-or-later
package com.qemut8030.launcher;

public final class Steps {
    public static final String BANNER =
        "iOS 16.5 VM on this phone: HackiOS by OOSEX GANG (github.com/oosexgang,\n"
      + "hackios-web.vercel.app) - the unmodified iOS 16.5 user space on Apple's open-source XNU\n"
      + "kernel, in QEMU's virt machine inside a Debian chroot, with network, jailbroken their way\n"
      + "(Procursus + Sileo: packages without an Apple account).\n"
      + "TCG only (no KVM, no GPU): slow - the home screen takes several minutes.\n"
      + "Their code is cloned at run time (kernel APSL 2.0, userland MIT) and iOS 16.5 is downloaded\n"
      + "from Apple's CDN onto this phone - nothing of theirs or Apple's is shipped in this app.\n"
      + "HackiOS is not affiliated with Apple; this launcher is not made by OOSEX GANG.";

    public static final class Step {
        public final String label; public final String command;
        public Step(String l, String c) { label = l; command = c; }
    }

    static final String DETACH =
        "for c in /sys/fs/cgroup /acct; do [ -w \"$c/cgroup.procs\" ] && echo $$ > \"$c/cgroup.procs\"; done 2>/dev/null; ";

    // The chroot runs the copy of hackios.sh in /root: refresh it from the app on every step.
    // The bundled NewTerm deb (if present) rides along so the build can bundle it without a network
    // fetch; the copy is best-effort so older payloads without it still work.
    static final String SYNC =
        "mkdir -p /data/local/debian/root && cp -f \"{P}\"/hackios.sh \"{P}\"/timesync-arm64 /data/local/debian/root/ "
      + "&& chmod 0755 /data/local/debian/root/hackios.sh; "
      + "cp -f \"{P}\"/ws.hbang.newterm3_iphoneos-arm64.deb /data/local/debian/root/ 2>/dev/null; "
      + "cp -f \"{P}\"/rootful-arm64 /data/local/debian/root/ 2>/dev/null; ";

    /** "Power off VM" button. */
    public static final String POWER_OFF =
        SYNC + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh stop'";

    /** "Save iOS snapshot" button: works while the Boot step is still running. */
    public static final String SAVE =
        SYNC + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh save'";

    public static final Step[] STEPS = new Step[] {
        new Step("1. Install & update Debian (chroot)",
            "ROOTFS=/data/local/debian sh {P}/setup-debian-chroot.sh"),
        new Step("2. Install HackiOS (QEMU, tools, their repositories)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh setup'"),
        new Step("3. Download iOS 16.5 + build images (long)",
            SYNC
          // iOS gets Android's time zone (expanded here, on the Android side)
          + DETACH + "sh /data/local/enter-debian.sh \"HACKIOS_TZ=$(getprop persist.sys.timezone) bash /root/hackios.sh build\""),
        new Step("4. Boot iOS 16.5 (VNC, network)",
            SYNC
          + DETACH + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh run'"),
        new Step("5. Status",
            SYNC + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh status'"),
        new Step("6. Forget the snapshot (next boot starts afresh)",
            SYNC + "sh /data/local/enter-debian.sh 'bash /root/hackios.sh forget'"),
    };
    private Steps() {}
}
