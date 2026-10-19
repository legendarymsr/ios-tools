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

- **`QEMU/general-kvm/`** — module `qemu-kvm-launcher-v1.0.0.zip`, app "QEMU KVM".
  Run ARM64 Linux / Windows-on-ARM guests under QEMU with hardware KVM. Needs a
  custom kernel (`CONFIG_KVM=y`) exposing `/dev/kvm`. Includes a prebuilt
  `kvmcheck` aarch64 binary.
- **`QEMU/ios-t8030/`** — module `qemu-t8030-launcher-v1.0.0.zip`, app
  "iOS Emu (t8030)". Emulate an iPhone 11 (iOS 14.x) in Inferno
  (ex-QEMUAppleSilicon) under TCG — slow, no GPU, bring-up quality; you supply
  your own legal IPSW.

QEMU itself is installed/built on-device in a Debian chroot (no Android/bionic
QEMU exists). See [`QEMU/README.md`](QEMU/README.md) for the full picture and
honest caveats.

See [`Checkm8OTG/README.md`](Checkm8OTG/README.md) for full docs and caveats.
