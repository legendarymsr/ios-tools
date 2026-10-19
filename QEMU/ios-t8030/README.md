# ios-t8030 — emulated iPhone 11 (iOS) on Android via Inferno

Boot an emulated **iPhone 11 (t8030, Apple A13)** running **iOS 14.x** under
**Inferno** (ChefKiss; formerly *QEMUAppleSilicon*, originally the
*qemu-t8030* fork by TrungNguyen1909). Packaged as a KernelSU/Magisk module that
installs the **iOS Emu (t8030)** launcher app.

- Module zip: **`qemu-t8030-launcher-v1.0.0.zip`**
- App package: `com.qemut8030.launcher` (label "iOS Emu (t8030)")
- App source: [`launcher-app/`](launcher-app/)
- Upstream: https://github.com/ChefKissInc/Inferno · guide: https://chefkiss.dev/applehax/inferno/

## Reality check (important)

- The guest CPU is an **Apple A13**, so there is **no KVM** — it's pure **TCG
  emulation**: very slow (multi-minute boots), **no GPU** acceleration, software
  rendering only. This is bring-up/research quality, not a daily driver.
- You must supply your **own legal IPSW**. Nothing from Apple is shipped here.
  Reference target: **iOS 14.0 beta 5 for iPhone12,1** (iPhone 11). Inferno
  supports iOS 14.x on t8030 today (older/newer versions are WIP upstream).
- Inferno is built **on-device inside a Debian (glibc) chroot** — there is no
  Android/bionic build of QEMU. On an 8 GB-class phone the build is heavy; a
  strong phone with lots of RAM/storage is strongly recommended.
- "Can't it just build Firefox ESR…" — no shortcut here either: the iOS kernel
  must be emulated as Apple hardware; that's what Inferno does.

## Install

1. KernelSU manager → Modules → install `qemu-t8030-launcher-v1.0.0.zip`, reboot.
2. Open "iOS Emu (t8030)", grant root.

## Use (buttons, top to bottom)

1. **Set up Debian chroot** — Debian arm64 rootfs at `/data/local/debian` +
   `/data/local/enter-debian.sh`.
2. **Install build deps** — git, meson/ninja, glib, pixman, gnutls, nettle
   (built from source if Debian's is < 3.10), lzfse, SDL/GTK, etc.
3. **Build Inferno** — clones `ChefKissInc/Inferno` (pinned commit), configures
   with `--target-list=aarch64-softmmu,x86_64-softmmu` and `ninja`. Produces real
   aarch64 **Linux** (glibc) `qemu-system-aarch64` / `qemu-img` that run in the
   chroot. **Long build.**
4. **Show iOS file-prep steps** — prints `prepare-ios-files.sh`.
5. **Show t8030 run command** — prints `run-t8030.sh`.

### Supplying iOS files (inside the chroot)

Follow https://chefkiss.dev/guides/inferno/file-setup/ — summarised in
`prepare-ios-files.sh`:

```sh
./prepare-ios-files.sh /path/to/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw
# creates the raw backing disks + extracts the IPSW into ./Restore
pip install pyasn1 pyasn1-modules
python3 create_apticket.py n104ap Restore/BuildManifest.plist ticket.shsh2 root_ticket.der
# place SEP ROM dump  AppleSEPROM-Cebu-B1  (t8030/iPhone 11 = "Cebu B1")
# build img4 util + prepare sep-firmware.n104.RELEASE.new.img4
```

The `create_apticket.py` script, the `img4` utility, and SEP ROM dumps come from
the ChefKiss guide/tooling, not from this repo.

### Run

```sh
./run-t8030.sh                       # boot (adjust firmware filenames to your ipsw)
RAMDISK=Restore/038-44135-124.dmg ./run-t8030.sh   # restore/upgrade
```

Display defaults to a **VNC server** (`-display vnc=127.0.0.1:0`) — connect with
a VNC viewer on the phone. Override via `DISPLAY_QEMU`. Restore itself is done
from a companion VM with `idevicerestore` (see the upstream "Running &
Restoring" guide).

## Scripts

- `setup-debian-chroot.sh` — shared chroot bootstrap (same as general-kvm).
- `setup-build-deps.sh` — install Inferno build dependencies (+ nettle 3.10 if
  needed).
- `build-inferno.sh` — clone + configure + build Inferno (pinned commit
  `cc4302a`, override with `REF=`).
- `prepare-ios-files.sh` — create disks + extract IPSW + checklist for
  ticket/SEP.
- `run-t8030.sh` — the full `qemu-system-aarch64 -M t8030 …` command line.

## Verified vs not

- Verified on the build host: both APKs assemble; scripts pass `bash -n`; module
  zip has `module.prop` at root; the `t8030` command line and build flags match
  the current upstream guide (Oct 2026).
- **Not** verified: the on-device Inferno build, the IPSW/ticket/SEP prep, and an
  actual iOS boot (no phone/IPSW on the build host).
