#!/usr/bin/env bash
# hackios.sh -- run HackiOS (iOS 16.5 user space on Apple's open-source XNU kernel) in QEMU's
# `virt` machine inside this Debian chroot on the phone (launcher steps 2-4).
#
# HackiOS is by OOSEX GANG (@oodze, @netusd, @wannqn, @hxfuxyyXD):
#   https://github.com/oosexgang  ·  https://hackios-web.vercel.app  ·  https://t.me/oosexgangdevs
# hackios-xnu-kernel is APSL 2.0, hackios-xnu-userland is MIT. Nothing of theirs is copied into
# ios-tools: this script clones their repositories at the commits pinned below and runs their own
# scripts. HackiOS is not affiliated with, authorised or endorsed by Apple Inc.; no Apple files are
# shipped -- their ios165/fetch.sh downloads iOS 16.5 from Apple's CDN onto this phone.
#
#   hackios.sh setup    packages, 7-Zip 24.09 (APFS needs 7-Zip 23+), both HackiOS repositories
#   hackios.sh build    download iOS 16.5 (7.4 GB, resumable), build HackiOS's loader and the
#                       images root.apfs + system.apfs (HackiOS's prebuilt kernel and programs)
#   hackios.sh run      boot it: QEMU virt, display on VNC 127.0.0.1:5900, network on (QEMU_NET=1)
#   hackios.sh stop     stop that QEMU
#   hackios.sh status   what is installed / built / running
#
# env: HACKIOS_DIR (default /root/hackios), HACKIOS_REF=latest (track main instead of the pins),
#      HACKIOS_SECS (session length, default 7200: the kernel returns to the loader after it),
#      HACKIOS_SMP (vCPUs, default 4), HACKIOS_RAM_GB (guest RAM, default 7: HackiOS's layout
#      puts the 2.5 GB system image high in RAM; the guest RAM is a file mapping, so the phone
#      itself needs about 2.5-3 GB free), HACKIOS_NET=0 (no network; takes effect at the next build),
#      HACKIOS_JOBS=<file> (the job list iOS runs at boot instead of ours; see net_jobs below).
set -euo pipefail
DIR="${HACKIOS_DIR:-/root/hackios}"
KERNEL_URL=https://github.com/oosexgang/hackios-xnu-kernel.git
USERLAND_URL=https://github.com/oosexgang/hackios-xnu-userland.git
KERNEL_PIN=8e61187098f2c26c5daee8f9f72b6416aa64b9ab     # 2026-10-22 "Add LICENSE"
USERLAND_PIN=a79ff0772a3454fd1ef127e181e5b3bce6c9ce18   # 2026-10-22
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
    clang lld qemu-system-arm qemu-efi-aarch64 qemu-utils procps >/dev/null || die "apt-get install failed"
  qemu-system-aarch64 -cpu help 2>/dev/null | grep -qw cortex-a76 \
    || die "this QEMU ($(qemu-system-aarch64 --version | head -1)) has no cortex-a76 CPU; HackiOS needs QEMU 7.1+"
  [ -f "$EFI_CODE" ] && [ -f "$EFI_VARS" ] || die "UEFI firmware missing ($EFI_CODE)"
  install_7zip

  if [ ! -d "$DIR/.git" ]; then
    log "cloning hackios-xnu-kernel into $DIR"
    git init -q "$DIR" && git -C "$DIR" remote add origin "$KERNEL_URL"
  fi
  checkout "$DIR" "$KERNEL_URL" "$KERNEL_PIN"
  # HackiOS's own setup clones hackios-xnu-userland into the same tree (git dir .userland.git)
  ( cd "$DIR" && USERLAND_URL="$USERLAND_URL" bash common/setup.sh ) | grep -E '^setup:|missing' || true
  [ -d "$DIR/.userland.git" ] || die "common/setup.sh did not check out hackios-xnu-userland"
  if [ "${HACKIOS_REF:-pinned}" = latest ]; then
    git --git-dir="$DIR/.userland.git" --work-tree="$DIR" pull -q --ff-only || true
  else
    # a plain checkout keeps setup.sh's skip-worktree marks, so the kernel repository's own
    # README.md, LICENSE and .gitignore in the shared tree are left alone
    git --git-dir="$DIR/.userland.git" --work-tree="$DIR" -c advice.detachedHead=false \
      checkout -q "$USERLAND_PIN" 2>/dev/null \
      || log "WARNING: could not pin hackios-xnu-userland to ${USERLAND_PIN:0:7}; using what setup.sh checked out"
  fi
  log "kernel repo at $(git -C "$DIR" rev-parse --short HEAD), userland repo at $(git --git-dir="$DIR/.userland.git" rev-parse --short HEAD)"
  log "setup done - next: step 3 (download iOS 16.5 + build the images)"
}

