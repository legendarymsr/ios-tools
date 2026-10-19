#!/usr/bin/env bash
#
# build-inferno.sh  --  clone and build Inferno (ChefKiss), the iPhone 11 /
# t8030 Apple-Silicon emulator (formerly QEMUAppleSilicon / qemu-t8030).
# Run INSIDE the Debian chroot after setup-build-deps.sh.
#
# This builds real aarch64 Linux (glibc) QEMU binaries that run in the chroot.
# It is TCG-only for the iOS guest (the guest is an Apple CPU; KVM cannot help),
# so a boot takes many minutes and needs a strong phone + lots of RAM.
#
# Env:
#   SRC      where to clone/build        (default /root/Inferno)
#   JOBS     parallel build jobs         (default nproc)
#   PKG_CONFIG_PATH  set to /usr/local/lib64/pkgconfig if you built nettle
set -eu
SRC="${SRC:-/root/Inferno}"
JOBS="${JOBS:-$(nproc)}"
# Pinned to a known-good Inferno commit (HEAD as of Oct 2026). Override with REF=.
REF="${REF:-cc4302a99167abec69b714cfd00c38caece7e7de}"

# --- meson >= 1.5 -----------------------------------------------------------
# Inferno's meson.build requires meson >= 1.5; bookworm's apt meson is 1.0.1.
# Install a current meson from PyPI into the system site-packages (/usr/local),
# which QEMU's configure venv (created with --system-site-packages) also sees.
die() { echo "[ERROR] $*" >&2; exit 1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }
mver() { python3 -c 'import mesonbuild.coredata as c; print(c.version)' 2>/dev/null || echo 0; }
command -v ninja >/dev/null 2>&1 || apt-get install -y ninja-build || die "ninja missing and apt install failed"
if ! ver_ge "$(mver)" 1.5.0; then
  echo "[*] meson $(mver) too old, installing meson>=1.5 from PyPI"
  command -v pip3 >/dev/null 2>&1 || apt-get install -y python3-pip || die "python3-pip install failed"
  pip3 install --upgrade --break-system-packages 'meson>=1.5' || die "pip install meson>=1.5 failed"
fi
hash -r
MV="$(mver)"
ver_ge "$MV" 1.5.0 || die "meson is $MV, need >= 1.5.0 (pip install 'meson>=1.5' did not take effect)"
echo "[*] Using meson $MV ($(python3 -c 'import mesonbuild,os;print(os.path.dirname(mesonbuild.__file__))')), ninja $(ninja --version)"

if [ ! -d "$SRC/.git" ]; then
  git clone https://github.com/ChefKissInc/Inferno "$SRC"
fi
cd "$SRC"
git fetch --all --tags || true
git checkout "$REF" 2>/dev/null || echo "[!] couldn't checkout $REF, staying on default branch"
git submodule update --init --recursive

rm -rf build && mkdir build && cd build
../configure \
  --target-list=aarch64-softmmu,x86_64-softmmu \
  --enable-lzfse --enable-slirp --enable-curses --enable-libssh \
  --enable-virtfs --enable-zstd --enable-nettle --enable-gnutls \
  --enable-gtk --enable-sdl \
  --disable-werror --disable-qom-cast-debug --disable-debug-info \
  || die "configure / meson setup failed - see the error above"
ninja -j"$JOBS" || die "ninja build failed - see the error above"

echo
echo "[done] Built:"
for b in qemu-system-aarch64 qemu-img; do
  [ -x "./$b" ] && { printf '  %s\n' "$SRC/build/$b"; file "./$b"; }
done
echo
echo "Next: use ./prepare-ios-files.sh to lay out the IPSW/disks, then ./run-t8030.sh"
