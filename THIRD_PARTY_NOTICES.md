# Third-party notices

| Component | License | In this repo? | Notes |
|---|---|---|---|
| HakiOS (oosexgang/hakios-xnu-kernel) | APSL-2.0 (kernel patch, `xnu/files`), MIT (everything else) | No, fetched at a pinned commit | Kernel-derived files would go in `kernel-patches/` under APSL-2.0 |
| TrollStore / TrollHelper (opa334) | MIT (`RootHelper/uicache.m`: BSD-4-Clause) | No, downloaded at runtime | |
| palera1n | MIT | Binary in `Checkm8OTG/app/src/main/assets/` | |
| gaster (0x7ff) | Apache-2.0 | Binary in `Checkm8OTG/app/src/main/assets/` | |
| checkra1n | Proprietary freeware (`LicenseRef-checkra1n`) | Binary in `Checkm8OTG/app/src/main/assets/` | Not open source; not covered by the GPL |
| Linux USB/IP (`drivers/usb/usbip/usbip_common.h`) | GPL-2.0-or-later | Struct layouts copied into `QEMU/ios-t8030/vhci-bridge/usbip_wire.h` | Header kept GPL-2.0-or-later so it combines with the GPL-3.0-or-later bridge |
| KernelSU | GPL-3.0 | No | Host the modules run on; modules are not derivative works |
| QEMU / qemu-t8030 | GPL-2.0 (files GPL-2.0-or-later, BSD, MIT) | No, installed from Debian or built | Shipping modified binaries requires the corresponding source |
| Inferno (ChefKissInc QEMU fork) | AGPL-3.0-or-later (patched files) | Patches: `QEMU/ios-t8030/inferno-*.patch` | |
| idevicerestore | LGPL-3.0-or-later | Patches: `QEMU/ios-t8030/idevicerestore-*.patch` | |
| libirecovery | LGPL-2.1-or-later | Patch: `QEMU/ios-t8030/libirecovery-no-usb.patch` | |
| Procursus | 0BSD | No | Rootless `/var/jb` conventions only |
| NewTerm 3 (HASHBANG Productions) | Apache-2.0 | `.deb`, unmodified | See `QEMU/ios-t8030/NewTerm-NOTICE.md` |
| xz utils | 0BSD / public domain (some tools LGPL/GPL) | `xz-arm64` binaries | See `LICENSE-xz` alongside each copy |
| Gradle wrapper | Apache-2.0 | `gradlew`, `gradlew.bat`, wrapper jar | |
| OSX-KVM (kholia) | No license file upstream (GitHub reports none) | No code in this repo. `Steps.java` only links to it and is original GPL-3.0-or-later code. OpenCore/OVMF/`fetch-macOS-v2.py` are bundled only in the macOS KVM release zip | Those release-zip assets keep their own upstream terms (OpenCore BSD-3-Clause, OVMF BSD-2-Clause-Patent). Fetching them at setup time would be cleaner |

Apple iOS/macOS images, firmware and SDKs are not included and are never redistributed.
