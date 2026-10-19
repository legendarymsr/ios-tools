#!/usr/bin/env bash
#
# build-inferno.sh  --  clone and build Inferno (ChefKiss), the iPhone 11 /
# t8030 Apple-Silicon emulator (formerly QEMUAppleSilicon / qemu-t8030).
# Run INSIDE the Debian chroot after setup-build-deps.sh (step 2).
#
# Produces /root/Inferno/build/qemu-system-aarch64 and qemu-img (aarch64
# glibc binaries for the chroot). TCG-only for the iOS guest.
#
# Re-runs are safe: a finished build is detected (ninja only rebuilds what
# changed, e.g. after a new ios-tools patch: one file + link, a few minutes), a half-finished build with
# the same commit + configure flags is resumed with ninja, and anything else
# (other commit/flags, broken checkout, failed configure) is cleaned first.
#
# Env:
#   SRC        where to clone/build      (default /root/Inferno)
#   JOBS       parallel build jobs       (default: picked from free RAM)
#   REF        Inferno commit            (default pinned below)
#   CLEAN=1      wipe build/ and reconfigure from scratch
#   CLEAN_SRC=1  also re-download the source
#   FULL_TARGETS=1  also build x86_64-softmmu (not needed on a phone)
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export DEBIAN_FRONTEND=noninteractive

SRC="${SRC:-/root/Inferno}"
REPO="${REPO:-https://github.com/ChefKissInc/Inferno}"
# Pinned Inferno commit: master HEAD Oct 2026 ("ChefKissInferno-1.0.0rc1",
# QEMU 10.2.2 base). Override with REF=<sha>.
REF="${REF:-cc4302a99167abec69b714cfd00c38caece7e7de}"

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

# retry N cmd...   (GitHub/GitLab over mobile data drops now and then)
retry() {
  local n="$1" i; shift
  for i in $(seq 1 "$n"); do
    "$@" && return 0
    [ "$i" -lt "$n" ] && { warn "attempt $i/$n failed: $*  - retrying in $((i*5))s"; sleep $((i*5)); }
  done
  return 1
}

# ---------- toolchain sanity ------------------------------------------------
for c in git curl cc c++ make pkg-config python3 ninja tar; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' missing - run step 2 (Install build deps) first"
done

# meson >= 1.5: Inferno's meson.build has meson_version '>=1.5.0'; bookworm's
# apt meson is 1.0.1. Step 2 pip-installs a newer one into /usr/local
# (system site-packages), which QEMU's configure venv also sees.
mver() { python3 -c 'import mesonbuild.coredata as c; print(c.version)' 2>/dev/null || echo 0; }
if ! ver_ge "$(mver)" 1.5.0; then
  log "meson $(mver) too old, installing meson>=1.5 from PyPI"
  command -v pip3 >/dev/null 2>&1 || apt-get install -y python3-pip || die "python3-pip install failed"
  retry 3 pip3 install --upgrade --break-system-packages 'meson>=1.5' || die "pip install meson>=1.5 failed"
fi
hash -r
MV="$(mver)"
ver_ge "$MV" 1.5.0 || die "meson is $MV, need >= 1.5.0"
log "meson $MV, ninja $(ninja --version), $(cc --version | head -n1)"

