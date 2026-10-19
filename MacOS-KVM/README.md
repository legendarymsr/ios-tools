# MacOS-KVM — macOS 14 (Sonoma) QEMU VM on a rooted Android phone

KernelSU/Magisk flashable **module** that installs a tappable **"macOS KVM"**
launcher app and stages an [OSX-KVM](https://github.com/kholia/OSX-KVM)-based
macOS 14 (Sonoma) QEMU stack on the phone.

Built for a rooted Samsung Galaxy Z Flip 4 (SM-F721B / `b4q`, Snapdragon 8+
Gen 1 / SM8475, aarch64) with kernel root — but any aarch64 rooted Android with
a working Debian chroot path should be able to run the same scripts.

- Module zip: **`macos-kvm-launcher-v1.0.3.zip`**
- App package: `com.macoskvm.launcher` (label **"macOS KVM"**)
- App source: [`launcher-app/`](launcher-app/)

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

- Fixed Debian chroot bootstrap on Android (linuxcontainers.org rootfs + bundled
  `xz-arm64`; size/type checks; cleanup on failure). Re-run chroot setup if a
  prior attempt failed.
- Boot script already uses `-accel tcg` (macOS is x86_64 on ARM64 host — KVM
  cannot accelerate cross-arch guests) and logs that clearly.

## The honest part (read this first)

**macOS is an x86_64 guest. Your phone is aarch64.** There is **no KVM**
acceleration across architectures. QEMU runs the guest under **TCG** (pure
software emulation). That means:

- Booting to the OpenCore menu may take many minutes.
- A full Sonoma install under TCG on a phone is **unlikely to be practical**
  (hours to days, high chance of timeouts / watchdog kills).
- This module wires up the real OSX-KVM stack so you can try it; it does **not**
  claim a usable daily-driver Hackintosh on the Flip 4.

OSX-KVM itself assumes an **x86_64 Linux host with VT-x/AMD-V + KVM**. We keep
the same OpenCore/OVMF/fetch flow and simply drop `-enable-kvm`.

Also: there is **no prebuilt Android/bionic `qemu-system-x86_64`**. Upstream
QEMU needs glibc + a pile of libraries, so (same as the other QEMU modules in
this repo) qemu is **installed on-device inside a Debian chroot**. The module
bundles OVMF, OpenCore, scripts, and the launcher app — not a magic qemu ELF.

## What is bundled

| Piece | Where | Notes |
|---|---|---|
| Launcher APK | `app/macos-kvm-launcher.apk` inside the zip | Tap-driven root frontend |
| Setup / boot scripts | `payload/*.sh` | Also in APK `assets/payload/` |
| OVMF firmware | `payload/assets/OVMF_*.fd` | From OSX-KVM |
| OpenCore bootloader | `payload/assets/OpenCore.qcow2` + `config.plist` | From OSX-KVM |
| `fetch-macOS-v2.py` | `payload/assets/` | From OSX-KVM / Acidanthera macrecovery |
| CREDITS / upstream README | `payload/assets/` | Attribution kept intact |
| Apple BaseSystem / IPSW | **not shipped** | Downloaded on-device by step 4 |

## Install

1. Open **KernelSU manager → Modules → Install from storage**, pick
   `macos-kvm-launcher-v1.0.3.zip`, reboot.
2. **"macOS KVM"** appears in the app drawer. Open it and **grant root**.

(Manual alternative: `adb install launcher-app/dist/macos-kvm-launcher.apk`.)

On flash, `customize.sh` also stages everything under
`/data/local/osx-kvm/` and `/data/local/tmp/macos-kvm/`.

## Use (buttons in the app, top to bottom)

1. **Install & update Debian** — downloads a Debian arm64 rootfs to
   `/data/local/debian` and writes `/data/local/enter-debian.sh` (real chroot
   with `/dev`/`/proc`/`/sys` and `/data/local/osx-kvm` bind-mounted).
2. **Install qemu-system-x86 in chroot** — `apt install qemu-system-x86`
   (Debian's prebuilt glibc binary).
3. **Stage OSX-KVM assets + create HDD** — copies OVMF/OpenCore into
   `/data/local/osx-kvm` and creates a 64G `mac_hdd_ng.img` qcow2.
4. **Fetch macOS 14 (Sonoma) recovery** — runs `fetch-macOS-v2.py --shortname
   sonoma` and converts `BaseSystem.dmg` → `BaseSystem.img` with `dmg2img`.
   Needs network. Apple EULA applies.
5. **Boot macOS 14 (TCG / VNC :5900)** — starts `qemu-system-x86_64` with
   `-accel tcg,thread=multi` (no `-enable-kvm`). Connect a VNC viewer on the
   phone to `127.0.0.1:5900`.

### Display

GUI defaults to **VNC** (`-display vnc=127.0.0.1:0`). Override inside the
chroot with `DISPLAY_QEMU='-nographic'` or `DISPLAY_QEMU='-display sdl'` if
you run an X server (e.g. Termux-X11).

### Disk / RAM notes (Flip 4)

- Default guest RAM is **3072 MiB** (phone has 8 GB — leave headroom for
  Android). Override with `ALLOCATED_RAM=4096`.
- Default HDD is **64G** sparse qcow2 under `/data/local/osx-kvm/mac_hdd_ng.img`.
  Make sure you have free space on `userdata` before fetching + installing.
- BaseSystem recovery alone is ~700 MB–1 GB download.

## Verified vs not

**Verified on the build host:**

- Launcher APK assembles (`assembleDebug`).
- Module zip has `module.prop` at its root, valid Magisk/KernelSU layout
  (`META-INF/com/google/android/{update-binary,updater-script}`, `customize.sh`,
  `service.sh`, `app/`, `payload/`).
- All shell scripts pass `bash -n`.
- Bundled OVMF/OpenCore/fetch script are present inside the zip.
- No Apple macOS images are in the zip or the git tree.

**Not verified (needs the phone):**

- Live Debian download / `apt install qemu-system-x86` on device.
- Fetching Sonoma recovery from Apple's CDN on device.
- Actually booting OpenCore / macOS under TCG on the Flip 4.
- Whether TCG gets far enough to be useful at all.

Treat on-device steps as "should work given root + network + disk", not
"tested here".

## License / attribution

See [`ATTRIBUTION.md`](ATTRIBUTION.md). Upstream OSX-KVM files keep their own
licenses and CREDITS. Do not redistribute Apple macOS images.
