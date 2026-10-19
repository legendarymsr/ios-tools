# ios-t8030 — emulated iPhone 11 (iOS) on Android via Inferno

Boot an emulated **iPhone 11 (t8030, Apple A13)** running **iOS 14.x** under
**Inferno** (ChefKiss; formerly *QEMUAppleSilicon*, originally the
*qemu-t8030* fork by TrungNguyen1909). Packaged as a KernelSU/Magisk module that
installs the **iOS Emu (t8030)** launcher app.

- Module zip: **`qemu-t8030-launcher-v1.1.2.zip`**
- App package: `com.qemut8030.launcher` (label "iOS Emu (t8030)")
- App source: [`launcher-app/`](launcher-app/)
- Upstream: https://github.com/ChefKissInc/Inferno · guide: https://chefkiss.dev/applehax/inferno/

## Reality check (important)

- The guest CPU is an **Apple A13**, so there is **no KVM** — it's pure **TCG
  emulation**: very slow (multi-minute boots), **no GPU** acceleration, software
  rendering only. This is bring-up/research quality, not a daily driver.
  Inferno `@ cc4302a` hardcodes `TYPE_APPLE_A13` and `minimum_page_bits=14`
  (16 KiB pages); `-accel kvm` / `-cpu host` are not usable for this machine.
  `run-t8030.sh` probes `/dev/kvm` for logging but always launches with
  `-accel tcg`.
- **v1.1.2 chroot fix:** the "can't create .../etc/resolv.conf" failure came
  from the Debian image's `etc/resolv.conf`, which is an absolute symlink into
  `/run/systemd/...`. Writing through it from Android followed it onto the
  phone's own `/run`. It is now replaced with a real file. The rootfs is also
  extracted into a staging dir and moved into place only after verification,
  with xz/tar exit codes logged and full cleanup on failure. `setup-build-deps.sh`
  now installs Debian's `libjpeg62-turbo-dev` (the Ubuntu-only package name
  used before made the whole `apt-get install` fail without saying so) and stops
  if apt fails.
- **v1.1.1 chroot fix:** Debian rootfs now comes from linuxcontainers.org
  (multi-MB `rootfs.tar.xz`); a static `xz-arm64` is bundled because Android
  toybox `tar` cannot decompress xz. Failed/partial downloads are removed so
  re-running works.
- **IPSW auto-download.** On first "Download & Configure" the app pulls the
  Inferno reference IPSW **directly from Apple's CDN** onto your phone
  (~5.5 GB). Nothing from Apple is shipped in this repo or the module zip.
  Apple's license covers downloading firmware yourself from Apple; it does
  **not** cover redistributing IPSWs. Do not re-upload the file.
- Reference target: **iOS 14.0 beta 5 for iPhone12,1** (build `18A5351d`).
  Inferno supports iOS 14.x on t8030 today.
- Inferno is built **on-device inside a Debian (glibc) chroot**. On an 8 GB-class
  phone the build is heavy; a strong phone with lots of RAM/storage is strongly
  recommended. Plan on **≥10 GB free** before Download & Configure
  (IPSW + extract + sparse root disk).

## Install

1. KernelSU manager → Modules → install `qemu-t8030-launcher-v1.1.2.zip`, reboot.
2. Open "iOS Emu (t8030)", grant root.

## Use (buttons, top to bottom)

1. **Set up Debian chroot** — Debian arm64 rootfs at `/data/local/debian` +
   `/data/local/enter-debian.sh`.
