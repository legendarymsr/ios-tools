# QEMU on a rooted Android phone

Two QEMU deliverables for a **rooted** Android phone (built and tested against a
Samsung Galaxy Z Flip 4 — SM-F721B / `b4q`, Snapdragon 8+ Gen 1 / SM8475,
aarch64 — with **kernel root**, i.e. you can build/load your own kernel and
expose `/dev/kvm`). Each is packaged as a **KernelSU/Magisk flashable module**
that installs a small Android launcher app on flash.

| Dir | Module zip | App | What it does |
|---|---|---|---|
| [`general-kvm/`](general-kvm/) | `qemu-kvm-launcher-v1.0.1.zip` | **QEMU KVM** | Run ARM64 Linux / Windows-on-ARM guests under QEMU with hardware **KVM** acceleration |
| [`ios-t8030/`](ios-t8030/) | `qemu-t8030-launcher-v1.1.1.zip` | **iOS Emu (t8030)** | Boot an emulated **iPhone 11 (t8030)**, iOS 14.x, in Inferno under TCG; auto-downloads the IPSW from Apple on first run |

## How the modules work

Flash the zip in the **KernelSU manager** (or Magisk). On install the module:

1. `pm install`s the bundled launcher APK (retried at boot by `service.sh` if it
   fails at flash time), so you get a tappable app — **no Termux needed**.
2. Stages the bundled qemu scripts + `kvmcheck` binary to
   `/data/local/tmp/qemu-kvm` or `/data/local/tmp/qemu-t8030`.

The app is a root frontend: it extracts the same bundled scripts and runs each
step (set up a Debian chroot, build/install QEMU, run a guest) with a tap,
streaming the log on screen.

## The honest part (read this)

- **No prebuilt Android/bionic QEMU.** Upstream QEMU (and Inferno) don't build
  against Android's bionic libc — they need glib/pixman/gnutls/nettle/etc. So
  the real qemu is **built or installed on-device inside a Debian (glibc)
  chroot**. With kernel root a real `chroot` (not proot) is used so `/dev/kvm`
  passes straight through and KVM actually accelerates. The modules bundle the
  automation + the one genuinely-native helper (`kvmcheck`), not a magic qemu
  binary.
- **KVM needs a custom kernel.** Samsung stock kernels ship `/dev/kvm`
  **disabled**. You need your own kernel with `CONFIG_KVM=y` (+ virtio) that
  exposes `/dev/kvm`. On the 8+ Gen 1, KVM also depends on the kernel owning EL2
  rather than the Gunyah hypervisor — `kvmcheck` tells you if a VM can actually
  be created. Without KVM everything falls back to **slow TCG**.
- **x86_64 guests on this ARM phone run under TCG** (no KVM across
  architectures) — usable but slow.
- **iOS emulation is TCG-only, slow, no GPU, bring-up quality.** The
  launcher **auto-downloads** the reference IPSW from Apple's CDN on first
  "Download & Configure" (~5.5 GB). Nothing copyrighted from Apple is
  shipped in the repo — it is fetched at runtime for your own use.

See each subdirectory's README for exact commands and caveats.
