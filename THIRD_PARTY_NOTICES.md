# Third-party notices

| Component | License | In this repo? | Notes |
|---|---|---|---|
| HakiOS (oosexgang/hakios-xnu-kernel) | APSL-2.0 (kernel patch, `xnu/files`), MIT (everything else) | No, fetched at a pinned commit | Kernel-derived files would go in `kernel-patches/` under APSL-2.0 |
| TrollStore / TrollHelper (opa334) | MIT (`RootHelper/uicache.m`: BSD-4-Clause) | No, downloaded at runtime | |
| palera1n | MIT | No, invoked by Checkm8OTG | |
| gaster (0x7ff) | Apache-2.0 | No, invoked by Checkm8OTG | |
| KernelSU | GPL-3.0 | No | Host the modules run on; modules are not derivative works |
| QEMU / qemu-t8030 | GPL-2.0 (files GPL-2.0-or-later, BSD, MIT) | No, installed from Debian or built | Shipping modified binaries requires the corresponding source |
| Inferno (ChefKissInc QEMU fork) | AGPL-3.0-or-later (patched files) | Patches: `QEMU/ios-t8030/inferno-*.patch` | |
| idevicerestore | LGPL-3.0-or-later | Patches: `QEMU/ios-t8030/idevicerestore-*.patch` | |
| libirecovery | LGPL-2.1-or-later | Patch: `QEMU/ios-t8030/libirecovery-no-usb.patch` | |
| Procursus | 0BSD | No | Rootless `/var/jb` conventions only |
| NewTerm 3 (HASHBANG Productions) | Apache-2.0 | `.deb`, unmodified | See `QEMU/ios-t8030/NewTerm-NOTICE.md` |
| xz utils | 0BSD / public domain (some tools LGPL/GPL) | `xz-arm64` binaries | See `LICENSE-xz` alongside each copy |
| Gradle wrapper | Apache-2.0 | `gradlew`, `gradlew.bat`, wrapper jar | |
| OSX-KVM (kholia) | No clear license file upstream | Adapted in MacOS-KVM (`Steps.java` and module assets) | Left without an SPDX header. Either get permission from upstream or fetch these files at setup time instead of shipping them |

Apple iOS/macOS images, firmware and SDKs are not included and are never redistributed.
