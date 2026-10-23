#!/usr/bin/env bash
#
# setup-build-deps.sh  --  run INSIDE the Debian chroot (see
# ../general-kvm/setup-debian-chroot.sh). Installs everything needed to build
# Inferno (the t8030 / iPhone 11 emulator, formerly QEMUAppleSilicon).
#
# Debian bookworm has no lzfse packages (liblzfse-dev / lzfse only exist from
# trixie on), so lzfse is built from source (github.com/lzfse/lzfse, pinned
# commit) and installed into /usr/local, where Inferno's meson finds it.
set -eu
export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

die() { echo "[ERROR] $*" >&2; exit 1; }

# Entering the chroot from Android keeps Android's PATH (/system/bin...), so
# Debian's /etc/profile runs `id` before it sets PATH and prints
# "id: command not found". Give /etc/profile a sane PATH first (once).
if [ -f /etc/profile ] && ! grep -q 'ios-tools: android PATH fix' /etc/profile; then
  sed -i '1i # ios-tools: android PATH fix\nexport PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"' /etc/profile \
    || echo "[!] could not patch /etc/profile (harmless)"
fi

echo "[*] apt-get update"
ok=0
for i in 1 2 3; do
  if apt-get update; then ok=1; break; fi
  echo "[!] apt-get update failed (attempt $i/3), retrying in 5s..." >&2
  sleep 5
done
[ "$ok" = 1 ] || die "apt-get update failed 3 times - see the error above"

echo "[*] Installing Debian packages"
# ChefKiss's Debian list mapped to bookworm names (libjpeg-turbo8-dev is the
# Ubuntu name, bookworm has libjpeg62-turbo-dev; lzfse/liblzfse-dev do not
# exist in bookworm and are built below). GTK/SDL are left out: there is no
# display server in the Android chroot; Inferno is built for VNC output.
PKGS="git build-essential cmake libtool meson ninja-build pkg-config \
  device-tree-compiler libglib2.0-dev gnutls-bin libtasn1-6-dev \
  libjpeg62-turbo-dev libpng-dev libslirp-dev libssh-dev \
  libusb-1.0-0-dev liblzo2-dev libncurses-dev \
  libpixman-1-dev libsnappy-dev vde2 zstd libzstd-dev zlib1g-dev \
  libgnutls28-dev libgmp10 libgmp-dev libattr1-dev libcap-ng-dev \
  libssl-dev openssl \
  python3 python3-pip python3-venv python3-setuptools python3-wheel \
  curl ca-certificates unzip wget xz-utils file bzip2 tar m4 \
  autoconf automake libtool-bin libcurl4-openssl-dev libzip-dev libreadline-dev \
  busybox-static cpio kmod usbutils bc bison flex libelf-dev \
  dnsmasq-base nftables tcpdump"
# The last three lines are for step 5 (Restore iOS): build-restore-tools.sh
# builds libimobiledevice/idevicerestore/usbmuxd (autotools, libcurl, libzip)
# and the USB-host VM (busybox-static initramfs, kmod, linux-apfs-rw module);
# dnsmasq/nftables/tcpdump serve and NAT the iPhone's USB ethernet in that VM.
ok=0
for i in 1 2 3; do
  # shellcheck disable=SC2086
  if apt-get install -y $PKGS; then ok=1; break; fi
  echo "[!] apt-get install failed (attempt $i/3); repairing dpkg state and retrying..." >&2
  dpkg --configure -a || true
  apt-get -f install -y || true
  apt-get update || true
  sleep 5
done
[ "$ok" = 1 ] || die "apt-get install failed - see the package error above"

# --- meson >= 1.5 (Inferno needs it; bookworm ships 1.0.1) -----------------
echo "[*] Installing meson>=1.5 from PyPI"
ok=0
for i in 1 2 3; do
  pip3 install --upgrade --break-system-packages 'meson>=1.5' && { ok=1; break; }
  sleep 5
done
[ "$ok" = 1 ] || die "pip install meson>=1.5 failed"
hash -r
python3 -c 'import mesonbuild.coredata as c; print("[*] meson", c.version)' || die "meson python module missing after pip install"

