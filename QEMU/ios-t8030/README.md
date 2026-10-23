# iOS VM on Android — HackiOS (iOS 16.5) in QEMU

Runs **iOS 16.5** in a VM on a rooted Android phone (tested target: Galaxy Z Flip 4) with
**HackiOS** by **OOSEX GANG**, inside a Debian chroot. Packaged as a KernelSU/Magisk module that
installs the **iOS VM (HackiOS)** launcher app. This launcher is not made by OOSEX GANG.

- Module zip: **`qemu-t8030-launcher-v2.1.0.zip`** (the file name stays for module upgrades)
- App package: `com.qemut8030.launcher` (label "iOS VM (HackiOS)")
- App source: [`launcher-app/`](launcher-app/) · the script it runs: [`hackios.sh`](hackios.sh)
- The old Inferno t8030 steps were removed in v2.0.0: see [INFERNO.md](INFERNO.md).

## Credit

[**HackiOS**](https://hackios-web.vercel.app) by **OOSEX GANG**
([@oodze](https://t.me/oodze), [@netusd](https://t.me/netusd), [@wannqn](https://t.me/wannqn),
[@hxfuxyyXD](https://t.me/hxfuxyyXD); [github.com/oosexgang](https://github.com/oosexgang),
news: [t.me/oosexgangdevs](https://t.me/oosexgangdevs)) boots Apple's open-source XNU kernel
(`xnu-8796.121.2`, the kernel of iOS 16.5) and runs the unmodified iOS 16.5 user space on it.
Besides their phone port it runs in QEMU's generic `virt` machine, which is what these steps use on
the phone: no Apple-specific machine model, and a virtio network card, so iOS has internet through
QEMU's own network. All credit for HackiOS goes to its authors. HackiOS is not affiliated with,
authorised or endorsed by Apple Inc.

Nothing of HackiOS is copied into this repository: `hackios.sh` clones
[hackios-xnu-kernel](https://github.com/oosexgang/hackios-xnu-kernel) (Apple Public Source License 2.0)
and [hackios-xnu-userland](https://github.com/oosexgang/hackios-xnu-userland) (MIT) at pinned commits
into the Debian chroot (`/root/hackios`) and runs their own scripts. iOS 16.5 (20F66) comes from
Apple's CDN through their `ios165/fetch.sh`, onto your phone only.

## Install

1. KernelSU manager → Modules → install `qemu-t8030-launcher-v2.1.0.zip`, reboot.
2. Open "iOS VM (HackiOS)", grant root.

Needs about 14 GB free storage while building and about 3 GB free RAM while iOS runs.

## Steps

1. **Install & update Debian (chroot)** — Debian arm64 at `/data/local/debian` and
   `/data/local/enter-debian.sh`; re-run any time to update it.
2. **Install HackiOS** — `hackios.sh setup`: packages (QEMU for aarch64, UEFI firmware, gcc, clang/lld),
   7-Zip 24.09 from [ip7z/7zip](https://github.com/ip7z/7zip) (checksum-verified; Debian's 7-Zip is too
   old to read APFS), both HackiOS repositories via their `common/setup.sh`.
3. **Download iOS 16.5 + build images (long)** — `hackios.sh build`: `hackios.sh build`: their `ios165/fetch.sh`
(7.4 GB download, resumes if interrupted; about 14 GB free space needed while it runs), their loader
built from source (`xnuloader/build.sh`, clang + lld), then `common/build.sh qemu-virt` with their
prebuilt kernel and programs → `userland/root.apfs` and `userland/system.apfs` (2.5 GB). The boot job
list asks configd for DHCP on `en0` (`net_test dhcp en0`, as their `rc.jobs.net` does): under QEMU
the virtio card has no IOKit object, so iOS does not configure it by itself. `HACKIOS_NET=0` builds
without it; `HACKIOS_JOBS=<file>` uses one of their `rc.jobs.*` lists instead.
Before building, `hackios.sh` fixes four bugs in the pinned HackiOS commits (reported upstream; each
fix is skipped once their code changes):
1. `userland/build.sh` copies `drawable_test`, which `prebuilt/userland` lacks, so the build stops;
2. `userland/build.sh` calls `timedatectl` under `set -e`, so it stops silently without systemd (a chroot);
3. `userland/mkjobs.py` reuses the loop variable `name`, so all ~400 on-demand iOS jobs (configd,
   mDNSResponder, trustd, nsurlsessiond, …) overwrite one file and none can start: no network;
4. `xnuloader/loader.c` reads the fw_cfg DMA answer through a plain variable, so `-O1` folds the check
   and the loader gives up on the 1125×2436 ramfb: black screen.
4. **Boot iOS 16.5 (VNC, network)** — `hackios.sh run`: their `qemu/run-ios.sh`, display on VNC
   `127.0.0.1:5900` (the built-in viewer opens by itself), `QEMU_NET=1`, 4 vCPUs, a 2-hour session
   (`HACKIOS_SECS`). TCG on the phone: the lock screen takes several minutes, and the screen dims after a
   while (tap to wake). **Power off VM** stops it.
5. **Status** — what is installed, built and running.
6. **Forget the snapshot** — the next boot starts afresh.

### Snapshots: boot in seconds

A cold boot to the home screen takes many minutes. Once iOS is on the home screen, tap **Save iOS
snapshot** (it works while the Boot step is running): `hackios.sh save` pauses iOS, writes QEMU's whole
VM state to `/root/hackios/qemu/hackios.snapshot` (about 4 GB, under a minute) and lets iOS carry on.
From then on step 4 resumes that state instead of booting: in a test on a PC, iOS was back on the home
screen, touch and network working, 14 s after starting, against about 420 s for a cold boot.

- The snapshot is only used while it still fits: same images, QEMU, vCPUs, RAM and boot settings. After a
  rebuild (step 3) it is ignored until you save again; **Forget the snapshot** deletes it.
- iOS's clock is behind after a resume by the time the VM was off.
- Needs QEMU 8.2 or newer (older ones cannot save the display). Step 2 installs QEMU 10 from
  bookworm-backports when the chroot is Debian bookworm (bookworm itself has 7.2).
- To make snapshots possible, QEMU runs with HackiOS's EFI disk read-only and without the virtio sound
  device (QEMU cannot save a VM with either; iOS has no sound output under QEMU anyway).

The **iOS VM Logs** icon opens the full step log on its own screen (Copy / Clear).

## The VNC viewer

- iOS is drawn fit-to-screen below a row of buttons, with Android's status and navigation bars hidden
  (swipe from an edge to see them). Pinch to zoom, two-finger drag to pan, **Fit** resets.
- Touch: a finger on the picture is a finger on the iPhone. Swipe up from the bottom edge to unlock /
  go home, from the left edge for back.
- Buttons: **Home**, **Lock**, **Swipe up**, **Vol +**, **Vol −** — HackiOS's virtio keyboard is the
  phone's buttons, not a keyboard, so text is typed on iOS's own on-screen keyboard.
- **Back** closes the viewer only; iOS keeps running.

## What to expect

- Slow: QEMU has no KVM here, so every instruction is translated (TCG). Snapshots (above) make starting
  fast, but not using it. A newer QEMU is not faster: QEMU 8.2 and 10.0 both took 421–423 s to the home
  screen in the same test. KVM is not available on Snapdragon Galaxy phones.
- Plain white home and lock screens, empty widgets: QEMU has no GPU for iOS, so CoreAnimation draws
  without wallpaper, blur or widget contents. Apps (Safari, Settings, Notes …) draw normally.
- Network: Safari and apps reach the internet through QEMU's user network (iOS gets 10.0.2.15).

## Scripts

- `hackios.sh` — `setup` | `build` | `run` | `save` | `forget` | `stop` | `status` (env: `HACKIOS_DIR`, `HACKIOS_REF=latest`,
  `HACKIOS_SECS`, `HACKIOS_SMP`, `HACKIOS_RAM_GB`, `HACKIOS_NET=0`, `HACKIOS_JOBS`, `HACKIOS_SNAPSHOT=0`).
- `setup-debian-chroot.sh` — the Debian chroot (step 1); `xz-arm64` (+ `LICENSE-xz`) unpacks it.
- `pack-release.sh` — builds the module zip from the APK and these scripts.