2. **Install build deps** — git, meson/ninja, glib, pixman, gnutls, nettle
   (built from source if Debian's is < 3.10), lzfse, SDL/GTK, etc.
3. **Build Inferno** — clones `ChefKissInc/Inferno` (pinned commit), configures
   with `--target-list=aarch64-softmmu,x86_64-softmmu` and `ninja`. **Long build.**
4. **Download & Configure (Apple IPSW)** — the one-tap setup:
   - `curl -C -` resumes the IPSW from Apple's CDN
   - verifies the expected `Content-Length` (5507405643 bytes)
   - creates Inferno backing disks (`qemu-img`)
   - extracts the IPSW into `/root/InfernoData/Restore`
   - fetches ChefKiss `create_apticket.py` / `create_septicket.py` / `ticket.shsh2`
   - fetches `AppleSEPROM-Cebu-B1` from [securerom.fun](https://securerom.fun)
   - forges `root_ticket.der` + `sep_root_ticket.der`
   - builds [xerub/img4lib](https://github.com/xerub/img4lib), looks up the
     SEP IV+Key for this build from
     [The Apple Wiki](https://theapplewiki.com/wiki/Keys:AzulSeed_18A5351d_(iPhone12,1))
     at runtime (keys are **not** stored in the repo), decrypts/rewraps
     `sep-firmware.n104.RELEASE.new.img4`
   - auto-detects kernel / DeviceTree / trustcache / ramdisk filenames
   - writes `run.env` + `READY` so Boot just works
5. **Boot iOS (t8030)** — runs `run-t8030.sh` (VNC on `127.0.0.1:5900`).
6. **Show READY status** — prints what was configured / what's still missing,
   plus jailbreak status.
7. **Jailbreak bootstrap (after restore)** — see [Jailbreak](#jailbreak-what-you-get-honestly).

### Apple IPSW URL used

```
https://updates.cdn-apple.com/2020SummerSeed/fullrestores/001-35886/5FE9BE2E-17F8-41C8-96BB-B76E2B225888/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw
```

Filename: `iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw` · size `5507405643`
bytes (verified via HTTP HEAD, Oct 2026). Same URL the ChefKiss file-setup guide
and the NixOS iOS-emulation wiki document.

### Manual / advanced

```sh
# inside the chroot
DATA=/root/InfernoData bash /root/download-and-configure.sh
cd /root/InfernoData && bash /root/run-t8030.sh
# restore/upgrade ramdisk:
RAMDISK=Restore/038-….dmg bash /root/run-t8030.sh
```

A full IPSW restore still needs the companion VM + `idevicerestore` (see the
upstream "Running & Restoring" guide). First boot without a prior restore may
not reach SpringBoard — that is expected.

## Jailbreak (what you get, honestly)

**Kernel side, always on.** Inferno patches the iOS kernel inside QEMU on every
boot (`hw/arm/apple-silicon/kernel_patches.c` at `cc4302a`). That covers the
AMFI trust-cache bypass (every binary counts as trusted), the code-signature and
`pmap_cs` bypasses, unsigned img4, rootfs remount and union mounts, and the APFS
update snapshot being disabled. So unsigned binaries already run, and there's no
`amfi=` boot-arg to add.

**Userland: added by step 7 / `jailbreak-prep.sh`.** This follows ChefKiss's
documented [Filesystem Patches](https://chefkiss.dev/guides/inferno/fs-patches/)
and [Jailbreak Utility Bootstrap](https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/)
pages:
- downloads the checkra1n **core bootstrap** (`strap.tar.lzma`: bash, apt,
  coreutils, ...) from `assets.checkra.in` at runtime. It is never stored in the
  repo. `WITH_CYDIA=1` also stages Cydia.app.
- builds [InfernoFSPatcher](https://git.chefkiss.dev/AppleHax/InfernoFSPatcher)
  (AGPL-3.0, cloned at runtime), which patches the dyld cache for software
  rendering.
- `patch-launchd.py` disables the services that break on the emulator (vmd,
  CommCenter*, locationd) and adds a root `/bin/bash` daemon on `/dev/console`.
- after applying, `run-t8030.sh` adds `launchd_unsecure_cache=1`, and you get a
  root shell on the serial console.

**What it can't do:**
- **palera1n/checkra1n can't run against this guest.** The emulator jumps
  straight into the kernel with no SecureROM, iBoot or DFU, so there's nothing
  for checkm8 to hit (Inferno maintainer, Discussion #162). No Sileo/Dopamine-style
  on-device jailbreak app is involved.
- **It doesn't happen on first boot by itself.** The bootstrap has to be written
  onto the *restored* APFS System volume. The `root` disk stays empty until a
  restore through the companion VM + `idevicerestore`, and that restore isn't
  automated here. ChefKiss documents writing that volume only from macOS
  (`hdiutil`/`diskutil`). On Linux it needs the out-of-tree linux-apfs-rw
  driver, which stock Android kernels don't have. So:
  - if your kernel lists `apfs` in `/proc/filesystems`, step 7 mounts the System
    volume read-write and applies everything (it makes a sparse backup
    `root.pre-jailbreak` first). This path is untested.
  - otherwise step 7 stages everything plus `jailbreak/apply-on-mac.sh`. Copy
    `root` and `jailbreak/` to a Mac, run
    `sudo ./apply-on-mac.sh /path/to/root`, copy `root` back, then
    `touch /root/InfernoData/JAILBREAK_APPLIED`.
- Not tested on a real restored disk (none on the build host).

## Scripts

- `setup-debian-chroot.sh` — shared chroot bootstrap (same as general-kvm).
- `setup-build-deps.sh` — install Inferno build dependencies (+ nettle 3.10 if
  needed).
- `build-inferno.sh` — clone + configure + build Inferno (pinned commit
  `cc4302a`, override with `REF=`).
- `download-and-configure.sh` — **new in v1.1.0**: Apple IPSW download + full
  file prep + `run.env`.
- `prepare-ios-files.sh` — create disks + extract IPSW (called by the
  downloader; safe to re-run).
- `jailbreak-prep.sh` — **v1.1.2**: stage/apply the jailbreak bootstrap
  (`stage` | `apply` with `SYSVOL=` | `status`). Also run automatically at the
  end of Download & Configure (stage only unless an APFS rw driver exists).
- `patch-launchd.py` — idempotent launchd.plist editor (Linux/macOS, stdlib).
- `run-t8030.sh` — the full `qemu-system-aarch64 -M t8030 …` command line;
  sources `run.env` when present.

## Verified vs not

- Verified on the build host: APK assembles; scripts pass `bash -n`; module zip
  has `module.prop` at root; Apple CDN URL returns HTTP 200 with the expected
  `Content-Length`; ChefKiss extras + SEPROM URLs return 200; Apple Wiki keys
  page parses (`#keypage-sepfirmware-iv` / `-key`).
- **Not** verified: the on-device Inferno build, a live 5.5 GB IPSW download on a
  phone, img4 decrypt/rewrap of SEP firmware, and an actual iOS boot (no phone
  on the build host). Treat on-device steps as "should work", not "tested here".