# --- lzfse (from source) ----------------------------------------------------
LZFSE_REPO="${LZFSE_REPO:-https://github.com/lzfse/lzfse}"
LZFSE_REF="e634ca58b4821d9f3d560cdc6df5dec02ffc93fd"   # upstream master HEAD (2017-05-22)
LZFSE_PREFIX=/usr/local

lzfse_ok() {
  [ -f "$LZFSE_PREFIX/include/lzfse.h" ] || return 1
  printf '#include <lzfse.h>\nint main(void){return lzfse_decode_scratch_size()==0;}\n' > /tmp/lzfse-test.c
  cc /tmp/lzfse-test.c -o /tmp/lzfse-test -llzfse >/dev/null 2>&1 && /tmp/lzfse-test
}

if lzfse_ok; then
  echo "[*] lzfse already installed in $LZFSE_PREFIX"
else
  echo "[*] Building lzfse from source ($LZFSE_REPO @ ${LZFSE_REF:0:12})"
  W=/tmp/lzfse-src
  rm -rf "$W"
  git -c http.version=HTTP/1.1 clone "$LZFSE_REPO" "$W" \
    || { sleep 5; rm -rf "$W"; git -c http.version=HTTP/1.1 clone "$LZFSE_REPO" "$W"; } \
    || die "could not clone $LZFSE_REPO"
  git -C "$W" checkout -q "$LZFSE_REF" || die "lzfse commit $LZFSE_REF not found"
  [ "$(git -C "$W" rev-parse HEAD)" = "$LZFSE_REF" ] || die "lzfse checkout is not $LZFSE_REF"
  cmake -S "$W" -B "$W/build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LZFSE_PREFIX" -DBUILD_SHARED_LIBS=ON \
    || die "lzfse cmake configure failed"
  cmake --build "$W/build" -j"$(nproc)" || die "lzfse build failed"
  cmake --install "$W/build" || die "lzfse install failed"
  ldconfig
  lzfse_ok || die "lzfse installed but a test program cannot link/run against -llzfse"
  rm -rf "$W"
  echo "[*] lzfse installed: $LZFSE_PREFIX/lib/liblzfse.so, $LZFSE_PREFIX/include/lzfse.h, $LZFSE_PREFIX/bin/lzfse"
fi
rm -f /tmp/lzfse-test /tmp/lzfse-test.c

# --- nettle -------------------------------------------------------------------
# Debian bookworm ships nettle 3.8; Inferno needs >= 3.10. Build it if too old.
# nettle installs into /usr/local/lib64 on 64-bit hosts; add that to the
# pkg-config and ld.so search paths so the check below and Inferno both see it.
export PKG_CONFIG_PATH="/usr/local/lib64/pkgconfig:/usr/local/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
echo /usr/local/lib64 > /etc/ld.so.conf.d/000-usr-local-lib64.conf
ldconfig
NETTLE_VER="$(pkg-config --modversion nettle 2>/dev/null || echo 0)"
need_nettle=0
case "$NETTLE_VER" in
  3.1[0-9]*|3.[2-9][0-9]*|[4-9].*) need_nettle=0 ;;
  *) need_nettle=1 ;;
esac
if [ "$need_nettle" = "1" ]; then
  echo "[*] Nettle $NETTLE_VER too old; building 3.10.2 from source..."
  cd /tmp
  rm -rf nettle.tar.gz nettle-3.10.2
  wget -O nettle.tar.gz https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz \
    || wget -O nettle.tar.gz https://ftp.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz \
    || die "nettle download failed"
  echo "fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5  nettle.tar.gz" | sha256sum -c - \
    || die "nettle checksum mismatch"
  tar -xf nettle.tar.gz && cd nettle-3.10.2
  { ./configure && make -j"$(nproc)" && make install && ldconfig; } || die "nettle build failed"
  cd /tmp && rm -rf nettle.tar.gz nettle-3.10.2
  NETTLE_VER="$(pkg-config --modversion nettle 2>/dev/null || echo 0)"
  case "$NETTLE_VER" in 3.1[0-9]*|3.[2-9][0-9]*|[4-9].*) ;; *) die "nettle built but pkg-config still reports $NETTLE_VER";; esac
  echo "[*] nettle $NETTLE_VER installed ($(pkg-config --variable=libdir nettle))"
else
  echo "[*] nettle $NETTLE_VER already new enough"
fi
echo "[done] build deps installed."
