# MacOS-KVM — macOS 26 (Tahoe) QEMU VM on a rooted Android phone

KernelSU/Magisk flashable **module** that installs a tappable **"macOS KVM"**
launcher app and stages an [OSX-KVM](https://github.com/kholia/OSX-KVM)-based
macOS QEMU stack on the phone. macOS 26 (Tahoe), the last macOS release for
Intel Macs, is the default; macOS 14 (Sonoma) is still available.

Built for a rooted Samsung Galaxy Z Flip 4 (SM-F721B / `b4q`, Snapdragon 8+
Gen 1 / SM8475, aarch64) with kernel root — but any aarch64 rooted Android with
a working Debian chroot path should be able to run the same scripts.

- Module zip: **`macos-kvm-launcher-v1.1.2.zip`**
- App package: `com.macoskvm.launcher` (label **"macOS KVM"**)
- App source: [`launcher-app/`](launcher-app/)

## v1.1.2: recovery check works without a terminal

- Fixed step 4 ending with `Image verification failed. ([Errno 25]
  Inappropriate ioctl for device)` after a complete download. OSX-KVM's
  `fetch-macOS-v2.py` sizes its chunk progress line with
  `os.get_terminal_size()` in `verify_image()`, which raises ENOTTY when there
  is no terminal (the app's log pane). The module's copy now uses
  `shutil.get_terminal_size()`, which falls back to 80 columns, the same as
  acidanthera's macrecovery.py (`patches/fetch-macOS-v2-no-tty.patch`). The
  chunklist signature and per-chunk SHA-256 checks are unchanged.
- An earlier complete download in `/data/local/osx-kvm/.dl-<version>/` is
  verified and converted instead of downloaded again. It is downloaded again
  only if that check fails.
- Step 4 picks up the fixed `fetch-macOS-v2.py` from the flashed module by
  itself; step 3 does not need to be run again.

## v1.1.1: QEMU from bookworm-backports

- Fixed step 2 failing with `qemu-system-x86 : Depends: qemu-system-common
  (= 1:7.2+dfsg-7+deb12u18+b3) but 1:10.0.2+ds-2+deb13u1~bpo12+1 is to be
  installed` when the iOS VM module (qemu-t8030) had already installed QEMU 10
  from bookworm-backports into the same Debian chroot. All `qemu-system-*`
  packages must have the same version.
- Step 2 now adds the `bookworm-backports` source if it is missing (the same
  line the iOS VM module writes) and installs `qemu-system-x86` and
  `qemu-utils` with `-t bookworm-backports` (QEMU 10.0.2). QEMU packages that
  are already installed, such as `qemu-system-arm`, are listed too so they stay
  on the same version. apt runs with `--no-remove`: nothing is removed or
  downgraded. dmg2img, python3 and the other helpers still come from bookworm.
- If backports cannot be reached, a fresh chroot falls back to bookworm's
  QEMU 7.2. If QEMU from backports is already installed, the step stops with
  an error instead of mixing versions.

## v1.1.0: macOS 26 (Tahoe)

- **Tahoe is the default.** Step 4 fetches the macOS 26 recovery and step 5
  boots it. Sonoma has its own **Optional: Fetch / Boot macOS 14 (Sonoma)**
  steps. Each release keeps its own image (`BaseSystem-tahoe.img`,
  `BaseSystem-sonoma.img`), so switching does not re-download.
  From a shell: `MACOS_VERSION=tahoe|sequoia|sonoma` for `fetch-macos.sh`
  and `boot-macos.sh`.
- **Recovery download fixed.** v1.0.x ran `fetch-macOS-v2.py --action download
  --shortname sonoma`, but the script ignores `--shortname` when `--action` is
  given, so it fetched the recovery Apple serves for the script's default
  board. Asking Apple's recovery server for that board returns the same product
  (`696-28424`) as OSX-KVM's Sequoia entry, not Sonoma's (`696-08090`). The
  scripts now pass the board ID, MLB and os type from OSX-KVM's table
  (Tahoe: `Mac-CFF7D910A743CAAF`, `-os latest`, product `140-93589` when
  checked on 2026-11-10). The old `BaseSystem.img` is no longer used; the fetch
  step tells you its size so you can delete it.
- **CPU model.** Tahoe (and Sequoia) boot with `Skylake-Client,-hle,-rtm`, the
  line upstream OSX-KVM's `OpenCore-Boot.sh` enables for Sequoia and Tahoe.
  Sonoma keeps `Haswell-noTSX`. Override with `CPU_MODEL=...`.
- **OpenCore / OVMF.** Unchanged from v1.0.4: they were already the files from
  OSX-KVM commit `4c378a4` ("Support for macOS Tahoe"); the OpenCore picker
  shows `REL-106 2025-11-03`.
- The scripts were renamed: `fetch-sonoma.sh` → `fetch-macos.sh`,
  `boot-macos14.sh` → `boot-macos.sh`, plus `macos-versions.sh` (release
  table). **Re-run step 3** after flashing so the new files are staged.
- On an x86_64 Linux host with a working `/dev/kvm`, `boot-macos.sh` uses KVM
  (`ACCEL=tcg|kvm` overrides). On the phone it is always TCG.
- `pack-release.sh` builds the module zip and refuses to package an APK whose
  bundled scripts differ from the ones in this folder; Gradle copies them into
  the app on every build.

## Built-in VNC viewer (v1.0.4)

The launcher app has its own VNC viewer, so no separate VNC app is needed.

- **Open VNC viewer (127.0.0.1:5900)** button at the top of the step list. It
  stays enabled while a step is running, so you can open it while the VM is up.
- The **Boot** step opens the viewer automatically as soon as
  `127.0.0.1:5900` accepts connections (it watches for about 60 s).
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
- A full macOS install under TCG on a phone is **unlikely to be practical**
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
| Apple BaseSystem / IPSW | **not shipped** | Downloaded on-device by step 4 (or the optional Sonoma step) |

## Install

1. Open **KernelSU manager → Modules → Install from storage**, pick
   `macos-kvm-launcher-v1.1.2.zip`, reboot.
2. **"macOS KVM"** appears in the app drawer. Open it and **grant root**.

(Manual alternative: `adb install launcher-app/dist/macos-kvm-launcher.apk`.)

On flash, `customize.sh` also stages everything under
`/data/local/osx-kvm/` and `/data/local/tmp/macos-kvm/`.

## Use (buttons in the app, top to bottom)

1. **Install & update Debian** — downloads a Debian arm64 rootfs to
   `/data/local/debian` and writes `/data/local/enter-debian.sh` (real chroot
   with `/dev`/`/proc`/`/sys` and `/data/local/osx-kvm` bind-mounted).
2. **Install qemu-system-x86 in chroot** — `apt install -t bookworm-backports
   qemu-system-x86 qemu-utils` (Debian's prebuilt QEMU 10.0; bookworm's 7.2 if
   backports is unreachable on a fresh chroot) plus dmg2img and helpers.
3. **Stage OSX-KVM assets + create HDD** — copies OVMF/OpenCore into
   `/data/local/osx-kvm` and creates a 64G `mac_hdd_ng.img` qcow2.
4. **Fetch macOS 26 (Tahoe) recovery** — runs `fetch-macOS-v2.py --action
   download --board-id Mac-CFF7D910A743CAAF --os-type latest` (Apple checks
   the image against its chunklist) and converts `BaseSystem.dmg` →
   `BaseSystem-tahoe.img` with `dmg2img`. Needs network. Apple EULA applies.
5. **Boot macOS 26 (Tahoe) (TCG / VNC :5900)** — starts `qemu-system-x86_64`
   with `-accel tcg,thread=multi` and `-cpu Skylake-Client,-hle,-rtm,...`. The built-in viewer opens on
   its own once `127.0.0.1:5900` is up (or tap **Open VNC viewer**).

**Optional: Fetch / Boot macOS 14 (Sonoma)** do the same for Sonoma
(board `Mac-827FAC58A8FDFA22`, CPU `Haswell-noTSX`).

### Display

GUI defaults to **VNC** (`-display vnc=127.0.0.1:0`). Override inside the
chroot with `DISPLAY_QEMU='-nographic'` or `DISPLAY_QEMU='-display sdl'` if
you run an X server (e.g. Termux-X11).

### Disk / RAM notes (Flip 4)

- Default guest RAM is **3072 MiB** (phone has 8 GB — leave headroom for
  Android). Override with `ALLOCATED_RAM=4096`.
- Default HDD is **64G** sparse qcow2 under `/data/local/osx-kvm/mac_hdd_ng.img`.
  Make sure you have free space on `userdata` before fetching + installing.
- A recovery image is roughly 1 GB or more to download, plus the converted
  `.img` (not measured for Tahoe; see below).

## Verified vs not

**v1.1.0, checked on the build host (x86_64 Debian, 2026-11-10):**

- Upstream facts: OSX-KVM `fetch-macOS-v2.py` (commit `4c378a4`) lists Tahoe
  as board `Mac-CFF7D910A743CAAF`, os `latest`; acidanthera's
  `recovery_urls.txt` uses the same. Upstream `OpenCore-Boot.sh` uses
  `Skylake-Client,-hle,-rtm` for Sequoia and Tahoe.
- Apple's recovery server answers that board/os query with product
  `140-93589`.
- The bundled OVMF/OpenCore/fetch script are byte-identical to OSX-KVM
  `4c378a4`.
- `boot-macos.sh` under TCG (QEMU 10.0.13) with the Tahoe CPU model and the
  Sonoma CPU model reaches the OpenCore picker (OpenCore `REL-106`). This was
  with a blank placeholder recovery image, so only the EFI entry shows.
- `fetch-macos.sh` passes the right board/MLB/os type for tahoe, sequoia and
  sonoma (checked with a stub downloader), keeps existing images, rejects
  unknown versions.
- APK builds, is signed with the same key as v1.0.4, and carries the same
  scripts as this folder; module zip layout as before.

**Not verified:**

- Downloading and converting the real Tahoe `BaseSystem.dmg`: the build
  host's network blocks plain HTTP, the image URLs Apple returns are plain
  HTTP, and the same paths over HTTPS fail (certificate mismatch / 404). So
  the image's exact 26.x version and size were not seen.
- Booting the Tahoe recovery to the installer, on any host.
- Anything on the phone (Debian chroot, qemu install, fetch, boot under TCG).
- QEMU 7.2 (Debian bookworm, used in the phone's chroot) was not run; its
  changelog lists TCG support for AVX/AVX2, which Skylake-Client needs.
- Whether TCG on the phone gets far enough to be useful at all.

## License / attribution

See [`ATTRIBUTION.md`](ATTRIBUTION.md). Upstream OSX-KVM files keep their own
licenses and CREDITS. Do not redistribute Apple macOS images.
