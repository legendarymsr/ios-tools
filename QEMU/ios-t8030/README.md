# ios-t8030 — emulated iPhone 11 (iOS) on Android via Inferno

Boot an emulated **iPhone 11 (t8030, Apple A13)** running **iOS 14.x** under
**Inferno** (ChefKiss; formerly *QEMUAppleSilicon*, originally the
*qemu-t8030* fork by TrungNguyen1909). Packaged as a KernelSU/Magisk module that
installs the **iOS Emu (t8030)** launcher app.

- Module zip: **`qemu-t8030-launcher-v1.2.5.zip`**
- App package: `com.qemut8030.launcher` (label "iOS Emu (t8030)")
- App source: [`launcher-app/`](launcher-app/)
- Upstream: https://github.com/ChefKissInc/Inferno · guide: https://chefkiss.dev/applehax/inferno/

## Built-in VNC viewer (v1.1.4)

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

## Automatic restore (v1.2.0, step 5)

A blank Inferno disk has to be restored with `idevicerestore` before iOS
boots. ChefKiss does that from a separate **companion VM**: the emulated
iPhone's USB port is a socket that only another QEMU's `usb-tcp-remote`
device can plug into ([Companion VM Setup](https://chefkiss.dev/guides/inferno/companion-setup/)),
and that VM runs `usbmuxd` + `idevicerestore`. Then the restored System volume
gets the [Filesystem Patches](https://chefkiss.dev/guides/inferno/fs-patches/),
which the guide does on macOS. Step 5 **Restore iOS (automatic)** does all of
it on the phone:

1. **Tools (first run only, ~10-30 min).** `build-restore-tools.sh` builds
   into `/opt/inferno-restore` at pinned commits: libplist,
   libimobiledevice-glue, libusbmuxd, libtatsu, libimobiledevice, libirecovery,
   usbmuxd, and idevicerestore with ChefKiss's
   [`idevicerestore.patch`](https://chefkiss.dev/Extras/Inferno/idevicerestore.patch)
   (`idevicerestore-inferno.patch`). It also builds libusb 1.0.29 without udev,
   InfernoFSPatcher, and the USB-host VM: Debian's own `linux-image-arm64`
   kernel (via apt), [linux-apfs-rw](https://github.com/linux-apfs/linux-apfs-rw)
   built against the matching `linux-headers`, and a busybox initramfs
   (`companion-init.sh`). Inferno itself is **not** rebuilt; the build from step
   3 already has the `virt` machine, `usb-ehci`, `usb-tcp-remote`, 9p and slirp.
2. **USB-host VM** (`companion-vm.sh usbmux`). It's a small aarch64 `virt` VM
   (TCG, 512 MB) running the same Inferno `qemu-system-aarch64`, with
   `-device usb-ehci -device usb-tcp-remote,conn-type=unix,conn-addr=InfernoData/restore/usb.sock`.
   Its userland is this Debian chroot, shared read-only over 9p, so nothing
   else is downloaded. It only runs `usbmuxd -S 0.0.0.0:27015`, forwarded to
   `127.0.0.1:27015` in the chroot.
3. **Restore ramdisk.** It boots `run-t8030.sh` with `RESTORE_MODE=1` and
   `usb-conn-type=unix,usb-conn-addr=…` (the same flags as ChefKiss's
   `-M t8030,…,usb-conn-*`). The VNC screen shows the restore, so you can
   watch with **Open VNC viewer**.
4. **idevicerestore** runs natively in the chroot. It talks to the VM's
   usbmuxd via `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015`:
   `idevicerestore --erase --restore-mode --no-input -i 0x1122334455667788 -T root_ticket.der <ipsw>`
   (the guide's command plus `--no-input`). The OS image is streamed straight
   from the downloaded `.ipsw`; it's stored uncompressed in that zip, so
   nothing is extracted. Progress is logged every 5 %. The guest closes itself
   when restore stage 1 is done.
5. **Filesystem patches** (`companion-vm.sh apfs-run`). The USB-host VM boots
   again with `root` attached and mounts the System volume read-write with
   linux-apfs-rw. It runs InfernoFSPatcher on `dyld_shared_cache_arm64e`, then
   `patch-launchd.py --no-bash` sets `Disabled` on vmd, CommCenter*, and
   locationd. The original `launchd.plist` is saved to `InfernoData/restore/`.
6. Writes `InfernoData/RESTORED`. **Boot iOS** now boots normally. The first
   boot runs data migration (restore stage 2) and can take a long time under
   TCG before the setup screen. Don't set a passcode, don't enable location
   services, and never use "Erase All Content and Settings" (ChefKiss).

Resuming and retrying:
- The work runs detached inside the chroot (`setsid`). Closing the app doesn't
  stop it, and tapping step 5 again re-attaches to `InfernoData/restore/restore.log`.
- On the first run, all nine Inferno disks are backed up (sparse) to
  `InfernoData/restore/blank/`. If stage 1 fails or gets interrupted, the next
  tap resets the disks from that backup and restores again. A failed FS-patch
  stage is retried on its own. `FORCE_RESTORE=1` wipes a restored guest back to
  blank and restores again.
- Errors print one `[ERROR] …` line plus the tail of the relevant log
  (`restore/inferno.log`, `restore/ios-serial.log`, `restore/idevicerestore.log.raw`,
  `companion/console.log`, `companion/job.log`).
- Inside the chroot: `bash /root/restore-ios.sh status | stop`.

Limits:
- Under TCG on a phone, the restore ramdisk can take 10-40+ min to come up and
  the restore itself can take hours. The step waits up to 3 h for the device
  (`DEVICE_TIMEOUT`, default 6 h).
- linux-apfs-rw write support is marked experimental upstream. If the FS-patch
  stage fails, the restore itself is still on disk. Do the patches on a Mac
  (fs-patches guide), then re-run step 5 with `SKIP_FS_PATCHES=1`.
- Not tested end to end here: the build host has no phone and no 5.5 GB IPSW
  restore. See "Verified vs not".

## Reality check (important)

- The guest CPU is an **Apple A13**, so there is **no KVM** — it's pure **TCG
  emulation**: very slow (multi-minute boots), **no GPU** acceleration, software
  rendering only. This is bring-up/research quality, not a daily driver.
  Inferno `@ cc4302a` hardcodes `TYPE_APPLE_A13` and `minimum_page_bits=14`
  (16 KiB pages); `-accel kvm` / `-cpu host` are not usable for this machine.
  `run-t8030.sh` probes `/dev/kvm` for logging but always launches with
  `-accel tcg`.
- **v1.2.5 USB-host VM kept alive:**
  - **Why the VM died:** the app's root shell and everything it starts (both QEMUs) lived in the app's cgroup. There, Android's phantom-process killer and its per-app process-group kill can SIGKILL a CPU-heavy QEMU once the launcher is in the background (for example while you watch the VNC viewer).
  - **Steps now leave the app's cgroup:** steps 2-8 move themselves to the root cgroup (`/sys/fs/cgroup`, `/acct`) first. The USB-host VM also gets `oom_score_adj -800` and a 128 MB TCG code buffer (`COMPANION_TB_MB`).
  - **usbmuxd is restarted:** if usbmuxd exits inside the VM, it is restarted (up to 5 times) and the exit status is logged, instead of the VM powering off.
  - **Clearer failure report:** a wrapper records how QEMU ended (`companion/qemu.exit`: exit status or signal; 137 = SIGKILL). On failure, step 5 prints that reason, any host OOM lines, the last 40 console lines, the QEMU log, and the usbmuxd log without the client connect/disconnect lines. The same report is available with `bash /root/companion-vm.sh report`.
  - **USB link in the progress line:** the 2-minute progress line shows whether the iOS VM has connected to the USB-host VM yet (`USB link connected/not yet`). Inferno connects only once, when iOS enables its USB controller, which can take an hour under TCG on a phone. If that connect fails, step 5 stops with a clear error. `DEVICE_TIMEOUT` is now 6 h.
- **v1.2.4 SEP firmware rewrap fix:** on the phone, step 4's `img4 -A -F … -T rsep` wrote the IM4P type as `pesr`. xerub's img4lib only byte-swaps fourccs when `__LITTLE_ENDIAN__`, `__x86_64__` or `__i386__` is defined, and GCC on arm64 Linux defines none of them (it defines `__AARCH64EL__` / `__BYTE_ORDER__`). Every SEP firmware that step 4 built on the phone, in all earlier versions, therefore had the wrong type. That is the most likely cause of the `dart-sep` / `t8020dart invalid lock state` restore panic. Step 4 now writes the IMG4 itself (`check-sep.py wrap`): `IMG4 { IM4P { "rsep", <version string copied from the IPSW's im4p>, <decrypted payload> }, [0] <sep_root_ticket.der> }`. The output is byte-identical to what img4lib builds on x86_64. img4lib is still used only to decrypt, which is endian-safe, and new img4lib builds get `-D__LITTLE_ENDIAN__=1`. The `none` line in the log is img4lib's normal output, not an empty version string. Re-run step 4 (it replaces the bad file), then step 5.
- **v1.2.3 SEP checks:** `panic(... caller 0xfffffff009686304): "t8020dart invalid lock state"` right after `Id(dart-sep) AppleT8020DART::_interruptHandler: DART interrupt while disabled by the client` means the SEP made a DMA access that faulted in the SEP DART. The ChefKiss FAQ entry for the related `dart-sep ... DART(DART) error` panic says "User error; bad SEP ROM or SEP Firmware", and issue #314 (iOS VM crashing after idevicerestore) was a wrong IV/key. iOS 14.0 beta 5 (18A5351d) on iPhone12,1 is still the target of the ChefKiss guide. New `check-sep.py` checks that the SEP ROM is the Cebu B1 dump (86016 bytes, sha256 `e3b11f62…`). It also checks that `sep-firmware.n104.RELEASE.new.img4` is an IMG4 of type `rsep` that holds a *decrypted* SEPOS, has the SEP ticket attached, and uses the exact IM4P version string of the IPSW's `sep-firmware.n104.RELEASE.im4p`. Step 4 now runs these checks: it downloads a bad SEP ROM again, moves a bad SEP firmware to `.bad` and rebuilds it, and stops with an `[ERROR]` if the IV/Key (from The Apple Wiki or `sep_ivkey.txt`) does not decrypt the SEP firmware. Steps 5 and 6 refuse to boot with bad SEP files. Re-run step 4 once after updating (it only redoes the SEP part); step 3 does not need to be re-run.
- **v1.2.2 restore panic diagnostics:** the `IOPlatformPanicAction -> AppleS8960XWatchDogTimer / AppleT8030PMGR` and `wdog panic (attempt 1)` lines are printed for *every* iOS panic, so they don't show the cause, and `wdt=-1` is already passed. On failure, step 5 now prints the 40 lines before and after the first panic line and keeps every attempt's full serial log as `InfernoData/restore/ios-serial.<time>.log`. `-smp` now defaults to 7, as in the ChefKiss guide: Inferno uses one of the `-smp` CPUs for the emulated SEP, so 6 gave only 5 A13 cores. The USB-host VM uses 1 vCPU during the restore so the SEP and iOS cores get more of the phone's CPU. No Inferno rebuild needed.
- **v1.2.1 keymap fix:** the iOS VM died at start with `could not read keymap file: 'en-us'`: the step 3 build-tree QEMU was never installed, so it had no data dir. `run-t8030.sh` and `companion-vm.sh` now find one at runtime (build `qemu-bundle`/`pc-bios`, `/usr/local/share/qemu`, `/usr/share/qemu`, else the Inferno source's `pc-bios/keymaps`) and pass it with `-L`. No rebuild needed.
- **v1.2.0:** new step 5 **Restore iOS (automatic)** (see above). Steps after it
  are renumbered: 6 Boot, 7 Status, 8 Jailbreak. Boot now refuses a blank or
  half-restored disk and tells you to run step 5. Step 8 writes the jailbreak
  bootstrap with the same USB-host VM (linux-apfs-rw), so no Mac is needed.
- **v1.1.8 Boot VNC fix:** QEMU 10 rejected `-display vnc=…,show-cursor=on` (`Invalid parameter 'show-cursor'`). Default is now `-display vnc=127.0.0.1:0`.
- **v1.1.7 step 3/4 fixes:**
  - Step 3 never produced `qemu-img` / `qemu-system-aarch64`. Inferno's
    `--enable-nettle` needs nettle >= 3.10; step 2 builds 3.10.2, but nettle
    installs into `/usr/local/lib64`, which pkg-config and ld.so do not search,
    so configure kept seeing bookworm's 3.8. Both paths are now registered.
  - Step 3 only fetches the `util/mlib` submodule. The old
    `submodule update --init --recursive` also pulled every QEMU firmware ROM
    repo (edk2, u-boot, seabios, ...: several GB) that the build never uses.
  - Source is a shallow fetch of the pinned commit with retries; if git keeps
    dropping the connection (`GnuTLS recv error`), it falls back to GitHub's
    source tarball.
  - Re-runs: an identical finished configure is resumed with `ninja`, anything
    else (other commit/flags, failed configure, interrupted clone) is wiped
    first. `CLEAN=1` forces a fresh build dir, `CLEAN_SRC=1` a fresh source.
  - The job count follows free RAM, and an OOM-killed compile is resumed with
    `-j1`. Only `aarch64-softmmu` is built (`FULL_TARGETS=1` adds x86_64), and
    GTK/SDL are off because the display is VNC. The step ends by checking that
    the binary has the `t8030` machine.
  - Step 4: the SEP IV/Key lookup no longer depends on one HTML page fetch (that
    got a 403 on some networks). It tries The Apple Wiki raw wikitext, its API, and
    the rendered page, each with browser headers through both curl and
    Python. The keys stay in memory only. If every source fails, paste the
    SEPFirmware IV followed by the Key (no spaces) into `/data/local/debian/root/InfernoData/sep_ivkey.txt` and re-run.
  - Step 4: the SEP `-V` version string is now taken from the decrypt command's
    output, as in the ChefKiss guide. Kernel, DeviceTree, Erase ramdisk, its
    trustcache, and SEP paths are read from `BuildManifest.plist`.
  - Step 5: the restore ramdisk is only passed while the `root` disk is blank
    (`RESTORE_MODE=1` forces it), and `sep_nvram` is kept at 64 KiB.
- **v1.1.3 Install & update Debian:** step 1 is now **Install & update Debian**.
  After the rootfs is in place (or if it already is) it runs `apt-get update`
  and `apt-get upgrade -y` inside the chroot and stops with a clear error if
  either fails. Re-running it on an existing install just updates Debian.
  apt downloads as root (`APT::Sandbox::User "root"`), because Android only
  lets the inet group open sockets. `enter-debian.sh` now enters with a clean
  Debian environment, which removes the `/etc/profile: id: command not found`
  noise.
- **v1.1.3 lzfse fix (step 2):** Debian bookworm has no `liblzfse-dev` / `lzfse`
  packages, so `apt-get install` failed. `setup-build-deps.sh` now installs the
  rest from apt (plus `cmake`), then builds lzfse from
  [lzfse/lzfse](https://github.com/lzfse/lzfse) at pinned commit `e634ca5`
  into `/usr/local` (`liblzfse.so`, `lzfse.h`, `lzfse` CLI), and checks that a
  test program links against `-llzfse`. Any apt or build failure stops the step
  with an `[ERROR]` line.
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

1. KernelSU manager → Modules → install `qemu-t8030-launcher-v1.2.5.zip`, reboot.
2. Open "iOS Emu (t8030)", grant root.

## Use (buttons, top to bottom)

1. **Install & update Debian** — Debian arm64 rootfs at `/data/local/debian` +
   `/data/local/enter-debian.sh`, then `apt-get update` + `apt-get upgrade -y`
   inside the chroot. Re-run any time to update Debian.
2. **Install build deps** — git, ninja, meson >= 1.5 (from PyPI; bookworm's is 1.0.1), glib, pixman, gnutls, nettle
   (built from source if Debian's is < 3.10), lzfse (built from source;
   bookworm has no package), etc.
3. **Compile Inferno / qemu-t8030 in the chroot**: checks meson >= 1.5 and
   nettle >= 3.10, fetches `ChefKissInc/Inferno` at the pinned commit (+ `util/mlib`),
   configures `aarch64-softmmu` with VNC output, and builds `qemu-system-aarch64` +
   `qemu-img` into `/root/Inferno/build`. **Long build** (30-90 min). Safe to
   re-run: it resumes or cleans as needed.
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
5. **Restore iOS (automatic)**: builds the restore tools on first run, then
   restores the IPSW onto the blank disk and applies the filesystem patches.
   See [Automatic restore](#automatic-restore-v120-step-5). Long; tap again to
   re-attach.
6. **Boot iOS (t8030)**: runs `run-t8030.sh` (VNC on `127.0.0.1:5900`). The
   built-in viewer opens by itself once the VNC port is up. The first boot
   after the restore finishes data migration.
7. **Show READY / restore status**: shows what's configured, what's still
   missing, the restore state, and the jailbreak status.
8. **Jailbreak bootstrap (after restore)**: see [Jailbreak](#jailbreak-what-you-get-honestly).

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
RESTORE_MODE=1 bash /root/run-t8030.sh   # force the restore ramdisk
RESTORE_MODE=0 bash /root/run-t8030.sh   # force a normal boot
```

# restore (what step 5 does):
DATA=/root/InfernoData bash /root/restore-ios.sh          # start / re-attach
DATA=/root/InfernoData bash /root/restore-ios.sh status
DATA=/root/InfernoData bash /root/restore-ios.sh stop
```

```sh
# the USB-host VM by hand
DATA=/root/InfernoData bash /root/companion-vm.sh usbmux   # usbmuxd on 127.0.0.1:27015
USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 /opt/inferno-restore/bin/idevice_id -l
DATA=/root/InfernoData bash /root/companion-vm.sh apfs-run 'ls "$SYSVOL"'
DATA=/root/InfernoData bash /root/companion-vm.sh stop

## Jailbreak (what you get, honestly)

**Kernel side, always on.** Inferno patches the iOS kernel inside QEMU on every
boot (`hw/arm/apple-silicon/kernel_patches.c` at `cc4302a`). That covers the
AMFI trust-cache bypass (every binary counts as trusted), the code-signature and
`pmap_cs` bypasses, unsigned img4, rootfs remount and union mounts, and the APFS
update snapshot being disabled. So unsigned binaries already run, and there's no
`amfi=` boot-arg to add.

**Userland: added by step 8 / `jailbreak-prep.sh`.** This follows ChefKiss's
documented [Filesystem Patches](https://chefkiss.dev/guides/inferno/fs-patches/)
and [Jailbreak Utility Bootstrap](https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/)
pages:
- downloads the checkra1n **core bootstrap** (`strap.tar.lzma`: bash, apt,
  coreutils, ...) from `assets.checkra.in` at runtime. It is never stored in the
  repo. `WITH_CYDIA=1` also stages Cydia.app.
- builds [InfernoFSPatcher](https://git.chefkiss.dev/AppleHax/InfernoFSPatcher)
  (AGPL-3.0, cloned at runtime), which patches the dyld cache for software
  rendering.
- `check-sep.py` - checks the SEP ROM and the prepared SEP firmware (used by steps 4-6)
- `patch-launchd.py` disables the services that break on the emulator (vmd,
  CommCenter*, locationd) and adds a root `/bin/bash` daemon on `/dev/console`.
- after applying, `run-t8030.sh` adds `launchd_unsecure_cache=1`, and you get a
  root shell on the serial console.

**What it can't do:**
- **palera1n/checkra1n can't run against this guest.** The emulator jumps
  straight into the kernel with no SecureROM, iBoot or DFU, so there's nothing
  for checkm8 to hit (Inferno maintainer, Discussion #162). No Sileo/Dopamine-style
  on-device jailbreak app is involved.
- **It isn't there on first boot by itself.** The bootstrap has to be written
  onto the *restored* APFS System volume, so run step 5 first. ChefKiss
  documents writing that volume only from macOS (`hdiutil`/`diskutil`). On
  Linux it needs the out-of-tree linux-apfs-rw driver, which stock Android
  kernels don't have. So:
  - step 8 boots the USB-host VM from step 5 (Debian kernel + linux-apfs-rw)
    and applies everything there. It makes a sparse backup
    `root.pre-jailbreak` first if there's room. If your phone kernel lists
    `apfs` in `/proc/filesystems`, that is used instead.
  - fallback: step 8 also stages `jailbreak/apply-on-mac.sh`. Copy `root` and
    `jailbreak/` to a Mac, run `sudo ./apply-on-mac.sh /path/to/root`, copy
    `root` back, then `touch /root/InfernoData/JAILBREAK_APPLIED`.
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
  sources `run.env` when present. `RESTORE_MODE=1|0`, `USB_CONN_TYPE/ADDR/PORT`,
  `SERIAL_QEMU` overrides.
- `restore-ios.sh` — **v1.2.0** step 5 orchestrator (detached worker, state in
  `InfernoData/restore/state`).
- `build-restore-tools.sh` — **v1.2.0** builds `/opt/inferno-restore`
  (libimobiledevice stack, idevicerestore + patch, usbmuxd, no-udev libusb,
  InfernoFSPatcher, USB-host VM kernel/initramfs + apfs.ko).
- `companion-vm.sh` / `companion-init.sh` — **v1.2.0** the USB-host VM
  (`usbmux` | `apfs-run CMD` | `stop` | `status`) and its initramfs `/init`.
- `idevicerestore-inferno.patch` — ChefKiss's idevicerestore patch (maps the
  emulated `…DEV` hardware model to `…AP`).

## Verified vs not

- Verified on the build host: APK assembles; scripts pass `bash -n`; module zip
  has `module.prop` at root; Apple CDN URL returns HTTP 200 with the expected
  `Content-Length`; ChefKiss extras + SEPROM URLs return 200; Apple Wiki keys
  page parses (`#keypage-sepfirmware-iv` / `-key`).
- **Not** verified: the on-device Inferno build, a live 5.5 GB IPSW download on a
  phone, img4 decrypt/rewrap of SEP firmware, and an actual iOS boot (no phone
  on the build host). Treat on-device steps as "should work", not "tested here".
- v1.2.0 restore, verified on the build host: against the Inferno source at
  `cc4302a`, `usb-tcp-remote` (`CONFIG_USB_TCP`, default y) and the `virt`
  machine are in the aarch64 build, and step 3 already enables slirp and
  virtfs. In the pinned sources, `usbmuxd -S ADDR:PORT`, libusbmuxd's
  `USBMUXD_SOCKET_ADDRESS`, and idevicerestore's `--restore-mode/--no-input/
  --plain-progress/-T/--cache-path` options all exist, and ChefKiss's patch
  applies to the pinned idevicerestore. All the bookworm arm64 package names
  exist. Debian 6.1.0-50-arm64 builds virtio/9p/EHCI as modules with 4 KiB
  pages. The OS image in the 18A5351d IPSW is stored uncompressed (zip
  central directory read from Apple's CDN), so it is never extracted. The
  libusb tarball sha256 is checked. The scripts pass `bash -n`.
- v1.2.0 restore, **not** verified: the full tool build, the USB-host VM
  boot, usbmuxd seeing the emulated iPhone, the idevicerestore run itself,
  and linux-apfs-rw writes to a real iOS System volume. The first run on the
  phone is the real test, so send the step 5 log if it fails.