# nettle >= 3.10: --enable-nettle hard-requires it (meson.build: nettle
# version '>=3.10'); bookworm ships 3.8. Step 2 builds 3.10.2 into /usr/local,
# and nettle's installer uses /usr/local/lib64 on 64-bit, which neither
# pkg-config nor ld.so search by default. Earlier versions never set this, so
# configure saw nettle 3.8 and failed.
export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
if [ -d /usr/local/lib64 ] && ! grep -qsx /usr/local/lib64 /etc/ld.so.conf.d/*.conf; then
  echo /usr/local/lib64 > /etc/ld.so.conf.d/000-usr-local-lib64.conf
fi
ldconfig
NV="$(pkg-config --modversion nettle 2>/dev/null || echo 0)"
ver_ge "$NV" 3.10 || die "nettle is $NV, need >= 3.10 - re-run step 2 (it builds nettle 3.10.2)"
log "nettle $NV ($(pkg-config --variable=libdir nettle))"
for pc in gnutls glib-2.0 pixman-1 zlib slirp libzstd; do
  pkg-config --exists "$pc" || die "$pc dev files missing - re-run step 2"
done
[ -f /usr/local/include/lzfse.h ] || [ -f /usr/include/lzfse.h ] || die "lzfse missing - re-run step 2 (builds it from source)"

# ---------- RAM-aware job count (phones OOM on QEMU's big files) ------------
if [ -z "${JOBS:-}" ]; then
  memkb=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  JOBS=$(( memkb / 1200000 ))           # ~1.2 GB per compiler job, worst case
  [ "$JOBS" -lt 1 ] && JOBS=1
  [ "$JOBS" -gt "$(nproc)" ] && JOBS=$(nproc)
fi
log "jobs: $JOBS (nproc $(nproc), MemAvailable $(awk '/MemAvailable/{printf "%d MB",$2/1024}' /proc/meminfo))"
avail_kb=$(df -Pk "$(dirname "$SRC")" | awk 'NR==2{print $4}')
[ "${avail_kb:-0}" -lt 4000000 ] && warn "only $((avail_kb/1024)) MB free; source + build needs ~3-4 GB"

# ---------- source at the pinned commit -------------------------------------
# Debian's git uses libcurl-gnutls, which drops big packs on flaky links
# ("GnuTLS recv error (-110)", "early EOF"). Force HTTP/1.1, retry, and if git
# still fails fall back to GitHub's source tarball over curl.
GITNET=(-c http.version=HTTP/1.1 -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60)
tarball_src() {   # tarball_src OWNER/REPO SHA DESTDIR
  local t="/tmp/src-$2.tar.gz"
  rm -f "$t"
  retry 4 curl -fL --retry 3 -o "$t" "https://codeload.github.com/$1/tar.gz/$2" || return 1
  rm -rf "$3"; mkdir -p "$3"
  tar -xzf "$t" -C "$3" --strip-components=1 || { rm -f "$t"; return 1; }
  rm -f "$t"
}
src_git_ok() { [ -d "$SRC/.git" ] && git -C "$SRC" rev-parse --verify -q HEAD >/dev/null 2>&1; }
src_tar_ok() { [ -f "$SRC/.ios-tools-tarball" ] && [ "$(cat "$SRC/.ios-tools-tarball")" = "$REF" ] && [ -f "$SRC/meson.build" ]; }

[ "${CLEAN_SRC:-0}" = "1" ] && rm -rf "$SRC"
if [ -e "$SRC" ] && ! src_git_ok && ! src_tar_ok; then
  warn "$SRC is not a usable checkout (interrupted clone or old tarball) - removing"
  rm -rf "$SRC"
fi

if ! src_git_ok && ! src_tar_ok; then
  log "fetching Inferno @ ${REF:0:12} (shallow)"
  rm -rf "$SRC"; mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$REPO"
  if ! retry 4 git "${GITNET[@]}" -C "$SRC" fetch --depth 1 origin "$REF"; then
    warn "git fetch keeps failing, downloading the source tarball instead"
    tarball_src ChefKissInc/Inferno "$REF" "$SRC" || die "could not download Inferno source (network?)"
    echo "$REF" > "$SRC/.ios-tools-tarball"
  fi
fi

if src_tar_ok; then
  log "source: tarball of $REF ($(cat "$SRC/VERSION" 2>/dev/null))"
  if [ ! -f "$SRC/util/mlib/m-core.h" ]; then
    MLIB_SHA=$(curl -fsSL "https://api.github.com/repos/ChefKissInc/Inferno/contents/util/mlib?ref=$REF" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])') || die "could not look up the mlib commit"
    tarball_src P-p-H-d/mlib "$MLIB_SHA" "$SRC/util/mlib" || die "could not fetch util/mlib"
  fi
else
  if [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)" != "$REF" ]; then
    git -C "$SRC" cat-file -e "$REF^{commit}" 2>/dev/null \
      || retry 3 git "${GITNET[@]}" -C "$SRC" fetch --depth 1 origin "$REF" \
      || die "cannot fetch Inferno commit $REF (network?) - re-run, or CLEAN_SRC=1"
    git -C "$SRC" -c advice.detachedHead=false checkout -f "$REF" || die "checkout $REF failed"
  fi
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$REF" ] || die "source is not at $REF"
  log "source: $(git -C "$SRC" log -1 --format='%h %cd %s' --date=short) ($(cat "$SRC/VERSION" 2>/dev/null))"
  # Only util/mlib is needed. The other submodules are firmware ROM sources
  # (edk2, u-boot, seabios, ...; several GB with --recursive) the build never
  # uses; earlier versions pulled them all recursively.
  MLIB_SHA=$(git -C "$SRC" ls-tree HEAD util/mlib | awk '{print $3}')
  if [ ! -f "$SRC/util/mlib/m-core.h" ]; then
    if ! retry 4 git "${GITNET[@]}" -C "$SRC" submodule update --init --depth 1 util/mlib; then
      warn "mlib submodule via git failed, using the tarball of $MLIB_SHA"
      tarball_src P-p-H-d/mlib "$MLIB_SHA" "$SRC/util/mlib" || die "could not fetch util/mlib"
    fi
  fi
  # Free the space of an old recursive ROM checkout
  for d in "$SRC"/roms/*/; do
    [ -e "$d/.git" ] && { git -C "$SRC" submodule deinit -f "roms/$(basename "$d")" >/dev/null 2>&1 || true; }
  done
  rm -rf "$SRC/.git/modules/roms" 2>/dev/null || true
