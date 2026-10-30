// SPDX-License-Identifier: GPL-3.0-or-later
package com.qemukvm.launcher;

public final class Steps {
    public static final String BANNER =
        "QEMU KVM launcher — general ARM64/x86 virtualization.\n"
      + "Bundled: kvmcheck + Debian-chroot setup + QEMU install/run scripts.\n"
      + "KVM needs a custom kernel (CONFIG_KVM=y) exposing /dev/kvm.\n"
      + "x86_64 guests on this ARM phone run under TCG (no KVM) = slow.";

    public static final class Step {
        public final String label; public final String command;
        public Step(String l, String c) { label = l; command = c; }
    }

    public static final Step[] STEPS = new Step[] {
        new Step("1. Check /dev/kvm (kvmcheck)",
            "{P}/kvmcheck-arm64"),
        new Step("2. Expose /dev/kvm (chmod 666)",
            "if [ -e /dev/kvm ]; then chmod 666 /dev/kvm && echo \"ready: $(ls -l /dev/kvm)\"; "
          + "else echo \"NO /dev/kvm — kernel lacks CONFIG_KVM or does not expose it (see README)\"; fi"),
        new Step("3. Install & update Debian (chroot)",
            "ROOTFS=/data/local/debian sh {P}/setup-debian-chroot.sh"),
        new Step("4. Install QEMU in chroot",
            "cp {P}/install-qemu.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh 'bash /root/install-qemu.sh'"),
        new Step("5. Show ARM64 Linux run command",
            "sed -n '1,40p' {P}/run-arm64-linux.sh"),
    };
    private Steps() {}
}
