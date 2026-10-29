#!/usr/bin/env bash
# hackios.sh -- run HackiOS (iOS 16.5 user space on Apple's open-source XNU kernel) in QEMU's
# `virt` machine inside this Debian chroot on the phone (launcher steps 2-4).
#
# HackiOS is by OOSEX GANG (@oodze, @netusd, @wannqn, @hxfuxyyXD):
#   https://github.com/oosexgang  ·  https://hackios-web.vercel.app  ·  https://t.me/oosexgangdevs
# hackios-xnu-kernel is APSL 2.0, hackios-xnu-userland is MIT. Nothing of theirs is copied into
# ios-tools: this script clones their repositories at the commits pinned below and runs their own
# scripts. HackiOS is not affiliated with, authorised or endorsed by Apple Inc.; no Apple files are
# shipped -- their sysimage/fetch.sh downloads iOS 16.5 from Apple's CDN onto this phone.
#
#   hackios.sh setup    packages, 7-Zip 24.09 (APFS needs 7-Zip 23+), both HackiOS repositories
#   hackios.sh build    download iOS 16.5 (7.4 GB, resumable), build HackiOS's loader and the
#                       images root.apfs + system.apfs (HackiOS's prebuilt kernel and programs)
#   hackios.sh run      boot it: QEMU virt, display on VNC 127.0.0.1:5900, network on (QEMU_NET=1)
#   hackios.sh save     save the running iOS to a snapshot (once it is on the home screen): the next
#                       run resumes it in seconds instead of booting for many minutes (QEMU 8.2+)
#   hackios.sh forget   delete the snapshot, so the next run boots afresh
#   hackios.sh stop     stop that QEMU
#   hackios.sh status   what is installed / built / running
#
# env: HACKIOS_DIR (default /root/hackios), HACKIOS_REF=latest (track main instead of the pins),
#      HACKIOS_SECS (session length, default 7200: the kernel returns to the loader after it),
#      HACKIOS_SMP (vCPUs, default 4), HACKIOS_RAM_GB (guest RAM, default 7: HackiOS's layout
#      puts the 2.5 GB system image high in RAM; the guest RAM is a file mapping, so the phone
#      itself needs about 2.5-3 GB free), HACKIOS_NET=0 (no network; takes effect at the next build),
#      HACKIOS_JOBS=<file> (the job list iOS runs at boot instead of ours; see net_jobs below),
#      HACKIOS_VNC=<n> (VNC display number, default 0 = port 5900, for hosts where it is taken),
#      HACKIOS_SNAPSHOT=0 (boot afresh even when a snapshot is saved), HACKIOS_TZ=<zone> (iOS's time
#      zone, e.g. Europe/London; the launcher passes Android's persist.sys.timezone),
#      HACKIOS_JB=0 (no jailbreak: leave out HackiOS's Procursus + Sileo prefix; next build),
#      HACKIOS_NEWTERM=0 (leave out the bundled NewTerm terminal app; needs the jailbreak; next build),
#      NEWTERM_DEB=<path> (bundle this local NewTerm .deb instead of fetching it from Chariz),
#      HACKIOS_TROLLSTORE=0 (leave out TrollStore; needs the jailbreak; next build),
#      TROLLSTORE_VERSION=<tag> (opa334/TrollStore release to fetch, default the latest),
#      TROLLSTORE_TAR=<path> / TROLLHELPER_DEB=<path> (use these local files instead of downloading),
#      HACKIOS_TIPAS="<path-or-url> ..." (.tipa/.ipa files TrollStore installs at boot; default the
#      ios-tools Hello World app; HACKIOS_TIPAS=none for none),
#      HACKIOS_ROOTFUL=0 (turn OFF the ephemeral writable-root overlay, which is ON by default -- a
#      ramfs union over the system dirs so files can be created in /Applications, /Library, /usr, /bin,
#      /sbin in memory; lost on a cold boot, cannot change existing read-only system files; next build),
#      HACKIOS_ROOTFUL_DIRS="/A /B" (which directories the overlay covers; default
#      "/Applications /Library /usr /bin /sbin"),
#      HACKIOS_WALLPAPER=0 (keep iOS's stock default wallpaper instead of the black one; next build),
#      HACKIOS_FBSCALE=2 (render the UI at 2x and upscale: less CPU per frame, a bit softer; it did not
#      change the frame rate in testing, so the default is native 3).
set -euo pipefail
DIR="${HACKIOS_DIR:-/root/hackios}"
HERE=$(cd "$(dirname "$0")" && pwd)
# optional local overrides: a file of `HACKIOS_...=...` lines next to this script, so experimental
# flags (e.g. HACKIOS_ROOTFUL=1) can be turned on without changing the launcher's build command --
# create /root/.hackios-env in the chroot with the settings you want.
# shellcheck disable=SC1091
[ -f "$HERE/.hackios-env" ] && . "$HERE/.hackios-env" || true
KERNEL_URL=https://github.com/oosexgang/hakios-xnu-kernel.git    # kernel + user space in one repository since 2026-10-25
KERNEL_PIN=88513176b1e96ecf0b764cd62c6f4e6ac71345e3     # 2026-10-26 "Update README.md"
SEVENZIP_VER=2409
declare -A SEVENZIP_SHA=(
  [arm64]=fbe331697c9417bbc06fc92d3f4576dca6a5a1442fad7ae810304446a9153e2c
  [x64]=914c7e20ad5ef8e4d3cf08620ff8894b28fe11b7eb99809d6930870fbe48a281
)
EFI_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
EFI_VARS=/usr/share/AAVMF/AAVMF_VARS.fd

log() { printf '[hackios] %s\n' "$*"; }
die() { printf '[hackios] ERROR: %s\n' "$*" >&2; exit 1; }
credit() {
  log "HackiOS by OOSEX GANG - https://github.com/oosexgang (kernel APSL 2.0, userland MIT)"
}
free_gb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 { print int($4 / 1048576) }'; }
qemu_pids() { pgrep -f "qemu-system-aarch64.*payload\.bin" 2>/dev/null || true; }

install_7zip() {
  if command -v 7z >/dev/null 2>&1 && 7z 2>/dev/null | grep -qE '7-Zip( \(z\))? (2[3-9]|[3-9][0-9])\.'; then
    log "7-Zip: $(7z 2>/dev/null | grep -m1 -oE '7-Zip.*\) [0-9.]+')"; return 0
  fi
  local arch
  case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) die "no 7-Zip build for $(uname -m)" ;; esac
  local t; t=$(mktemp -d)
  log "installing 7-Zip ${SEVENZIP_VER} ($arch) from github.com/ip7z/7zip (Debian's 7-Zip is too old to read APFS)"
  curl -fsSL --retry 3 -o "$t/7z.tar.xz" \
    "https://github.com/ip7z/7zip/releases/download/${SEVENZIP_VER:0:2}.${SEVENZIP_VER:2}/7z${SEVENZIP_VER}-linux-$arch.tar.xz" \
    || die "7-Zip download failed"
  echo "${SEVENZIP_SHA[$arch]}  $t/7z.tar.xz" | sha256sum -c --quiet - || die "7-Zip download has the wrong checksum"
  mkdir -p /usr/local/lib/7zip && tar -xf "$t/7z.tar.xz" -C /usr/local/lib/7zip
  ln -sf /usr/local/lib/7zip/7zz /usr/local/bin/7z
  rm -rf "$t"
  7z | head -2 | tail -1
}