fi
[ -f "$SRC/util/mlib/m-core.h" ] || die "util/mlib is empty after fetch"

# ---------- ios-tools patches on top of the pinned commit -------------------
# inferno-usb-tcp-remote-fix.patch: the USB-host (companion) side of the
# virtual USB cable aborted QEMU ("usb packet state check failed") when the
# iOS side disconnected while a packet was already cancelled, and could abort
# on a quick reconnect. Applying it to an already built tree only recompiles
# hw/usb/dev-tcp-remote.c and relinks qemu-system-aarch64 (a few minutes).
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH_ID="usb-tcp-remote-fix-1"
for p in inferno-usb-tcp-remote-fix.patch; do
  pf="$HERE/$p"
  [ -f "$pf" ] || die "$p missing next to $0 (copy the whole payload)"
  if git -C "$SRC" apply --reverse --check "$pf" >/dev/null 2>&1; then
    log "patch $p: already applied"
  elif git -C "$SRC" apply --check "$pf" >/dev/null 2>&1; then
    git -C "$SRC" apply "$pf" || die "applying $p failed"
    log "patch $p: applied (ninja rebuilds only the changed file)"
  else
    die "$p does not apply to $SRC - CLEAN_SRC=1 to re-download the source"
  fi
done

# ---------- configure (reuse only an identical, completed configure) -------
TARGETS="aarch64-softmmu"
[ "${FULL_TARGETS:-0}" = "1" ] && TARGETS="aarch64-softmmu,x86_64-softmmu"
CONF_ARGS=(
  --target-list="$TARGETS"
  --disable-guest-agent
  --enable-lzfse --enable-slirp --enable-curses --enable-libssh
  --enable-virtfs --enable-zstd --enable-nettle --enable-gnutls
  --enable-vnc --enable-vnc-jpeg --enable-png
  --disable-gtk --disable-sdl --disable-opengl
  --disable-werror --disable-qom-cast-debug --disable-debug-info
)
# GTK/SDL off on purpose: no X/Wayland in an Android chroot. The display is
# VNC (the launcher's built-in viewer), which is all run-t8030.sh uses.
STAMP_WANT="$REF ${CONF_ARGS[*]} nettle=$NV meson=$MV"
STAMP="$SRC/build/.ios-tools-configured"
cd "$SRC"
if [ "${CLEAN:-0}" = "1" ] || [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$STAMP_WANT" ] \
   || [ ! -f build/build.ninja ]; then
  log "configuring (fresh build dir)"
  rm -rf build && mkdir build && cd build
  # meson downloads subproject wraps (dtc, keycodemapdb, softfloat...) here
  if ! retry 2 ../configure "${CONF_ARGS[@]}"; then
    tail -n 40 meson-logs/meson-log.txt 2>/dev/null >&2 || true
    die "configure / meson setup failed - see the error above (log: $SRC/build/meson-logs/meson-log.txt)"
  fi
  echo "$STAMP_WANT" > "$STAMP"
else
  log "reusing the existing configure in $SRC/build (resuming the build)"
  cd build
fi

# ---------- build ------------------------------------------------------------
log "building with ninja -j$JOBS (30-90 min on a phone)"
if ! ninja -j"$JOBS" qemu-system-aarch64 qemu-img; then
  # Usual phone failure: OOM killer ("Killed signal terminated program cc1").
  # Resume with one job; ninja keeps everything already compiled.
  warn "ninja -j$JOBS failed; retrying with -j1 (resumes, keeps finished objects)"
  ninja -j1 qemu-system-aarch64 qemu-img || die "ninja build failed - see the first 'FAILED:' line above"
fi

for b in qemu-system-aarch64 qemu-img; do
  [ -x "./$b" ] || die "build finished but $SRC/build/$b is missing"
done
echo "$PATCH_ID" > .ios-tools-patches
./qemu-system-aarch64 -machine help | grep -qE '^t8030[[:space:]]' \
  || die "built qemu-system-aarch64 has no t8030 machine - wrong source?"
./qemu-system-aarch64 -version | head -n1
echo
echo "[done] Built:"
printf '  %s\n' "$SRC/build/qemu-system-aarch64" "$SRC/build/qemu-img"
# The build tree is used without "make install"; make sure QEMU's keymaps
# (needed by -display vnc) sit in a data dir the launch scripts pass with -L.
if [ -d "$SRC/pc-bios/keymaps" ]; then
  mkdir -p "$SRC/build/ios-tools-qemu-data" && cp -r "$SRC/pc-bios/keymaps" "$SRC/build/ios-tools-qemu-data/" \
    && echo "[*] keymaps copied to $SRC/build/ios-tools-qemu-data" || echo "[!] could not copy keymaps (the launch scripts retry at runtime)"
fi
echo "Next: step 4 (Download & configure iOS)."
