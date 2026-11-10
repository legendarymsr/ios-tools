# iOS VM on Android — HackiOS (iOS 16.5) in QEMU

Runs **iOS 16.5** in a VM on a rooted Android phone (tested target: Galaxy Z Flip 4) with
**HackiOS** by **OOSEX GANG**, inside a Debian chroot. Packaged as a KernelSU/Magisk module that
installs the **iOS VM (HackiOS)** launcher app. This launcher is not made by OOSEX GANG.

- Module zip: **`qemu-t8030-launcher-v2.10.2.zip`** (the file name stays for module upgrades)
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
[hakios-xnu-kernel](https://github.com/oosexgang/hakios-xnu-kernel) (kernel Apple Public Source License 2.0,
user space MIT; the user space was folded into this one repository upstream on 2026-10-25) at a pinned commit
into the Debian chroot (`/root/hackios`) and runs their own scripts. Pinned: `63fc2b4` (2026-11-06, HakiOS
2.3.4 plus PRs #53/#54). Upstream no longer downloads iOS itself (their `sysimage/unpack.sh` takes an IPSW you
have), so `hackios.sh` downloads the iOS 16.5 (20F66) IPSW from Apple's CDN onto your phone only, checks its
SHA-256 and hands it to `sysimage/unpack.sh`. `HACKIOS_IPSW=<path>` uses an IPSW you already have instead.

HakiOS 2.3.4's own changes (Metal, touch, the phone ports) are for the POCO X5 Pro. The QEMU path here uses their
**prebuilt kernel**, which is still the 2026-10-25 build (`prebuilt/hakios-kernel`, the same binary as the old
`prebuilt/mach.development.bcm2837`); what changes under QEMU is their loader (built here), their image build
(`userland/build.sh`, `mkhighrate.py`) and their scripts (`qemu/run-darwin.sh`, `sysimage/unpack.sh`).

## Install

1. KernelSU manager → Modules → install `qemu-t8030-launcher-v2.10.2.zip`, reboot.
2. Open "iOS VM (HackiOS)", grant root.

Needs about 18 GB free storage for a first build (the 6.2 GB IPSW is deleted after unpacking) and about 3 GB free RAM while iOS runs.

## Steps

1. **Install & update Debian (chroot)** — Debian arm64 at `/data/local/debian` and
   `/data/local/enter-debian.sh`; re-run any time to update it.
2. **Install HackiOS** — `hackios.sh setup`: packages (QEMU for aarch64, UEFI firmware, gcc, clang/lld),
   7-Zip 24.09 from [ip7z/7zip](https://github.com/ip7z/7zip) (checksum-verified; Debian's 7-Zip is too
   old to read APFS), the HakiOS repository at its pinned commit (an old two-repository checkout is cleaned up).