checkout() { # checkout DIR URL PIN [GIT_DIR]: the pinned commit (or main with HACKIOS_REF=latest)
  local d="$1" url="$2" pin="$3"
  if [ "${HACKIOS_REF:-pinned}" = latest ]; then
    git -C "$d" fetch -q --depth 1 origin main && git -C "$d" checkout -q FETCH_HEAD
  else
    git -C "$d" fetch -q --depth 1 origin "$pin" && git -C "$d" checkout -q "$pin"
  fi
}

do_setup() {
  credit
  local need_gb=14 have; have=$(free_gb "$(dirname "$DIR")")
  [ -n "$have" ] && [ "$have" -lt "$need_gb" ] && log "WARNING: only ${have} GB free; download + images need about ${need_gb} GB"
  log "installing packages (git, python3, gcc, QEMU for aarch64, UEFI firmware)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q || true
  apt-get install -y -q --no-install-recommends git python3 gcc libc6-dev curl ca-certificates xz-utils \
    clang lld lz4 make qemu-system-arm qemu-efi-aarch64 qemu-utils procps zstd binutils >/dev/null || die "apt-get install failed"
  # snapshots (hackios.sh save) need QEMU 8.2+, which saves the ramfb display; bookworm has 7.2,
  # bookworm-backports has trixie's QEMU 10.0 (no speed difference measured, only the snapshots)
  if ! qemu_ok_for_snapshots && grep -q '^VERSION_CODENAME=bookworm' /etc/os-release 2>/dev/null; then
    log "QEMU $(qemu-system-aarch64 --version | head -1 | awk '{print $4}') cannot save snapshots: installing QEMU 10 from bookworm-backports"
    grep -rqs 'bookworm-backports' /etc/apt/sources.list /etc/apt/sources.list.d/ \
      || echo 'deb http://deb.debian.org/debian bookworm-backports main' > /etc/apt/sources.list.d/bookworm-backports.list
    apt-get update -q >/dev/null || true
    apt-get install -y -q --no-install-recommends -t bookworm-backports qemu-system-arm qemu-utils >/dev/null \
      || log "WARNING: QEMU from bookworm-backports did not install; HackiOS runs, but without snapshots"
  fi
  qemu-system-aarch64 -cpu help 2>/dev/null | grep -qw cortex-a76 \
    || die "this QEMU ($(qemu-system-aarch64 --version | head -1)) has no cortex-a76 CPU; HackiOS needs QEMU 7.1+"
  [ -f "$EFI_CODE" ] && [ -f "$EFI_VARS" ] || die "UEFI firmware missing ($EFI_CODE)"
  install_7zip

  if [ ! -d "$DIR/.git" ]; then
    log "cloning hackios-xnu-kernel into $DIR"
    git init -q "$DIR" && git -C "$DIR" remote add origin "$KERNEL_URL"
  fi
  checkout "$DIR" "$KERNEL_URL" "$KERNEL_PIN"
  # the old two-repository layout (hackios-xnu-userland checked out over this tree): start afresh
  if [ -d "$DIR/.userland.git" ]; then
    log "the user space moved into the kernel repository upstream: removing the old .userland.git checkout"
    rm -rf "$DIR/.userland.git" "$DIR/ios165" "$DIR/common"
    git -C "$DIR" reset -q --hard && git -C "$DIR" clean -qfd -e sysimage -e jb -e qemu/hackios.snapshot\* || true
  fi
  log "HakiOS repository at $(git -C "$DIR" rev-parse --short HEAD)"
  log "setup done - next: step 3 (download iOS 16.5 + build the images)"
}

# Fixes to HackiOS's checkout (pinned commits), each applied once; report them upstream:
#  - userland/build.sh copies obj/drawable_test, which prebuilt/userland does not have (PREBUILT=1 stops)
#  - userland/build.sh asks timedatectl for the time zone under set -e; without systemd (this chroot)
#    the build stops there without a message
#  - userland/mkjobs.py reuses the loop variable `name` for RWA_PACKED16, so the ~400 on-demand iOS
#    jobs (REST=1: configd, mDNSResponder, trustd, nsurlsessiond, ...) all overwrite one file named
#    RWA_PACKED16 and none of them can start: no DHCP, no DNS, Safari "not connected to the Internet"
#  - (not bugs: two switches for snapshots, default unchanged) qemu/run.sh mounts the ESP read-write
#    and qemu/run-ios.sh always adds virtio-sound; QEMU refuses to save a VM with either, so
#    QEMU_ESP_RW= QEMU_ESP_RO=1 mounts it read-only and QEMU_SOUND=0 leaves the sound device out
#  - (not bugs, ours) userland/build.sh takes the time zone from HACKIOS_TZ when timedatectl has none
#    (the launcher passes Android's), copies obj/timesync into the image when it is there, and
#    qemu/run-ios.sh passes QEMU_NET_EXTRA to the user network (the host's clock for timesync)
#  - xnuloader/loader.c reads back the fw_cfg DMA answer through a plain variable, so -O1 folds the
#    check and the prebuilt loader.efi always gives up on the 1125x2436 ramfb: black screen
#  - (not a bug, ours) QEMU's VNC server drops every row below 2160 (ui/vnc.h VNC_MAX_HEIGHT), which
#    cut iOS's dock off in the launcher's viewer. The loader makes the ramfb PANEL 944x2048 (<=2048,
#    iOS's aspect); iOS still renders 1125x2436 and the kernel scales it onto the panel, exactly as it
#    scales to the real phone's 1080x2400, so the UI is unchanged
fix_checkout() {
  python3 - "$DIR" <<'PYFIX'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
fixes = [
  ("userland/build.sh",
   "zone=$(timedatectl show -p Timezone --value 2>/dev/null); ",
   "zone=$(timedatectl show -p Timezone --value 2>/dev/null || true); "),
  ("qemu/run.sh",
   "-drive file=fat:rw:esp,format=raw,if=virtio ",
   "-drive file=fat:${QEMU_ESP_RW-rw:}esp,format=raw,if=virtio${QEMU_ESP_RO:+,readonly=on} "),
  ("qemu/run-ios.sh",
   "if qemu-system-aarch64 -device help 2>/dev/null | grep -q '\"virtio-sound-device\"'; then",
   "if [ \"${QEMU_SOUND:-1}\" != 0 ] && qemu-system-aarch64 -device help 2>/dev/null | grep -q '\"virtio-sound-device\"'; then"),
  ("userland/build.sh",
   "zone=${zone:-UTC}",
   "zone=${zone:-${HACKIOS_TZ:-UTC}}"),
  ("qemu/run-ios.sh",
   "\tNET=(-netdev user,id=net0 -device virtio-net-device,netdev=net0)\n",
   "\tNET=(-netdev \"user,id=net0${QEMU_NET_EXTRA:+,$QEMU_NET_EXTRA}\" -device virtio-net-device,netdev=net0)\n"),
  ("xnuloader/loader.c",
   "#define PHONE_WIDTH     1125            /* the screen of the iPhone X, whose identity we carry */\n#define PHONE_HEIGHT    2436\n",
   "#define PHONE_WIDTH     1125            /* the screen of the iPhone X, whose identity we carry */\n#define PHONE_HEIGHT    2436\n"
   "/* ios-tools: the ramfb PANEL QEMU presents. iOS renders PHONE_WIDTH x PHONE_HEIGHT and the kernel\n"
   " * scales onto this panel, so the UI is unchanged; <=2048 tall because QEMU VNC here tops out at 2048 (VGA_MAX_HEIGHT). */\n"
   "#define PANEL_WIDTH     944\n#define PANEL_HEIGHT    2048\n"),
  ("xnuloader/loader.c",
   "\tuint64_t fb = 0, bytes = (uint64_t)PHONE_WIDTH * 4 * PHONE_HEIGHT;",
   "\tuint64_t fb = 0, bytes = (uint64_t)PANEL_WIDTH * 4 * PANEL_HEIGHT;"),
  ("xnuloader/loader.c",
   "\tcfg.width = be32(PHONE_WIDTH);\n\tcfg.height = be32(PHONE_HEIGHT);\n\tcfg.stride = be32(PHONE_WIDTH * 4);",
   "\tcfg.width = be32(PANEL_WIDTH);\n\tcfg.height = be32(PANEL_HEIGHT);\n\tcfg.stride = be32(PANEL_WIDTH * 4);"),
  ("xnuloader/loader.c",
   "\tSCREEN.width = PHONE_WIDTH;\n\tSCREEN.height = PHONE_HEIGHT;\n\tSCREEN.stride = PHONE_WIDTH * 4;",
   "\tSCREEN.width = PANEL_WIDTH;\n\tSCREEN.height = PANEL_HEIGHT;\n\tSCREEN.stride = PANEL_WIDTH * 4;"),
  ("xnuloader/loader.c",
   "\t*(volatile uint64_t *)(FW_CFG_BASE + 16) = __builtin_bswap64((uint64_t)(uintptr_t)&dma);\n\tif (dma.control != 0) {\n",
   "\t__asm__ volatile(\"dsb sy\" ::: \"memory\");\n"
   "\t*(volatile uint64_t *)(FW_CFG_BASE + 16) = __builtin_bswap64((uint64_t)(uintptr_t)&dma);\n"
   "\t__asm__ volatile(\"dsb sy\" ::: \"memory\");\n"
   "\tif (*(volatile uint32_t *)&dma.control != 0) {\n"),
]
for f, old, new in fixes:
    p = d / f; s = p.read_text()
    if new in s: continue
    if old not in s:
        print(f"[hackios] note: {f} differs from the pinned commit (fixed by hand or changed upstream): one fix left out"); continue
    p.write_text(s.replace(old, new, 1)); print(f"[hackios] fixed {f}")
PYFIX
}

