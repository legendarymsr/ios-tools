# general-kvm — KVM-accelerated QEMU on Android

Run ARM64 Linux and Windows-on-ARM guests under QEMU with hardware **KVM**
acceleration on a rooted phone. Packaged as a KernelSU/Magisk module that
installs the **QEMU KVM** launcher app.

- Module zip: **`qemu-kvm-launcher-v1.0.1.zip`**
- App package: `com.qemukvm.launcher` (label "QEMU KVM")
- App source: [`launcher-app/`](launcher-app/)

## v1.0.1

- Fixed Debian chroot bootstrap on Android: rootfs URL now resolves a current
  linuxcontainers.org bookworm/arm64 `rootfs.tar.xz` (~95 MB), with size/type
  checks and cleanup on failure. Bundles static `xz-arm64` (Android toybox tar
  has no xz). Re-flash/re-run **Set up Debian chroot** if a prior run failed.

## Install

1. Open the **KernelSU manager → Modules → Install from storage**, pick
   `qemu-kvm-launcher-v1.0.1.zip`, reboot.
2. "QEMU KVM" appears in your app drawer. Open it and grant root.

(Manual alternative: `adb install launcher-app/app/build/outputs/apk/debug/app-debug.apk`.)

## Use (buttons in the app, top to bottom)

1. **Check /dev/kvm** — runs the bundled `kvmcheck` and tells you whether KVM is
   truly usable (device node, API version, caps, and an actual `KVM_CREATE_VM`).
2. **Expose /dev/kvm (chmod 666)** — makes the node usable by the chroot/app.
3. **Set up Debian chroot** — downloads a Debian arm64 rootfs to
   `/data/local/debian` and writes `/data/local/enter-debian.sh` (a real chroot
   with `/dev`, `/proc`, `/sys` and `/dev/kvm` bind-mounted).
4. **Install QEMU in chroot** — `apt install qemu-system-arm qemu-system-x86 …`
   (Debian's prebuilt glibc binaries — the fast, reliable path).
5. **Show ARM64 Linux run command** — prints `run-arm64-linux.sh`.

Then, inside the chroot (`su -c /data/local/enter-debian.sh`):

```sh
qemu-img create -f qcow2 guest.qcow2 16G
./run-arm64-linux.sh ubuntu-24.04-arm64.iso -drive file=guest.qcow2,if=virtio
```

`run-arm64-linux.sh` auto-detects KVM and uses `-enable-kvm -cpu host` when
`/dev/kvm` works, else falls back to TCG. `run-woa.sh` boots Windows on ARM (you
supply the Windows ARM64 ISO + virtio-win drivers).

### Guest images (you supply these)

Unlike the iOS t8030 module, **general-kvm does not auto-download an OS
image**. Copy any ARM64 Linux ISO (Ubuntu, Debian, Fedora, …) or a Windows
on ARM ISO into the chroot yourself (adb push, Download folder, etc.) and
pass it to `run-arm64-linux.sh` / `run-woa.sh`. That keeps the module small
and avoids redistributing third-party install media.

### Display

GUI output defaults to a **VNC server** (`-display vnc=127.0.0.1:0`) — connect
with any VNC viewer app on the phone. Override with
`DISPLAY_QEMU='-display sdl'` if you run an X server (e.g. Termux-X11), or
`DISPLAY_QEMU='-nographic'` for a serial console.

## Enabling KVM (the hard requirement)

Samsung stock kernels ship `/dev/kvm` **disabled**. You must boot your own
kernel:

- Kernel config: `CONFIG_KVM=y`, `CONFIG_VIRTUALIZATION=y`, and the virtio
  guest/host bits you want (`CONFIG_VHOST`, `CONFIG_VIRTIO_*`).
- Ensure `/dev/kvm` is created (ueventd/`CONFIG_KVM` exposes the misc device);
  `chmod 666 /dev/kvm` (the module's `service.sh` does this at boot).
- On the Snapdragon 8+ Gen 1 the kernel must run at **EL2** (or have a hyp stub)
  for KVM. If firmware/Gunyah already owns EL2, `KVM_CREATE_VM` fails even with
  the node present — `kvmcheck` reports exactly this.
- `qemu-system-aarch64 -accel help` should list `kvm`.

Cross-arch note: `-enable-kvm` only accelerates **same-arch** (ARM64) guests.
`qemu-system-x86_64` on this phone runs under TCG and is slow.

## kvm-check

[`kvm-check/`](kvm-check/) has the source (`kvmcheck.c`), `build.sh`, and the
**prebuilt** `kvmcheck-arm64` (static aarch64 Android ELF, NDK r27d). It is the
only genuinely-prebuilt native binary here; everything else (qemu) is
installed/built on-device in the chroot.

## Verified vs not

- Verified on the build host: APK assembles; `kvmcheck-arm64` is a valid static
  aarch64 Android ELF and is packaged uncompressed in the APK and the module;
  all scripts pass `bash -n`; module zip has `module.prop` at its root.
- **Not** verified: live KVM on a real device (needs a custom kernel + a phone),
  the Debian download/`apt` path (needs the device online), and actual guest
  boots. Treat on-device steps as "should work", not "tested here".
