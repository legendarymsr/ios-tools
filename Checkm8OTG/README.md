# Checkm8 OTG

Rooted Android app that runs **gaster** (checkm8 → pwned DFU) and **palera1n v2.2** (full jailbreak) against a USB-tethered iPhone in DFU mode.

## Supported devices

### gaster / checkm8 (Exploit button)
**A5–A11 and T2** — iPhone 4S through iPhone 8 / 8 Plus / X, matching iPads, T2 Macs. **A12+ will not work.**

### palera1n jailbreak (Jailbreak button)
Per [palera1n](https://github.com/palera1n/palera1n) v2.2:

| Range | Notes |
|-------|--------|
| **A8–A11 / T2** | checkm8-capable chips palera1n supports |
| **iOS / iPadOS / tvOS 15.0 – 26.x**, bridgeOS 5–10 | Modern palera1n range |
| **Rootless (`-l`)** | Default in the app |
| **Rootful / fakefs (`-f`)** | Optional; first run with fakefs setup can take a long time and needs free space on the iPhone |
| **A11** | Disable passcode while jailbroken; on iOS 16 reset the device before proceeding |
| **A12+** | Not supported (no checkm8) |

## What you need

1. An **aarch64 Android phone** with **USB host / OTG**.
2. **Root**: KernelSU or Magisk.
3. A supported iPhone in **DFU** (not Recovery).
4. This debug APK: `Checkm8OTG-debug.apk`.

## Install

```text
adb install -r Checkm8OTG-debug.apk
```

Open the app and **grant root**.

## Use

1. Put the iPhone in DFU (screen stays black).
2. Plug it into the Android phone via OTG. App should show `05ac:1227`.
3. Either:
   - **Exploit (gaster pwn)** — only pwned DFU.
   - Pick **Rootless** or **Rootful/fakefs**, then **Jailbreak (palera1n)** — full chain (checkra1n → PongoOS → patched boot).
4. Watch the log. Keep the cable seated; palera1n can take several minutes.

**Reset USB / gaster reset** runs `gaster reset`.

## What’s bundled

| Asset | What it is |
|-------|------------|
| `assets/gaster` | aarch64 **Android NDK** PIE ELF (r27d), libusb + OpenSSL libcrypto static. Used for Exploit / Reset. |
| `assets/palera1n` | Official **palera1n-linux-arm64 v2.2** — **musl-static** Linux aarch64 ELF (not an NDK build). Embeds Pongo.bin, ramdisk, binpack overlay, kpf, and a patched checkra1n. Built with `ROOTFUL`. |
| `assets/checkra1n` | Official **checkra1n-linux-arm64 0.1337.3** — musl-static. Passed to palera1n via `-i` so we control path / chmod / SELinux. |

**Why not an NDK build of palera1n?** Upstream only ships Darwin + musl-Linux targets. Rebuilding the full libimobiledevice / mbedtls / libusb / readline dep tree for Bionic is heavy; the official static arm64 binary already embeds every payload. Documented trade-off: it is a Linux musl binary running under Android root, not a Bionic-linked Android ELF.

**Fetched at runtime?** Nothing from the network for the jailbreak boot itself — payloads are embedded. After first boot, the **iPhone** (not this app) may download bootstrap packages (Sileo, etc.) over its own network once jailbroken.

## How it works

- Extracts binaries to `files/bin/`, sets `TMPDIR=files/tmp`, `chmod 755` + best-effort `chcon`, loosens `/dev/bus/usb/*`, `setenforce 0`.
- Runs via **libsu** root shell (900s timeout).
- Jailbreak command shape: `TMPDIR=… palera1n -l|-f -S -v -i <bundled checkra1n>`.
- Android USB Host API detects DFU; exploit traffic is **libusb → usbfs** as root.

## Build

```text
export JAVA_HOME=… ANDROID_HOME=…/android-sdk
cd Checkm8OTG && ./gradlew assembleDebug
# APK → app/build/outputs/apk/debug/app-debug.apk
```

## Caveats (read these)

- **Not end-to-end tested** against a physical iPhone from this build host. APK assembles; bundled ELFs are valid aarch64. USB + root behavior depends on your ROM.
- **musl-static on Android**: works on many rooted aarch64 phones with `setenforce 0`. May fail on **16 KB page-size** kernels (some Android 15+ devices) with “Exec format error”. gaster (NDK/Bionic) is fine on those; palera1n/checkra1n may not be.
- **No usbmuxd** on Android: DFU → checkra1n → Pongo path uses raw USB and should work. Features that need usbmuxd/idevice* (some recovery helpers, post-boot device info over lockdown) may fail.
- **SELinux**: app tries `setenforce 0` and `chcon`. Strict setups may still block exec-from-app-data.
- **USB controllers / cables**: USB-A recommended by palera1n docs; some OTG stacks are flaky with Apple DFU.
- **Debug-signed APK** for sideload only.
- Root is mandatory.

## License notes

- gaster: Apache-2.0 (palera1n fork)
- palera1n: see upstream LICENSE
- checkra1n: proprietary (checkra1n team); redistributed as upstream does inside palera1n
- libusb: LGPL-2.1
- OpenSSL 1.1.1: OpenSSL / SSLeay
- App glue: use as you like
