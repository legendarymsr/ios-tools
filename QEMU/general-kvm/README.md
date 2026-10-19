# general-kvm — KVM-accelerated QEMU on Android

Run ARM64 Linux and Windows-on-ARM guests under QEMU with hardware **KVM**
acceleration on a rooted phone. Packaged as a KernelSU/Magisk module that
installs the **QEMU KVM** launcher app.

- Module zip: **`qemu-kvm-launcher-v1.0.4.zip`**
- App package: `com.qemukvm.launcher` (label "QEMU KVM")
- App source: [`launcher-app/`](launcher-app/)

## Built-in VNC viewer (v1.0.4)

The launcher app has its own VNC viewer, so no separate VNC app is needed.

- **Open VNC viewer (127.0.0.1:5900)** button at the top of the step list. It
  stays enabled while a step is running, so you can open it while the VM is up.
- There is no Boot button in this app (guests need your own disk/ISO), so run
  `run-arm64-linux.sh` / `run-woa.sh` in the chroot, then tap **Open VNC viewer**.
- The viewer retries the connection for about 60 s while QEMU is still starting,
  and shows **Disconnected — tap to reconnect** if the VM stops.
- Screen is drawn **fit-to-screen**; **pinch** to zoom (up to 8×), **two-finger
  drag** to pan, **Fit** resets.
- **Tap** = left click, **one-finger drag** = move with the left button held,
  **long press** = right click. A hardware mouse (hover + wheel) also works.
- **Keyboard** toolbar button shows/hides the soft keyboard; typed text is sent
  as key events. Extra toolbar keys: **Esc** and **Ctrl+C**. Hardware keyboards
  work too (arrows, Home/End, PgUp/PgDn, modifiers).
- **Back** closes the viewer only; the VM keeps running.
- Protocol: RFB 3.8 (3.3/3.7 accepted), security type *None* (QEMU's default
  `-display vnc=127.0.0.1:0` has no password), Raw + CopyRect encodings,
  DesktopSize so guest resolution changes are followed. Written in plain Java,
  no extra libraries.

## v1.0.3

- **v1.0.3 Install & update Debian:** step 1 is now **Install & update Debian**.
  After the rootfs is in place (or if it already is) it runs `apt-get update`
  and `apt-get upgrade -y` inside the chroot and stops with a clear error if
  either fails. Re-running it on an existing install just updates Debian.
  apt downloads as root (`APT::Sandbox::User "root"`), because Android only
  lets the inet group open sockets. `enter-debian.sh` now enters with a clean
  Debian environment, which removes the `/etc/profile: id: command not found`
  noise.

## v1.0.2

- Fixed `can't create /data/local/debian/etc/resolv.conf: No such file or
  directory`. The Debian image ships `etc/resolv.conf` as an absolute symlink to
  `/run/systemd/resolve/stub-resolv.conf`; writing through it from Android
  followed the link onto the phone's own `/run`, which doesn't exist. The
  symlink is now replaced with a real file.
- Rootfs is extracted into `/data/local/debian.staging` and only moved into
  place once `etc/os-release` and `usr/bin/sh` exist. xz and tar run as separate
  steps, and their exit codes, the download size and the archive type are
  logged. Any failure wipes the partial tree (stale bind mounts are unmounted
  first) and exits non-zero. Re-running cleans up leftovers from earlier runs.
  If your last attempt failed, just tap **Install & update Debian** again.

## v1.0.1

- Fixed Debian chroot bootstrap on Android: rootfs URL now resolves a current
  linuxcontainers.org bookworm/arm64 `rootfs.tar.xz` (~95 MB), with size/type
  checks and cleanup on failure. Bundles static `xz-arm64` (Android toybox tar
  has no xz). Re-flash/re-run **Install & update Debian** if a prior run failed.

## Install

1. Open the **KernelSU manager → Modules → Install from storage**, pick
   `qemu-kvm-launcher-v1.0.4.zip`, reboot.
2. "QEMU KVM" appears in your app drawer. Open it and grant root.

(Manual alternative: `adb install launcher-app/app/build/outputs/apk/debug/app-debug.apk`.)

## Use (buttons in the app, top to bottom)

1. **Check /dev/kvm** — runs the bundled `kvmcheck` and tells you whether KVM is
   truly usable (device node, API version, caps, and an actual `KVM_CREATE_VM`).
2. **Expose /dev/kvm (chmod 666)** — makes the node usable by the chroot/app.
3. **Install & update Debian** — downloads a Debian arm64 rootfs to
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

GUI output defaults to a **VNC server** (`-display vnc=127.0.0.1:0`) — open it with
the app's built-in **Open VNC viewer** button (or any VNC app). Override with
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