# Fixes to HackiOS's checkout (pinned commits), each applied once; report them upstream:
#  - userland/build.sh copies obj/drawable_test, which prebuilt/userland does not have (PREBUILT=1 stops)
#  - userland/build.sh asks timedatectl for the time zone under set -e; without systemd (this chroot)
#    the build stops there without a message
#  - userland/mkjobs.py reuses the loop variable `name` for RWA_PACKED16, so the ~400 on-demand iOS
#    jobs (REST=1: configd, mDNSResponder, trustd, nsurlsessiond, ...) all overwrite one file named
#    RWA_PACKED16 and none of them can start: no DHCP, no DNS, Safari "not connected to the Internet"
#  - xnuloader/loader.c reads back the fw_cfg DMA answer through a plain variable, so -O1 folds the
#    check and the prebuilt loader.efi always gives up on the 1125x2436 ramfb: black screen
fix_checkout() {
  python3 - "$DIR" <<'PYFIX'
import pathlib, sys
d = pathlib.Path(sys.argv[1])
fixes = [
  ("userland/build.sh",
   "\tcp obj/hello_dyn obj/svc_test obj/surf_test obj/drawable_test obj/rwtouch obj/mg_test root/bin/\n",
   "\tfor t in hello_dyn svc_test surf_test drawable_test rwtouch mg_test; do [ -f obj/$t ] && cp obj/$t root/bin/ || true; done\n"),
  ("userland/build.sh",
   "zone=$(timedatectl show -p Timezone --value 2>/dev/null); ",
   "zone=$(timedatectl show -p Timezone --value 2>/dev/null || true); "),
  ("userland/mkjobs.py",
   "        for name in ('RWA_PACKED16',):\n            if os.environ.get(name):\n"
   "                job.setdefault('EnvironmentVariables', {})[name] = os.environ[name]\n        if label in oslog:",
   "        for var in ('RWA_PACKED16',):\n            if os.environ.get(var):\n"
   "                job.setdefault('EnvironmentVariables', {})[var] = os.environ[var]\n        if label in oslog:"),
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

# What iOS runs at boot (HackiOS's launchd job com.redwood.demo). QEMU's virtio network card (en0)
# has no IOKit object, so configd never sets it up by itself; HackiOS's net_test asks configd's
# IPConfiguration for DHCP on en0 (as their rc.jobs.net does) and QEMU's user network answers.
net_jobs() {
  local f="$DIR/userland/rc.jobs.ios-tools"
  if [ -n "${HACKIOS_JOBS:-}" ]; then echo "$HACKIOS_JOBS"; return; fi
  if [ "${HACKIOS_NET:-1}" = 0 ]; then echo rc.jobs; return; fi
  cat > "$f" <<'JOBS'
# written by ios-tools hackios.sh: DHCP on en0 (QEMU's network), wait for the address, show it
/redwood/bin/net_test dhcp en0 waitaddr en0 180 show
JOBS
  echo "$f"
}

do_build() {
  credit
  [ -f "$DIR/common/build.sh" ] && [ -d "$DIR/.userland.git" ] || die "not set up yet - run step 2 first"
  command -v 7z >/dev/null || die "7z missing - run step 2 first"
  cd "$DIR"
  if [ ! -f ios165/.done-rootfs ] || [ ! -f ios165/.done-cryptex ] || [ ! -f ios165/.done-cryptex-app ]; then
    log "downloading iOS 16.5 (20F66) from Apple's CDN and extracting it (7.4 GB, resumes if interrupted)"
    bash ios165/fetch.sh
  else
    log "iOS 16.5 files already extracted"
  fi
  fix_checkout
  log "building HackiOS's loader (xnuloader/loader.efi)"
  bash xnuloader/build.sh >/dev/null || die "the loader did not build (clang/lld from step 2?)"
  local jobs; jobs=$(net_jobs)
  log "building the images (HackiOS's prebuilt kernel and programs; boot jobs: $(basename "$jobs"))"
  SKIP="kernel loader boot" PREBUILT=1 RC_JOBS="$jobs" bash common/build.sh qemu-virt
  [ -f userland/root.apfs ] && [ -f userland/system.apfs ] && [ -f xnuloader/loader.efi ] \
    || die "the images were not built (see above)"
  log "images: root.apfs $(du -h userland/root.apfs | cut -f1), system.apfs $(du -h userland/system.apfs | cut -f1)"
  log "build done - next: step 4 (boot)"
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
  local secs="${HACKIOS_SECS:-7200}"
  local net=1; [ "${HACKIOS_NET:-1}" = 0 ] && net=0
  log "booting iOS 16.5 under QEMU virt (TCG, ${HACKIOS_SMP:-4} vCPUs, ${HACKIOS_RAM_GB:-7} GB guest RAM, network=$net, session ${secs} s)"
  log "display: VNC 127.0.0.1:5900 - the lock screen takes several minutes on a phone"
  log "touch: the pointer with the button held is a finger; swipe up from the bottom edge = home/unlock, from the left edge = back"
  QEMU_FORCE=1 QEMU_NET=$([ "$net" = 1 ] && echo 1 || echo) QEMU_SMP="${HACKIOS_SMP:-4}" \
    QEMU_RAM_GB="${HACKIOS_RAM_GB:-7}" QEMU_EFI="$EFI_CODE" QEMU_VARS="$EFI_VARS" \
    CMDLINE="cpus=${HACKIOS_SMP:-4} ${HACKIOS_CMDLINE:-}" \
    bash qemu/run-ios.sh "$secs" -display vnc=127.0.0.1:0
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
  [ -f "$DIR/ios165/.done-cryptex-app" ] && log "iOS 16.5 files: extracted" || log "iOS 16.5 files: not yet (step 3)"
  [ -f "$DIR/userland/system.apfs" ] && log "images: built" || log "images: not yet (step 3)"
  [ -n "$(qemu_pids)" ] && log "running (pid $(qemu_pids | tr '\n' ' '))" || log "not running"
}

case "${1:-status}" in
  setup) do_setup ;;
  build) do_build ;;
  run) do_run ;;
  stop) do_stop ;;
  status) do_status ;;
  *) die "usage: hackios.sh setup|build|run|stop|status" ;;
esac
