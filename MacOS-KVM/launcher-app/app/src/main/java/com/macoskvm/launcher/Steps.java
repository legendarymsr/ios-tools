package com.macoskvm.launcher;

public final class Steps {
    public static final String BANNER =
        "macOS KVM launcher — macOS 14 (Sonoma) via OSX-KVM on Android.\n"
      + "Host is aarch64, guest is x86_64 → TCG only (NO KVM). Expect VERY slow.\n"
      + "Based on https://github.com/kholia/OSX-KVM — attribution in CREDITS.md.\n"
      + "No Apple images are shipped; Fetch Sonoma downloads recovery on-device.\n"
      + "Apple EULA applies. You should legally own a Mac to use macOS.";

    public static final class Step {
        public final String label; public final String command;
        public Step(String l, String c) { label = l; command = c; }
    }

    public static final Step[] STEPS = new Step[] {
        new Step("1. Set up Debian chroot",
            "ROOTFS=/data/local/debian sh {P}/setup-debian-chroot.sh"),
        new Step("2. Install qemu-system-x86 in chroot",
            "cp {P}/install-qemu-x86.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh 'bash /root/install-qemu-x86.sh'"),
        new Step("3. Stage OSX-KVM assets + create HDD",
            "ASSETS=/data/local/osx-kvm/assets WORKDIR=/data/local/osx-kvm "
          + "sh {P}/setup-osx-kvm.sh"),
        new Step("4. Fetch macOS 14 (Sonoma) recovery",
            "cp {P}/fetch-sonoma.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh 'bash /root/fetch-sonoma.sh'"),
        new Step("5. Boot macOS 14 (TCG / VNC :5900)",
            "cp {P}/boot-macos14.sh /data/local/debian/root/ 2>/dev/null; "
          + "sh /data/local/enter-debian.sh 'bash /root/boot-macos14.sh'"),
        new Step("Show boot script (first 40 lines)",
            "sed -n '1,40p' {P}/boot-macos14.sh"),
    };
    private Steps() {}
}
