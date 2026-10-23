# ios-tools

iOS tooling and ports.

A general home for iOS porting and jailbreak projects.

## Projects

### Checkm8OTG

A rooted Android app that runs `gaster`/checkm8 and `palera1n` against a
USB-connected iPhone directly from Android (no Termux needed). Put the iPhone
in DFU, connect it over OTG, grant root, then tap **Exploit** (pwned DFU) or
**Jailbreak** (palera1n, rootless or rootful).

- Engine: bundled aarch64 `gaster`, `palera1n` v2.2, and `checkra1n`.
- Support: gaster A5–A11 / T2; palera1n A8–A11 / T2, iOS 15–26. Not A12+.
- A prebuilt debug APK (`Checkm8OTG-debug.apk`) is included for direct testing.

### QEMU (iOS emulation + KVM virtualization)

Two QEMU deliverables for a rooted Android phone, each packaged as a
**KernelSU/Magisk flashable module** that installs a tappable launcher app:

- **`QEMU/general-kvm/`** — module `qemu-kvm-launcher-v1.0.4.zip`, app "QEMU KVM".
  Run ARM64 Linux / Windows-on-ARM guests under QEMU with hardware KVM. Needs a
  custom kernel (`CONFIG_KVM=y`) exposing `/dev/kvm`. Includes a prebuilt
  `kvmcheck` aarch64 binary.
- **`QEMU/ios-t8030/`** — module `qemu-t8030-launcher-v2.1.0.zip`, app
  "iOS VM (HackiOS)". iOS 16.5 in QEMU's `virt` machine with
  [HackiOS](https://github.com/oosexgang) by OOSEX GANG, in a Debian chroot, with network.
  TCG only (slow, no GPU). HackiOS's code and iOS 16.5 (from Apple's CDN) are fetched on the
  phone; nothing of theirs or Apple's is in the repo. (The Inferno t8030 steps were removed in
  v2.0.0; see `QEMU/ios-t8030/INFERNO.md`.)

All three launcher apps have a built-in VNC viewer for the VM screen
(`127.0.0.1:5900`); the Boot steps open it automatically.

QEMU itself is installed/built on-device in a Debian chroot (no Android/bionic
QEMU exists). See [`QEMU/README.md`](QEMU/README.md) for the full picture and
honest caveats.

### MacOS-KVM

KernelSU/Magisk module that installs a **"macOS KVM"** launcher app and stages
an [OSX-KVM](https://github.com/kholia/OSX-KVM)-based **macOS 14 (Sonoma)**
QEMU stack on the phone.

- Module zip: `MacOS-KVM/macos-kvm-launcher-v1.0.4.zip`
- Guest is **x86_64** on an **aarch64** host → **TCG only, no KVM**. Expect it
  to be **VERY slow**; a full install may not be practical.
- Bundles OVMF + OpenCore from OSX-KVM; downloads Sonoma recovery on-device
  (no Apple images are committed).

See [`MacOS-KVM/README.md`](MacOS-KVM/README.md) for install steps, caveats,
and attribution.

See [`Checkm8OTG/README.md`](Checkm8OTG/README.md) for full docs and caveats.