3. **Download iOS 16.5 + build images (long)** — `hackios.sh build`: the iOS 16.5 IPSW from Apple's CDN
(6.2 GB, resumes if interrupted, SHA-256 checked; `HACKIOS_KEEP_IPSW=1` keeps it), unpacked by their
`sysimage/unpack.sh` (about 18 GB free space at the peak). Upgrading from an older pin does not download it
again: their `select-system.py` changed only in its comments, so the files already unpacked are kept. Then their
loader built from source (`xnuloader/build.sh`, clang + lld), then
`PREBUILT=1 REST=1 userland/build.sh` with their prebuilt kernel and programs (our `timesync` and `rootful`
go in through their `EXTRA`) → `userland/root.apfs` and `userland/system.apfs` (2.5 GB). The boot job
list asks configd for DHCP on `en0` (`net_test dhcp en0`, as their `rc.jobs.net` does): under QEMU
the virtio card has no IOKit object, so iOS does not configure it by itself. `HACKIOS_NET=0` builds
without it; `HACKIOS_JOBS=<file>` uses one of their `rc.jobs.*` lists instead.
The bugs `hackios.sh` used to fix in their checkout (`drawable_test`, `timedatectl` without systemd, the
`mkjobs.py` job names, the ramfb DMA read-back in `xnuloader/loader.c`) are all fixed upstream now. Before
building it only makes its own changes: snapshot switches, the time zone, the host clock and ssh forward for the
user network, and a 944×2048 ramfb panel (QEMU's VNC drops rows below 2048).
4. **Boot iOS 16.5 (VNC, network)** — `hackios.sh run`: their `qemu/run-darwin.sh`, display on VNC
   `127.0.0.1:5900` (the built-in viewer opens by itself), `QEMU_NET=1`, 4 vCPUs, a 2-hour session
   (`HACKIOS_SECS`). TCG on the phone: the lock screen takes several minutes, and the screen dims after a
   while (tap to wake). **Power off VM** stops it.
5. **Status** — what is installed, built and running.
6. **Forget the snapshot** — the next boot starts afresh.

### Jailbreak and Sileo (no Apple account)

Step 3 builds iOS jailbroken the way HackiOS does it: their `tools/mk-jb.sh` fetches the
[Procursus](https://github.com/ProcursusTeam/Procursus) rootless bootstrap (apt, dpkg, a shell and the
usual tools under `/var/jb`), [Sileo](https://github.com/Sileo/Sileo) (the package manager app) and
[ElleKit](https://github.com/evelyneee/ellekit) (the tweak loader), and their build puts them into the
system image. Every boot runs their `prep.sh` and refreshes the package lists.

- **Sileo** is on the second home-screen page. It installs from apt repositories (Procursus is set up;
  add others under Sources) and needs no Apple account and no sign-in of any kind. It is not Apple's
  App Store: it installs command-line tools, tweaks and the apps that repositories package, not App Store
  apps. Apple's own App Store icon stays, and it would want an Apple ID; you can ignore it.
- Packages come over HTTPS from the repositories you add; Procursus is the only one at the start.
- OpenSSH is installed (HackiOS preinstalls it) but nothing starts it, and there is no key or password
  that lets anyone in.
- **What you install lives in memory** (`/private/var` is a memory filesystem in HackiOS): a cold boot
  starts from the clean image again. Install what you want, then **Save iOS snapshot**: resuming the
  snapshot brings it all back.
- `HACKIOS_JB=0` builds without the jailbreak.

### NewTerm: a terminal on the home screen

Step 3 also bundles **[NewTerm](https://github.com/hbang/NewTerm) 3** (HASHBANG Productions, Apache-2.0),
a native iOS terminal, into the jailbreak prefix the same way Sileo is — it is on the second home-screen
page and opens a real `zsh` shell with the usual command-line tools (the Procursus bootstrap already
provides the shell, coreutils, ncurses and `system-cmds` it needs). The rootless (`/var/jb`) build is
fetched from [Chariz](https://chariz.com/get/newterm-beta) at build time (the repo Sileo itself would use),
so nothing third-party is committed here. This sidesteps installing it through Sileo on-device, which the
Procursus `firmware` pseudo-package otherwise trips up.

- `HACKIOS_NEWTERM=0` leaves NewTerm out (it needs the jailbreak, so it also goes with `HACKIOS_JB=0`).
- `NEWTERM_DEB=<path>` bundles a local NewTerm `.deb` instead of fetching it (use the `iphoneos-arm64`,
  i.e. rootless, build — it must install into `/var/jb`).

### TrollStore (and a Hello World app)

Step 3 also stages **[TrollStore](https://github.com/opa334/TrollStore)** (opa334, MIT) the way it is
installed on a jailbroken iOS 16 device: through **TrollHelper** (`com.opa334.trollstorehelper`, the rootless
`iphoneos-arm64` deb). Both TrollHelper's deb and `TrollStore.tar` are downloaded from TrollStore's own GitHub
releases at build time (latest, or `TROLLSTORE_VERSION=<tag>`); ios-tools does not ship them. At boot a
background job (`/var/jb/usr/libexec/ios-tools/trollstore-boot.sh`, log in `/var/tmp/ios-tools-trollstore.log`)
waits for iOS to come up and runs TrollHelper's root helper `trollstorehelper install-trollstore TrollStore.tar`
(or `refresh-all` if TrollStore is already there), then has it install any apps staged with `HACKIOS_TIPAS` (none by default -- nothing is preinstalled).
The ios-tools **Hello World** app ([`apps/hello-world`](../../apps/hello-world)) is **not** preinstalled: download
`HelloWorld.tipa` from the [`hello-world-v1.3` release](https://github.com/legendarymsr/ios-tools/releases/tag/hello-world-v1.3)
and install it yourself with TrollStore (open the .tipa with TrollStore, or `trollstorehelper install HelloWorld.tipa` as root).
"TrollStore Helper" is also on the home screen to (re)install TrollStore by hand.

- `HACKIOS_TROLLSTORE=0` leaves TrollStore out (it needs the jailbreak, so it also goes with `HACKIOS_JB=0`).
- `HACKIOS_TIPAS="<path-or-url> ..."` optionally installs `.tipa`/`.ipa` files at boot (default: none).
- `TROLLSTORE_TAR=<path>` / `TROLLHELPER_DEB=<path>` use local files instead of downloading.
- The boot job is part of ios-tools' job list, so it does not run with `HACKIOS_NET=0` or a custom `HACKIOS_JOBS`.

### An ephemeral "rootful" overlay (on by default)

HackiOS is **rootless** because its root filesystem is a read-only APFS RAM disk — the kernel's APFS is a
reader, so `/` genuinely cannot be written (the only writable filesystem is the memory one on `/private/var`,
which is where the `/var/jb` prefix lives). A true rootful jailbreak — one that rewrites the system files on
disk — is therefore impossible here.

What *is* possible is an **ephemeral overlay**, and it is now **on by default**: a small helper
(`rootful/rootful.c`) mounts a writable memory filesystem (`ramfs`) as a **union** over the system directories
at boot, so a file *created* in `/Applications`, `/Library`, `/usr`, `/bin` or `/sbin` lands in memory while
reads of what is already there fall through to the read-only root. It runs from the boot job list; the boot
log prints `rootful: writable overlay on <dir> (verified: created a file)` for each one.

Caveats, by design:
- **Ephemeral** — the overlay is memory, emptied on a cold boot (a snapshot keeps it), exactly like `/var/jb`.
- **Add-only** — it cannot modify the existing read-only system files, only put new ones beside them (the
  kernel can't rewrite APFS). You get uid 0 either way; this just lets you write to the system paths too.

The full set `/Applications /Library /usr /bin /sbin` was verified to boot cleanly (home screen, Settings and
NewTerm all launch with it active). `HACKIOS_ROOTFUL_DIRS="/A /B"` overrides which directories it covers, and
`HACKIOS_ROOTFUL=0` turns it off. To change either without editing the launcher, put the setting in
**`/root/.hackios-env`** in the chroot (that file is sourced by `hackios.sh`), then re-run step 3.

### Snapshots: boot in seconds

A cold boot to the home screen takes many minutes. Once iOS is on the home screen, tap **Save iOS
snapshot** (it works while the Boot step is running): `hackios.sh save` pauses iOS, writes QEMU's whole
VM state to `/root/hackios/qemu/hackios.snapshot` (about 4 GB, under a minute) and lets iOS carry on.
From then on step 4 resumes that state instead of booting: in a test on a PC, iOS was back on the home
screen, touch and network working, 14 s after starting, against about 420 s for a cold boot.

- The snapshot is only used while it still fits: same images, QEMU, vCPUs, RAM and boot settings. After a
  rebuild (step 3) it is ignored until you save again; **Forget the snapshot** deletes it.
- iOS's clock: `timesync` (ours, [`timesync/timesync.c`](timesync/timesync.c), started from the boot job
  list) sets it from the phone's clock every 30 s, so after a resume it is right again within about half a
  minute (QEMU's user network answers 10.0.2.100:37 with the host's `date`; SNTP servers as a fallback).
  Step 3 gives iOS Android's time zone.
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

### Why the screen is 944×2048, not 1125×2436

iOS renders at the iPhone's native 1125×2436, but QEMU's VNC server (which the viewer reads) drops every
row past about 2048, so the dock used to be cut off. The loader now presents QEMU a 944×2048 panel at
iOS's aspect ratio; iOS still renders 1125×2436 and the kernel scales it onto the panel, the same way it
scales onto the real phone's 1080×2400. So the UI layout is unchanged and the whole screen — status bar
to dock — fits the viewer.

### Wallpaper: black, not white

iOS 16.5's stock wallpaper (and any photo set as one) is GPU-composited and renders as a blank **white**
screen without a GPU. Step 3 instead sets the default to iOS's procedural **"Stripe Black"** wallpaper,
which the software renderer draws — a black background with a thin diagonal stripe. `HACKIOS_WALLPAPER=0`
keeps iOS's stock default. A photo cannot be used: every wallpaper type this iOS ships (Bokeh, the
stripes, the layered animation) is procedural, and a raster image needs the GPU.

### Speed

Nothing makes this fast — a Snapdragon Galaxy can't give QEMU hardware virtualization (KVM), so every CPU
instruction is translated in software (TCG). What helps:

- **Snapshots** (above) make *starting* instant after the first boot.
- **Render resolution** (`HACKIOS_FBSCALE=2`) draws the UI at 2× (750×1624) instead of native 3× and
  upscales it — fewer pixels for the CPU per frame. A controlled A/B test (same animation, only the scale
  changed) showed **no frame-rate difference** — both ~10 fps, because the limit is the final scaling onto
  the panel, not the UI rendering. So the default is native 3×; `HACKIOS_FBSCALE=2` is there if you want
  lower CPU load (and a slightly softer image), but don't expect it to feel faster.
- A newer QEMU is **not** faster: QEMU 8.2 and 10.0 both took 421–423 s to the home screen in the same test.
- The honest summary: snapshots fix *startup*; nothing available here makes *running* it much faster.

## What to expect

- Slow: QEMU has no KVM here, so every instruction is translated (TCG). Snapshots make *starting* fast;
  *running* it stays unhurried (about 10 fps) and nothing available here changes that much.
- The home/lock background is black (the stock white wallpaper needs a GPU; see above). Widgets, blur and
  photo wallpapers still need the GPU and are blank. Apps (Safari, Settings, Notes …) draw normally.
- Network: Safari and apps reach the internet through QEMU's user network (iOS gets 10.0.2.15).
- **Sileo** and **NewTerm** (a terminal with a real `zsh` shell) are on the second home-screen page.

## Scripts

- `hackios.sh` — `setup` | `build` | `run` | `save` | `forget` | `stop` | `status` (env: `HACKIOS_DIR`, `HACKIOS_REF=latest`,
  `HACKIOS_SECS`, `HACKIOS_SMP`, `HACKIOS_RAM_GB`, `HACKIOS_NET=0`, `HACKIOS_JOBS`, `HACKIOS_SNAPSHOT=0`, `HACKIOS_TZ`, `HACKIOS_JB=0`, `HACKIOS_NEWTERM=0`, `NEWTERM_DEB`, `HACKIOS_TROLLSTORE=0`, `TROLLSTORE_VERSION`, `HACKIOS_TIPAS`, `HACKIOS_ROOTFUL=0`, `HACKIOS_ROOTFUL_DIRS`, `HACKIOS_SSH_KEY`, `HACKIOS_IPSW`, `HACKIOS_KEEP_IPSW=1`).
- `timesync/` — `timesync.c` and its build for iOS (`timesync-arm64`, built with the theos toolchain and the
  iOS 16.5 SDK, ad-hoc signed with `ldid`); `hackios.sh build` puts it into the image.
- `setup-debian-chroot.sh` — the Debian chroot (step 1); `xz-arm64` (+ `LICENSE-xz`) unpacks it.
- `pack-release.sh` — builds the module zip from the APK and these scripts.

## v2.10.2: upgrading a phone from v2.9.x

The launcher app runs the `hackios.sh` in its own assets (copied into the chroot at every step), and in
v2.10.0 and v2.10.1 that copy was still v2.9.4's: the app kept the old pin (`8851317`) and layout check, so
step 3 said "not set up yet (or the old layout)" and step 2 stopped at `git checkout` over the files
v2.9.4 had edited in the HakiOS checkout (`qemu/run-ios.sh`, `xnuloader/loader.c`, ...). The fixes of v2.10.0
and v2.10.1 reach the phone with this release. Now:
- the APK's assets are synced from the module's files before every build (`syncPayload` in
  `launcher-app/app/build.gradle.kts`), and `pack-release.sh` refuses an APK that carries another `hackios.sh`;
- step 2 brings any older HakiOS checkout to the pin: origin set to upstream and fetching `main` only
  (old clones track the deleted `hakios` branch), the pinned commit fetched when missing (shallow clones),
  ios-tools' own edits to tracked files dropped (`reset --hard`, `checkout -f --detach`; made again at
  step 3), nothing untracked or ignored deleted -- the unpacked iOS files, `jb/` and the images stay;
  a snapshot of the old images is deleted;
- step 3 does that update itself when the checkout is not the pinned one, so step 2 is not needed first;
  step 4 on an old checkout says to run step 3.

## v2.10.1: Sileo and apt install packages again

In v2.10.0 Sileo queued nothing: "Depends firmware", "Depends org.swift.libswift" (the other half of Sileo's
`firmware (>= 12.2) | org.swift.libswift` dependency), "Depends libkrw0-plugin". Under the Debian chroot's
Python 3.11.2 upstream's `tools/jb-preinstall.py` stopped at `tarfile`'s `filter=` (Python 3.12), so
`tools/mk-jb.sh` stopped half way: shshd, libkrw0 and libdimentio0 were still in dpkg's database, no
`/var/jb/prep.sh` was written, and so `/var/jb/usr/libexec/firmware` never ran and the `firmware` package --
which is in no repository, apt has "no installation candidate" for it -- never existed. A second `build` kept
that half-made prefix. Now:
- `jb-preinstall.py` is patched to pass `filter=` only where Python has it;
- a prefix without `prep.sh` (an unfinished `mk-jb.sh`) is made again, and with it the system image;
- `jb_dpkg_tidy` makes dpkg's database consistent at build time: `firmware` 16.5 and the `cy+` packages
  (os.iphoneos 16.5, model.iphone 10.3, kernel.darwin 22.5.0, cpu.arm64, lib.corefoundation) are recorded
  locally as Procursus's `firmware` program writes them (it rewrites them at every boot), shshd/libkrw0/
  libdimentio0 are taken out, and the packages put in by hand (Sileo, ElleKit, OpenSSH, NewTerm, TrollHelper, ...)
  get their file lists, md5sums and full control records from their .debs; the boot job
  `/var/jb/usr/libexec/ios-tools/dpkg-tidy.sh` gives `firmware`/`cy+*`/`gsc.*` their empty file lists, so
  `dpkg --audit` is clean.

The `mobile` user's password (for `sudo` in NewTerm) is `alpine`; root logs in over ssh with your key only.
An existing install picks the fix up at the next step 3 (build).

## v2.10.0: HakiOS 2.3.4

Pinned to hakios-xnu-kernel `63fc2b4` (2026-11-06: 2.3.4 plus the merged PRs #53 and #54). What changed for the
QEMU path upstream: `sysimage/fetch.sh` became `sysimage/unpack.sh`, which takes your own IPSW and downloads
nothing (so `hackios.sh` downloads the IPSW from Apple's CDN itself, or uses `HACKIOS_IPSW`);
`qemu/run-ios.sh` became `qemu/run-darwin.sh` and the prebuilt kernel is `prebuilt/hakios-kernel`;
`xnuloader/mkidentity.sh` builds lzfse correctly itself, so ios-tools no longer builds it; `userland/build.sh`
adds `mkhighrate.py`; `hakios-metal/` is in the tree now, but `PREBUILT=1` does not build it. The repository
checkout is forced (`git checkout -f`) so the files `hackios.sh` edits do not block an update.
`tools/mkdatavol.py` (the HFS+ data volume) makes a fastboot image for the phone's `darwin` partition and is not
used under QEMU.

## v2.9.0: current upstream HakiOS

Pinned to hakios-xnu-kernel `8851317` (2026-10-26): `ios165/` → `sysimage/`, `common/build.sh` →
`PREBUILT=1 REST=1 userland/build.sh`, boot job `com.hakios.demo`, `-device ramfb` display (required:
SpringBoard does not start without it), `make` + `lz4` added to the packages. Upstream's own
`qemu/run.sh` default is one vCPU (`QEMU_SMP=1`) with `tb-size=384`; `HACKIOS_SMP=1` matches it.
TrollStore stays on by default (`HACKIOS_TROLLSTORE=1`); since v2.9.4 Hello World is no longer preinstalled -- install it with TrollStore.

## v2.9.1: verified on an x86_64 box

Reached the home screen with TrollStore and Hello World and opened Hello World, in a Debian bookworm
chroot with QEMU 10.0.2 from bookworm-backports and qemu-efi-aarch64 2022.11 (what this module installs),
`HACKIOS_SMP=6 HACKIOS_SNAPSHOT=0`. The same image under Debian trixie's QEMU 10.0.13 + edk2 2025.02 wedged
the guest at the Apple logo (vCPUs spinning, no log output), with 1, 4 or 6 vCPUs.
TrollStore needs ldid to install fakesigned apps (error 173): it is now staged and put into TrollStore.app at boot.
Hello World no longer asks for get-task-allow (TrollStore would arm Developer Mode: error 183).
`HACKIOS_SSH_KEY=<public key>` at build starts sshd in iOS; `run` forwards 127.0.0.1:${HACKIOS_SSH_PORT:-2222}.