# What iOS runs at boot (HackiOS's launchd job com.hakios.demo). QEMU's virtio network card (en0)
# has no IOKit object, so configd never sets it up by itself; HackiOS's net_test asks configd's
# IPConfiguration for DHCP on en0 (as their rc.jobs.net does) and QEMU's user network answers.
net_jobs() {
  local f="$DIR/userland/rc.jobs.ios-tools"
  if [ -n "${HACKIOS_JOBS:-}" ]; then echo "$HACKIOS_JOBS"; return; fi
  if [ "${HACKIOS_NET:-1}" = 0 ]; then echo rc.jobs; return; fi
  cat > "$f" <<'JOBS'
# written by ios-tools hackios.sh: DHCP on en0 (QEMU's network), wait for the address, show it
/redwood/bin/net_test dhcp en0 waitaddr en0 180 show
# keep the clock right (it is behind after a snapshot is resumed): the host's clock, else SNTP
/redwood/bin/timesync &
JOBS
  # the ephemeral rootful overlay (opt-in): writable ramfs unions over the system directories, so
  # files can be created in /Applications, /Library, ... (in memory). Runs before the jailbreak prep
  # so the overlay is in place first. HACKIOS_ROOTFUL_DIRS overrides the default set.
  if [ "${HACKIOS_ROOTFUL:-1}" != 0 ]; then
    printf '# ios-tools: ephemeral rootful overlay (writable ramfs union over the system dirs)\n' >> "$f"
    printf '/redwood/bin/rootful %s\n' "${HACKIOS_ROOTFUL_DIRS:-/Applications /Library /usr /bin /sbin}" >> "$f"
  fi
  if [ -d "$DIR/jb/root/var/jb" ]; then
    # the jailbreak, as HackiOS's rc.jobs.jb has it: the prefix's preparation once per boot (dpkg's
    # "firmware", Sileo registered with LaunchServices), then fresh package lists for Sileo and apt
    cat >> "$f" <<'JOBS'
/var/jb/bin/sh /var/jb/prep.sh
JOBS
    # ssh into iOS (opt-in): HACKIOS_SSH_KEY=<public key file> puts that key in /var/root/.ssh through
    # their build's ssh/ directory (with a host key made here; SHARE=1 images never carry them) and
    # starts the prefix's sshd; `run` forwards 127.0.0.1:${HACKIOS_SSH_PORT:-2222} to it. This is how
    # the home screen is reached and driven from the host: sbreload, rwtouch, the TrollStore log.
    if [ -n "${HACKIOS_SSH_KEY:-}" ] && [ -f "$HACKIOS_SSH_KEY" ]; then
      mkdir -p "$DIR/ssh" && cp -f "$HACKIOS_SSH_KEY" "$DIR/ssh/authorized_keys"
      [ -f "$DIR/ssh/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$DIR/ssh/ssh_host_ed25519_key"
    fi
    if [ -f "$DIR/ssh/authorized_keys" ] && [ -x "$DIR/jb/root/var/jb/usr/sbin/sshd" ]; then
      printf '%s\n' '/var/jb/usr/sbin/sshd -D -e -h /var/root/.ssh/ssh_host_ed25519_key -o UsePAM=no -o PasswordAuthentication=no -o PermitRootLogin=prohibit-password -o AuthorizedKeysFile=/var/root/.ssh/authorized_keys &' >> "$f"
    fi
    cat >> "$f" <<'JOBS'
/redwood/bin/net_test waitaddr en0 60 resolve apt.procurs.us
/var/jb/usr/bin/apt-get update
JOBS
    # TrollStore (ios-tools): install/refresh it via TrollHelper's root helper once iOS is up
    if [ -f "$DIR/jb/root/var/jb/usr/libexec/ios-tools/trollstore-boot.sh" ]; then
      printf '/var/jb/bin/sh /var/jb/usr/libexec/ios-tools/trollstore-boot.sh &\n' >> "$f"
    fi
  fi
  echo "$f"
}

# NewTerm (ios-tools): bundle HASHBANG's NewTerm 3 terminal into the jailbreak prefix, the way
# mk-jb.sh bundles Sileo -- unpack the rootless (/var/jb) deb into jb/root and pull its runtime
# dependencies (a shell, coreutils, ncurses terminfo, system-cmds) from Procursus that the bootstrap
# does not already carry, so a working terminal is on the home screen at first boot without Sileo
# (whose "firmware" resolver quirk blocks installing it on-device). NewTerm is Apache-2.0
# (github.com/hbang/NewTerm); its deb is fetched from Chariz (repo.chariz.com, the repo Sileo itself
# would use), or taken from $NEWTERM_DEB if that points at a local .deb. Never fatal: any failure
# just leaves NewTerm out, like the wallpaper. Returns 0 if NewTerm is present in the prefix, 1 if not.
PROCURSUS_MIRROR=https://apt.procurs.us
PROCURSUS_SUITE=1800
CHARIZ_REPO=https://repo.chariz.com
# extract a .deb's data tree into a root (dpkg-deb if present -- it is, in the Debian chroot -- else ar+tar)
deb_extract() {
  local deb="$1" dest="$2"
  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb -x "$deb" "$dest" && return 0
  fi
  local t; t=$(mktemp -d)
  ( cd "$t" && ar x "$deb" ) || { rm -rf "$t"; return 1; }
  local data; data=$(ls "$t"/data.tar.* 2>/dev/null | head -1) || { rm -rf "$t"; return 1; }
  case "$data" in
    *.xz)   xz -dc "$data"   | tar -x -C "$dest" ;;
    *.lzma) xz -dc "$data"   | tar -x -C "$dest" ;;
    *.zst)  zstd -dc "$data" | tar -x -C "$dest" ;;
    *.gz)   gzip -dc "$data" | tar -x -C "$dest" ;;
    *.bz2)  bzip2 -dc "$data"| tar -x -C "$dest" ;;
    *)      tar -xf "$data" -C "$dest" ;;
  esac
  local rc=$?; rm -rf "$t"; return $rc
}
# a field from a .deb's control
deb_field() { dpkg-deb -f "$1" "$2" 2>/dev/null; }
# append a "Status: install ok installed" stanza for a package to the prefix's dpkg database, so apt
# and Sileo see it installed (and do not offer to reinstall it) -- as mk-jb.sh does for Sileo/ElleKit
dpkg_record() { # dpkg_record STATUS_FILE PACKAGE VERSION [ARCH] [DEPENDS]
  local st="$1" pkg="$2" ver="$3" arch="${4:-iphoneos-arm64}" dep="${5:-}"
  grep -q "^Package: $pkg\$" "$st" 2>/dev/null && return 0
  { printf 'Package: %s\nStatus: install ok installed\nArchitecture: %s\nVersion: %s\n' "$pkg" "$arch" "$ver"
    [ -n "$dep" ] && printf 'Depends: %s\n' "$dep"
    printf '\n'; } >> "$st"
}
bundle_newterm() {
  local root="$DIR/jb/root"
  [ -d "$root/var/jb" ] || return 1
  local app="$root/var/jb/Applications/NewTerm.app"
  [ -f "$app/NewTerm" ] && return 0   # already bundled
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  # 1. obtain the NewTerm deb -- the bundled one (shipped next to this script, or $NEWTERM_DEB),
  #    else the arm64 (/var/jb) build from Chariz. The bundled deb makes the build self-contained
  #    (no network for it) and pins the exact tested build.
  local deb="" c
  for c in "${NEWTERM_DEB:-}" "$HERE"/ws.hbang.newterm3*.deb "$HERE"/newterm/ws.hbang.newterm3*.deb; do
    if [ -n "$c" ] && [ -f "$c" ]; then deb="$c"; break; fi
  done
  if [ -n "$deb" ]; then
    log "NewTerm: using bundled $deb"
  else
    log "NewTerm: resolving ws.hbang.newterm3 (arm64) from $CHARIZ_REPO"
    if ! curl -fsSL --retry 3 -o "$tmp/ch.xz" "$CHARIZ_REPO/Packages.xz"; then
      log "NewTerm: could not fetch the Chariz package index - left out"; return 1
    fi
    local fn
    fn=$(xz -dc "$tmp/ch.xz" | python3 -c '
import sys
cur={}; best=None
def flush():
    global best
    if cur.get("Package")=="ws.hbang.newterm3" and cur.get("Architecture")=="iphoneos-arm64":
        best=cur.get("Filename")
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line: flush(); cur={}; continue
    if line[:1] in " \t": continue
    k,_,v=line.partition(":"); cur[k.strip()]=v.strip()
flush()
print(best or "")')
    if [ -z "$fn" ]; then log "NewTerm: not in the Chariz index - left out"; return 1; fi
    if ! curl -fsSL --retry 3 -o "$tmp/newterm.deb" "$CHARIZ_REPO/$fn"; then
      log "NewTerm: deb download failed - left out"; return 1
    fi
    deb="$tmp/newterm.deb"
  fi
  # it must be the rootless (/var/jb) build, or it would scatter into read-only system paths
  mkdir -p "$tmp/nt"
  deb_extract "$deb" "$tmp/nt" || { log "NewTerm: could not read the deb - left out"; return 1; }
  if [ ! -d "$tmp/nt/var/jb/Applications/NewTerm.app" ]; then
    log "NewTerm: this deb is not the rootless (/var/jb) build - left out (need the arm64 one)"; return 1
  fi
  local st="$root/var/jb/Library/dpkg/status"
  # 2. runtime dependencies from Procursus: resolve NewTerm's Depends closure, minus whatever the
  #    bootstrap already installed (its dpkg status), and download the missing ones
  log "NewTerm: resolving runtime dependencies from Procursus (suite $PROCURSUS_SUITE)"
  local pidx="$tmp/proc.xz"
  if curl -fsSL --retry 3 -o "$pidx" "$PROCURSUS_MIRROR/dists/$PROCURSUS_SUITE/main/binary-iphoneos-arm64/Packages.xz"; then
    xz -dc "$pidx" | python3 -c '
import sys
status_path=sys.argv[1]
# stdin: Procursus Packages (plain). argv[1]: prefix dpkg status (already-installed).
pkgs={}; provides={}
cur={}
def flush(d):
    n=d.get("Package")
    if not n: return
    pkgs[n]=d
    for pv in (d.get("Provides","") or "").replace(" ","").split(","):
        pv=pv.split("(")[0]
        if pv: provides.setdefault(pv,n)
for line in sys.stdin:
    line=line.rstrip("\n")
    if not line: flush(cur); cur={}; continue
    if line[:1] in " \t": continue
    k,_,v=line.partition(":"); cur[k.strip()]=v.strip()
flush(cur)
# already installed (names + their Provides) from the prefix status
have=set()
try:
    d={}
    for line in open(status_path,encoding="utf-8",errors="replace"):
        line=line.rstrip("\n")
        if not line:
            n=d.get("Package")
            if n and "install ok installed" in d.get("Status",""):
                have.add(n)
                for pv in (d.get("Provides","") or "").replace(" ","").split(","):
                    pv=pv.split("(")[0]
                    if pv: have.add(pv)
            d={}; continue
        if line[:1] in " \t": continue
        k,_,v=line.partition(":"); d[k.strip()]=v.strip()
except FileNotFoundError:
    pass
def dep_names(s):
    out=[]
    for clause in (s or "").split(","):
        clause=clause.strip()
        if not clause: continue
        # first alternative that exists as a real package or a provider
        for alt in clause.split("|"):
            name=alt.strip().split(" ")[0].split("(")[0].strip()
            if not name: continue
            if name in pkgs or name in provides: out.append(name); break
        else:
            name=clause.split("|")[0].strip().split(" ")[0].split("(")[0].strip()
            if name: out.append(name)
    return out
# NewTerm 3 needs: a shell, coreutils, ncurses (terminfo), system-cmds. Seed concretely so the
# shell choice is zsh+bash and ncurses pulls the terminfo data too.
seed=["coreutils","system-cmds","zsh","bash","ncurses-bin","ncurses-term"]
if "ncurses" in provides: seed.append(provides["ncurses"])   # libncursesw6
want=[]; seen=set()
def resolve(name):
    if name in seen: return
    seen.add(name)
    real=name if name in pkgs else provides.get(name)
    if not real or real in have or real not in pkgs: return
    # recurse into its deps first, so dependencies are unpacked before dependents
    for dn in dep_names(pkgs[real].get("Depends","")):
        resolve(dn)
    if real not in want:
        want.append(real)
for s in seed: resolve(s)
for n in want:
    d=pkgs[n]
    print("\t".join([d.get("Filename",""), n, d.get("Version",""),
                     d.get("Architecture","iphoneos-arm64"), d.get("Depends","")]))
' "$st" > "$tmp/deps.tsv" || true
    local n=0
    while IFS=$'\t' read -r fn pkg ver arch dep; do
      [ -n "$fn" ] || continue
      if curl -fsSL --retry 3 -o "$tmp/dep.deb" "$PROCURSUS_MIRROR/$fn"; then
        if deb_extract "$tmp/dep.deb" "$root"; then
          dpkg_record "$st" "$pkg" "$ver" "$arch" "$dep"; n=$((n+1))
        fi
      else
        log "NewTerm: dependency $pkg could not be downloaded (continuing)"
      fi
    done < "$tmp/deps.tsv"
    log "NewTerm: installed $n dependency package(s) the bootstrap lacked"
  else
    log "NewTerm: Procursus index unavailable - installing the app without extra deps (the bootstrap's shell is used)"
  fi
  # 3. lay NewTerm.app into the prefix (it already targets /var/jb) and record it in dpkg
  cp -a "$tmp/nt/." "$root/"
  local ntver; ntver=$(deb_field "$deb" Version); [ -n "$ntver" ] || ntver="3.0~beta1"
  local ntdep; ntdep=$(deb_field "$deb" Depends)
  dpkg_record "$st" ws.hbang.newterm3 "$ntver" iphoneos-arm64 "$ntdep"
  log "NewTerm: bundled ws.hbang.newterm3 $ntver into the prefix (home-screen app)"
  return 0
}

# TrollStore (ios-tools): opa334's TrollStore, installed the way it is on a jailbroken iOS 16 device
# -- through TrollHelper (com.opa334.trollstorehelper, the rootless /var/jb deb from TrollStore's own
# GitHub releases), whose bundled root helper `trollstorehelper install-trollstore TrollStore.tar`
# puts TrollStore.app into /var/containers/Bundle/Application and registers it as a system app.
# At build time both release files are downloaded (never committed / redistributed by ios-tools)
# and laid into the jailbreak prefix with a small boot script; at boot the script waits for iOS to
# come up, installs TrollStore if it is not there (or refreshes its registrations if it is), then
# lets TrollStore install the .tipa files staged in $HACKIOS_TIPAS (default: the ios-tools Hello
# World app). TrollHelper also sits on the home screen ("TrollStore Helper") to (re)install by hand.
# Never fatal: any failure just leaves TrollStore out. Returns 0 if it is staged, 1 if not.
TROLLSTORE_REPO=https://github.com/opa334/TrollStore
HELLO_TIPA_URL=https://github.com/legendarymsr/ios-tools/releases/download/hello-world-v1.1/HelloWorld.tipa
ts_fetch() { # ts_fetch ASSET DEST
  local base="$TROLLSTORE_REPO/releases/latest/download"
  [ -n "${TROLLSTORE_VERSION:-}" ] && base="$TROLLSTORE_REPO/releases/download/$TROLLSTORE_VERSION"
  curl -fsSL --retry 3 -o "$2" "$base/$1"
}
bundle_trollstore() {
  local root="$DIR/jb/root"
  [ -d "$root/var/jb" ] || return 1
  local share="$root/var/jb/usr/share/ios-tools" lib="$root/var/jb/usr/libexec/ios-tools"
  local tmp; tmp=$(mktemp -d)
  trap 'rm -rf "${tmp:-}"; trap - RETURN' RETURN
  # 1. TrollHelper (rootless deb) -> /var/jb/Applications/TrollStorePersistenceHelper.app
  if [ ! -x "$root/var/jb/Applications/TrollStorePersistenceHelper.app/trollstorehelper" ]; then
    local deb="${TROLLHELPER_DEB:-}"
    if [ -z "$deb" ] || [ ! -f "$deb" ]; then
      deb="$tmp/trollhelper.deb"; local v=latest
      log "TrollStore: fetching TrollHelper (iphoneos-arm64) from $TROLLSTORE_REPO releases (${TROLLSTORE_VERSION:-latest})"
      # the asset name carries the version: resolve it from the release's tag
      v=${TROLLSTORE_VERSION:-$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$TROLLSTORE_REPO/releases/latest" | sed 's#.*/tag/##')}
      [ -n "$v" ] && ts_fetch "com.opa334.trollstorehelper_${v}_iphoneos-arm64.deb" "$deb" \
        || { log "TrollStore: TrollHelper download failed - left out"; return 1; }
    fi
    mkdir -p "$tmp/th"
    deb_extract "$deb" "$tmp/th" || { log "TrollStore: could not read the TrollHelper deb - left out"; return 1; }
    [ -x "$tmp/th/var/jb/Applications/TrollStorePersistenceHelper.app/trollstorehelper" ] \
      || { log "TrollStore: not the rootless TrollHelper deb - left out"; return 1; }
    cp -a "$tmp/th/." "$root/"
    dpkg_record "$root/var/jb/Library/dpkg/status" com.opa334.trollstorehelper \
      "$(deb_field "$deb" Version || echo 0)" iphoneos-arm64
  fi
  # 2. TrollStore.tar (what install-trollstore unpacks)
  mkdir -p "$share/tipa" "$lib"
  if [ ! -s "$share/TrollStore.tar" ]; then
    if [ -n "${TROLLSTORE_TAR:-}" ] && [ -f "$TROLLSTORE_TAR" ]; then cp -f "$TROLLSTORE_TAR" "$share/TrollStore.tar"
    else
      log "TrollStore: fetching TrollStore.tar"
      ts_fetch TrollStore.tar "$share/TrollStore.tar" || { log "TrollStore: TrollStore.tar download failed - left out"; rm -f "$share/TrollStore.tar"; return 1; }
    fi
  fi
  # 2b. ldid (opa334's fork, AGPL-3.0, github.com/opa334/ldid): TrollStore signs apps with it and refuses
  # fakesigned .tipa files without it (trollstorehelper returns 173); the app downloads it on demand, the
  # boot script puts it in place instead
  if [ ! -s "$share/ldid" ]; then
    curl -fsSL --retry 3 -o "$share/ldid" https://github.com/opa334/ldid/releases/latest/download/ldid \
      && chmod 755 "$share/ldid" || { log "TrollStore: ldid download failed - .tipa installs may fail (173)"; rm -f "$share/ldid"; }
  fi
  # 3. the apps TrollStore installs at boot
  rm -f "$share/tipa/"*
  local s i=0
  for s in ${HACKIOS_TIPAS:-$HELLO_TIPA_URL}; do
    [ "$s" = none ] && break
    i=$((i+1)); local dst; dst="$share/tipa/$i-$(basename "${s%%\?*}")"
    case "$s" in
      http://*|https://*) curl -fsSL --retry 3 -o "$dst" "$s" || { log "TrollStore: could not fetch $s (skipped)"; rm -f "$dst"; } ;;
      *) cp -f "$s" "$dst" 2>/dev/null || log "TrollStore: $s not found (skipped)" ;;
    esac
  done
  # 4. the boot script (runs as root from the boot job list, in the background)
  cat > "$lib/trollstore-boot.sh" <<'TSBOOT'
#!/var/jb/bin/sh
# ios-tools: install TrollStore via TrollHelper's root helper, then the staged .tipa apps
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
H=/var/jb/Applications/TrollStorePersistenceHelper.app/trollstorehelper
S=/var/jb/usr/share/ios-tools
L=/var/tmp/ios-tools-trollstore.log
exec >>"$L" 2>&1
echo "== $(date) trollstore-boot"
ts_app() { ls -d /var/containers/Bundle/Application/*/TrollStore.app 2>/dev/null | head -1; }
# LaunchServices must be up before anything can be registered: retry for ~10 minutes
n=0
while [ $n -lt 40 ]; do
  if [ -n "$(ts_app)" ]; then "$H" refresh-all && break
  else "$H" install-trollstore "$S/TrollStore.tar" && [ -n "$(ts_app)" ] && break; fi
  n=$((n+1)); sleep 15
done
[ -n "$(ts_app)" ] || { echo "TrollStore not installed"; exit 1; }
echo "TrollStore at $(ts_app)"
[ -f "$S/ldid" ] && [ ! -f "$(ts_app)/ldid" ] && cp "$S/ldid" "$(ts_app)/ldid" && chmod 755 "$(ts_app)/ldid" && echo opa334 > "$(ts_app)/ldid.version"
for t in "$S"/tipa/*; do
  [ -f "$t" ] || continue
  echo "installing $t"; "$H" install "$t" || echo "install failed: $t"
done
echo "== done"
TSBOOT
  chmod 0755 "$lib/trollstore-boot.sh"
  log "TrollStore: TrollHelper + TrollStore.tar staged in the prefix ($i app(s) to install at boot)"
  return 0
}
unbundle_trollstore() {
  local root="$DIR/jb/root"
  rm -rf "$root/var/jb/Applications/TrollStorePersistenceHelper.app" "$root/var/jb/usr/share/ios-tools" \
         "$root/var/jb/usr/libexec/ios-tools"
  sed -i '/^Package: com\.opa334\.trollstorehelper$/,/^$/d' "$root/var/jb/Library/dpkg/status" 2>/dev/null || true
}

do_build() {
  credit
  [ -f "$DIR/userland/build.sh" ] && [ -f "$DIR/sysimage/fetch.sh" ] || die "not set up yet (or the old layout) - run step 2 first"
  command -v 7z >/dev/null || die "7z missing - run step 2 first"
  cd "$DIR"
  if [ ! -f sysimage/.done-rootfs ] || [ ! -f sysimage/.done-cryptex ] || [ ! -f sysimage/.done-cryptex-app ]; then
    log "downloading iOS 16.5 (20F66) from Apple's CDN and extracting it (7.4 GB, resumes if interrupted)"
    bash sysimage/fetch.sh
  else
    log "iOS 16.5 files already extracted"
  fi
  fix_checkout
  # their xnuloader/mkidentity.sh builds lzfse with `make lzfse`, a target lzfse's Makefile does not
  # have; build it with the default target into the place mkidentity.sh looks first
  if ! command -v lzfse >/dev/null && [ ! -x "$DIR/xnu-deps/host/bin/lzfse" ]; then
    log "building lzfse (BSD, github.com/lzfse/lzfse) for the loader's device tree"
    local lz; lz=$(mktemp -d)
    git clone -q --depth 1 https://github.com/lzfse/lzfse "$lz/lzfse" && make -s -C "$lz/lzfse" >/dev/null \
      && mkdir -p "$DIR/xnu-deps/host/bin" && cp "$lz/lzfse/build/bin/lzfse" "$DIR/xnu-deps/host/bin/" \
      || log "WARNING: lzfse did not build"
    rm -rf "$lz"
  fi
  log "building HackiOS's loader (xnuloader/loader.efi)"
  bash xnuloader/build.sh >/dev/null || die "the loader did not build (clang/lld from step 2?)"
  # the jailbreak, HackiOS's own: tools/mk-jb.sh fetches the Procursus rootless bootstrap, Sileo and
  # ElleKit into jb/, and their build puts it into the system image (/var/jb at run time)
  local jb=off system=
  if [ "${HACKIOS_JB:-1}" != 0 ]; then
    if [ ! -d jb/root/var/jb ]; then
      log "jailbreak: HackiOS's tools/mk-jb.sh (Procursus rootless bootstrap, Sileo, ElleKit)"
      bash tools/mk-jb.sh | tail -2 || die "tools/mk-jb.sh failed (see above)"
    fi
    jb=on
  elif [ -d jb/root ]; then
    log "jailbreak left out (HACKIOS_JB=0)"; rm -rf jb/root
  fi
  # NewTerm (ios-tools): a terminal app on the home screen, bundled into the jailbreak prefix (needs
  # the jailbreak). HACKIOS_NEWTERM=0 leaves it out. A terminal is only meaningful with the prefix's
  # tools, so it rides on HACKIOS_JB.
  local want_nt=off
  if [ "$jb" = on ] && [ "${HACKIOS_NEWTERM:-1}" != 0 ]; then
    if bundle_newterm; then want_nt=on; else log "NewTerm: not bundled (see above)"; fi
  elif [ -d jb/root/var/jb/Applications/NewTerm.app ]; then
    log "NewTerm left out (HACKIOS_NEWTERM=0 or no jailbreak): removing it from the prefix"
    rm -rf jb/root/var/jb/Applications/NewTerm.app
    sed -i '/^Package: ws\.hbang\.newterm3$/,/^$/d' jb/root/var/jb/Library/dpkg/status 2>/dev/null || true
  fi
  # TrollStore (ios-tools): staged into the jailbreak prefix, installed at boot. HACKIOS_TROLLSTORE=0
  # leaves it out.
  local want_ts=off
  if [ "$jb" = on ] && [ "${HACKIOS_TROLLSTORE:-1}" != 0 ]; then
    if bundle_trollstore; then want_ts="on:$(ls jb/root/var/jb/usr/share/ios-tools/tipa 2>/dev/null | tr '\n' ' ')"
    else log "TrollStore: not bundled (see above)"; unbundle_trollstore; fi
  elif [ -d jb/root/var/jb/usr/share/ios-tools ]; then
    log "TrollStore left out (HACKIOS_TROLLSTORE=0 or no jailbreak): removing it from the prefix"
    unbundle_trollstore
  fi
  if [ "$(cat userland/.ios-tools-trollstore 2>/dev/null || echo off)" != "$want_ts" ]; then
    system=1; log "the system image is remade ($([ "$want_ts" = off ] && echo without || echo with) TrollStore)"
  fi
  # their build remakes system.apfs only when its own inputs change: with the jailbreak (or NewTerm)
  # added or taken out it has to be remade too (userland/.ios-tools-jb / .ios-tools-newterm remember
  # what the image has)
  if [ "$(cat userland/.ios-tools-jb 2>/dev/null || echo off)" != "$jb" ]; then
    system=1; log "the system image is remade ($([ $jb = on ] && echo with || echo without) the jailbreak)"
  fi
  if [ "$(cat userland/.ios-tools-newterm 2>/dev/null || echo off)" != "$want_nt" ]; then
    system=1; log "the system image is remade ($([ $want_nt = on ] && echo with || echo without) NewTerm)"
  fi
  # iOS's default wallpaper (ios-tools): the stock one (identifier 7400) is GPU-composited and comes up
  # a blank white screen without a GPU under QEMU; the "Stripe Black" (7395) is procedural, so the
  # software renderer draws it -- a black background with a thin diagonal stripe. HACKIOS_WALLPAPER=0
  # keeps iOS's stock default. A photo cannot be a wallpaper here: every wallpaper type iOS 16.5 ships
  # (Bokeh, the stripes, LayeredAnimation) is procedural, and a raster "poster" needs the GPU.
  local want_wall=stripe-black; [ "${HACKIOS_WALLPAPER:-1}" = 0 ] && want_wall=stock
  local dwp=sysimage/rootfs/Library/Wallpaper/DefaultWallpapers~iphone.plist
  if [ -f "$dwp" ]; then
    [ -f "$dwp.ios-tools-orig" ] || cp "$dwp" "$dwp.ios-tools-orig"
    python3 - "$dwp" "$want_wall" <<'PYWALL'
import plistlib, sys
f, want = sys.argv[1], sys.argv[2]
if want == "stripe-black":
    d = plistlib.load(open(f, "rb"))
    d["default"] = {"wallpaperIdentifier": 7395, "collectionIdentifier": "2939274C-F444-4AA8-806E-6E3FAFBA79B1"}
else:
    d = plistlib.load(open(f + ".ios-tools-orig", "rb"))   # iOS's own default again
plistlib.dump(d, open(f, "wb"))
PYWALL
    if [ "$(cat userland/.ios-tools-wallpaper 2>/dev/null || echo stock)" != "$want_wall" ]; then
      system=1; log "wallpaper: $want_wall (the system image is remade)"
    fi
  fi
  # ours, into /redwood/bin through their build's EXTRA: timesync (keeps iOS's clock right after a
  # snapshot is resumed, timesync/timesync.c) and, unless HACKIOS_ROOTFUL=0, the ephemeral rootful
  # overlay helper (rootful/rootful.c). EXTRA copies by file name, so they are staged under their names.
  local xdir="$DIR/userland/obj/ios-tools" extra="" ts rf
  rm -rf "$xdir"; mkdir -p "$xdir"
  for ts in "$HERE/timesync-arm64" "$HERE/timesync/timesync-arm64"; do
    if [ -f "$ts" ]; then cp -f "$ts" "$xdir/timesync"; extra="$extra $xdir/timesync"; break; fi
  done
  if [ "${HACKIOS_ROOTFUL:-1}" != 0 ]; then
    for rf in "$HERE/rootful-arm64" "$HERE/rootful/rootful-arm64"; do
      if [ -f "$rf" ]; then cp -f "$rf" "$xdir/rootful"; extra="$extra $xdir/rootful"; break; fi
    done
    [ -f "$xdir/rootful" ] || log "rootful: rootful-arm64 not found - overlay left out"
  fi
  # iOS's time zone: Android's (the launcher passes it), checked against the zones iOS has
  if [ -n "${HACKIOS_TZ:-}" ] && [ ! -e "sysimage/rootfs/usr/share/zoneinfo.default/$HACKIOS_TZ" ]; then
    log "time zone $HACKIOS_TZ is not one iOS has: UTC"; unset HACKIOS_TZ
  fi
  if [ -n "${HACKIOS_TZ:-}" ]; then export HACKIOS_TZ; log "time zone: $HACKIOS_TZ"; fi
  local jobs; jobs=$(net_jobs)
  log "building the images (HackiOS's prebuilt kernel and programs; boot jobs: $(basename "$jobs"))"
  ( cd userland && PREBUILT=1 REST=1 RC_JOBS="$jobs" SYSTEM=$system EXTRA="${extra# }" \
      bash build.sh ) || die "their image build failed (see above)"
  [ -f userland/root.apfs ] && [ -f userland/system.apfs ] && [ -f xnuloader/loader.efi ] \
    || die "the images were not built (see above)"
  echo "$jb" > userland/.ios-tools-jb
  echo "$want_nt" > userland/.ios-tools-newterm
  echo "$want_ts" > userland/.ios-tools-trollstore
  echo "${want_wall:-stock}" > userland/.ios-tools-wallpaper
  log "images: root.apfs $(du -h userland/root.apfs | cut -f1), system.apfs $(du -h userland/system.apfs | cut -f1)"
  log "build done - next: step 4 (boot)"
}

# Rendering resolution (ios-tools): HACKIOS_FBSCALE=2 draws the UI at 2 pixels a point (750x1624) instead
# of the native 3 (1125x2436) and the kernel enlarges it to the panel -- fewer pixels for the CPU to draw.
# In a controlled test it did NOT change the frame rate (both ~10 fps: the panel scaling, not the UI
# rendering, is the limit), so the default is native 3. It lowers CPU load per frame; a little softer.
fbscale_arg() {
  local fb="${HACKIOS_FBSCALE:-3}"
  case "$fb" in 0|3) ;; *) printf 'fbscale=%s' "$fb" ;; esac
}

# ---- snapshots ------------------------------------------------------------------------------------
# A snapshot is QEMU's saved VM state (a migration stream in a file): RAM, CPUs and devices. Resuming it
# needs the same QEMU, devices, memory and images, so it is kept with a key of all of those and only
# used when the key still matches. QEMU 8.2+ is needed: older ones do not save the ramfb display.
SNAP_PORT=4445
snap_file() { echo "$DIR/qemu/hackios.snapshot"; }
qemu_ok_for_snapshots() {
  local v; v=$(qemu-system-aarch64 --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  [ -n "$v" ] && [ "$(printf '%s\n8.2\n' "$v" | sort -V | head -1)" = 8.2 ]
}
snap_key() {
  ( cd "$DIR" && qemu-system-aarch64 --version | head -1
    echo "smp=${HACKIOS_SMP:-4} ram=${HACKIOS_RAM_GB:-7} net=${HACKIOS_NET:-1} fbscale=${HACKIOS_FBSCALE:-3} cmdline=${HACKIOS_CMDLINE:-}"
    stat -c '%n %s %Y' userland/root.apfs userland/system.apfs xnuloader/loader.efi prebuilt/mach.development.bcm2837 2>/dev/null
  ) | sha256sum | cut -d' ' -f1
}
# qmp COMMAND-JSON...: send QMP commands to the running QEMU, print each answer; `wait-migration`
# polls query-migrate until it ends and prints its final status
qmp() {
  python3 - "$SNAP_PORT" "$@" <<'PYQMP'
import json, socket, sys, time
port, cmds = int(sys.argv[1]), sys.argv[2:]
deadline = time.time() + 120
while True:
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=5); break
    except OSError:
        if time.time() > deadline: print("no-qmp"); sys.exit(1)
        time.sleep(1)
f = s.makefile("rw")
def call(cmd):
    f.write(json.dumps(cmd) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
json.loads(f.readline()); call({"execute": "qmp_capabilities"})
for c in cmds:
    if c == "wait-migration":
        last = None
        while True:
            st = call({"execute": "query-migrate"}).get("return", {})
            status = st.get("status", "none")
            mb = st.get("ram", {}).get("transferred", 0) >> 20
            if status != last or int(time.time()) % 15 == 0:
                print(f"migration: {status}, {mb} MB", flush=True); last = status
            if status in ("completed", "failed", "cancelled"):
                if status == "failed": print("error:", st.get("error-desc", "?"))
                print("final:", status); break
            time.sleep(1)
    else:
        print(json.dumps(call(json.loads(c))))
PYQMP
}

do_run() {
  credit
  cd "$DIR" 2>/dev/null || die "not set up yet - run step 2 first"
  [ -f userland/root.apfs ] && [ -f userland/system.apfs ] || die "no images yet - run step 3 first"
  [ -z "$(qemu_pids)" ] || die "HackiOS is already running (Power off VM stops it)"
  pgrep -f 'qemu-system-aarch64.*-M t8030' >/dev/null && die "another iOS VM (qemu-t8030) is running on the same VNC port - stop it first"
  local avail; avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
  if [ "${avail:-0}" -lt 3000 ]; then
    log "WARNING: only ${avail} MB of memory available; HackiOS wants about 2.5-3 GB. Close other apps if Android kills it."
  fi
  fix_checkout >/dev/null
  local secs="${HACKIOS_SECS:-7200}"
  local net=1; [ "${HACKIOS_NET:-1}" = 0 ] && net=0
  local extra=() snap; snap=$(snap_file)
  if qemu_ok_for_snapshots; then
    # the same devices whether or not this run is saved later: snapshots need them alike
    export QEMU_ESP_RW= QEMU_ESP_RO=1 QEMU_SOUND=0
    if [ "${HACKIOS_SNAPSHOT:-1}" != 0 ] && [ -f "$snap" ] && [ "$(cat "$snap.key" 2>/dev/null)" = "$(snap_key)" ]; then
      log "resuming the saved iOS (snapshot of $(date -r "$snap" '+%Y-%m-%d %H:%M'), $(du -h "$snap" | cut -f1)) instead of booting"
      extra=(-incoming defer)
      # the snapshot was taken with the VM paused, so it loads paused: cont starts it
      ( out=$(qmp "{\"execute\": \"migrate-incoming\", \"arguments\": {\"uri\": \"file:$snap\"}}" wait-migration '{"execute": "cont"}' 2>&1)
        if echo "$out" | grep -q "final: completed"; then
          log "snapshot loaded: iOS is running (its clock is behind by the time it was off)"
        else
          log "the snapshot could not be loaded: $(echo "$out" | grep -E 'error|final' | head -2 | tr '\n' ' ')"
          touch "$DIR/qemu/.snapshot-failed"; qmp '{"execute": "quit"}' >/dev/null 2>&1
        fi ) &
    elif [ -f "$snap" ] && [ "${HACKIOS_SNAPSHOT:-1}" != 0 ]; then
      log "the saved snapshot is from other images or settings: booting afresh (save again once on the home screen)"
    fi
  else
    if [ -f "$snap" ]; then log "snapshots need QEMU 8.2 or newer (this is $(qemu-system-aarch64 --version | head -1 | awk '{print $4}')): booting afresh"; fi
  fi
  if [ ${#extra[@]} = 0 ]; then
    log "booting iOS 16.5 under QEMU virt (TCG, ${HACKIOS_SMP:-4} vCPUs, ${HACKIOS_RAM_GB:-7} GB guest RAM, network=$net, session ${secs} s)"
    log "display: VNC 127.0.0.1:$((5900 + ${HACKIOS_VNC:-0})) - the lock screen takes several minutes on a phone"
    if qemu_ok_for_snapshots; then log "tip: once iOS is on the home screen, tap \"Save iOS snapshot\" so the next boot takes seconds"; fi
  fi
  log "touch: the pointer with the button held is a finger; swipe up from the bottom edge = home/unlock, from the left edge = back"
  rm -f "$DIR/qemu/.snapshot-failed"
  # the host's clock for timesync in iOS: a connection to 10.0.2.100:37 gets `date +%s.%N`
  export QEMU_NET_EXTRA='guestfwd=tcp:10.0.2.100:37-cmd:date +%s.%N'
  if [ -f "$DIR/ssh/authorized_keys" ]; then
    QEMU_NET_EXTRA="$QEMU_NET_EXTRA,hostfwd=tcp:127.0.0.1:${HACKIOS_SSH_PORT:-2222}-:22"
    log "ssh: 127.0.0.1:${HACKIOS_SSH_PORT:-2222} -> iOS :22 (root, the key from HACKIOS_SSH_KEY)"
  fi
  QEMU_FORCE=1 QEMU_NET=$([ "$net" = 1 ] && echo 1 || echo) QEMU_SMP="${HACKIOS_SMP:-4}" \
    QEMU_RAM_GB="${HACKIOS_RAM_GB:-7}" QEMU_EFI="$EFI_CODE" QEMU_VARS="$EFI_VARS" \
    CMDLINE="cpus=${HACKIOS_SMP:-4} $(fbscale_arg) ${HACKIOS_CMDLINE:-}" \
    bash qemu/run-ios.sh "$secs" -display vnc=127.0.0.1:"${HACKIOS_VNC:-0}" "${extra[@]}" || true
  wait
  if [ -f "$DIR/qemu/.snapshot-failed" ]; then
    rm -f "$DIR/qemu/.snapshot-failed" "$snap" "$snap.key"
    log "snapshot deleted; booting afresh"
    HACKIOS_SNAPSHOT=0 do_run
  fi
}

do_save() {
  credit
  [ -n "$(qemu_pids)" ] || die "HackiOS is not running - boot it (step 4) and wait for the home screen first"
  qemu_ok_for_snapshots || die "snapshots need QEMU 8.2 or newer; this is $(qemu-system-aarch64 --version | head -1 | awk '{print $4}')"
  ps -o args= -p "$(qemu_pids | head -1)" | grep -q 'fat:esp' \
    || die "this QEMU was started before snapshot support: Power off, boot again (step 4), then save"
  local snap; snap=$(snap_file)
  log "saving iOS to $snap (iOS pauses for this; a few GB)"
  local t0; t0=$(date +%s)
  rm -f "$snap.part"
  local out; out=$(qmp '{"execute": "stop"}' \
    "{\"execute\": \"migrate\", \"arguments\": {\"uri\": \"file:$snap.part\"}}" wait-migration '{"execute": "cont"}' 2>&1)
  if echo "$out" | grep -q "final: completed"; then
    mv -f "$snap.part" "$snap" && snap_key > "$snap.key"
    log "saved in $(( $(date +%s) - t0 )) s, $(du -h "$snap" | cut -f1); iOS keeps running. The next boot (step 4) resumes from here."
  else
    rm -f "$snap.part"
    die "saving failed: $(echo "$out" | grep -E 'error|final|desc' | head -3 | tr '\n' ' ')"
  fi
}

do_forget() {
  rm -f "$(snap_file)" "$(snap_file).key" "$(snap_file).part"
  log "snapshot deleted: the next boot starts afresh"
}

do_stop() {
  if [ -z "$(qemu_pids)" ]; then log "HackiOS is not running"; return 0; fi
  [ -x "$DIR/qemu/stop.sh" ] && bash "$DIR/qemu/stop.sh" || true
  local i; for i in $(seq 1 10); do [ -z "$(qemu_pids)" ] && break; sleep 1; done
  if [ -n "$(qemu_pids)" ]; then kill $(qemu_pids) 2>/dev/null || true; sleep 2; kill -9 $(qemu_pids) 2>/dev/null || true; fi
  log "HackiOS stopped"
}

do_status() {
  credit
  [ -d "$DIR/.git" ] && log "installed: kernel repo $(git -C "$DIR" rev-parse --short HEAD), userland repo $(git --git-dir="$DIR/.userland.git" rev-parse --short HEAD 2>/dev/null || echo '?')" || log "not installed (step 2)"
  [ -f "$DIR/sysimage/.done-cryptex-app" ] && log "iOS 16.5 files: extracted" || log "iOS 16.5 files: not yet (step 3)"
  [ -f "$DIR/userland/system.apfs" ] && log "images: built" || log "images: not yet (step 3)"
  [ -f "$(snap_file)" ] && log "snapshot: saved $(date -r "$(snap_file)" '+%Y-%m-%d %H:%M'), $(du -h "$(snap_file)" | cut -f1)" || log "snapshot: none"
  [ -n "$(qemu_pids)" ] && log "running (pid $(qemu_pids | tr '\n' ' '))" || log "not running"
}

case "${1:-status}" in
  setup) do_setup ;;
  build) do_build ;;
  run) do_run ;;
  save) do_save ;;
  forget) do_forget ;;
  stop) do_stop ;;
  status) do_status ;;
  *) die "usage: hackios.sh setup|build|run|save|forget|stop|status" ;;
esac
