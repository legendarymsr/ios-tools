#!/usr/bin/env bash
#
# setup-build-deps.sh  --  run INSIDE the Debian chroot (see
# ../general-kvm/setup-debian-chroot.sh). Installs everything needed to build
# Inferno (the t8030 / iPhone 11 emulator, formerly QEMUAppleSilicon).
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  git build-essential libtool meson ninja-build pkg-config \
  device-tree-compiler libglib2.0-dev gnutls-bin \
  libjpeg-turbo8-dev libpng-dev libslirp-dev libssh-dev \
  libusb-1.0-0-dev liblzo2-dev libncurses5-dev libncurses-dev \
  libpixman-1-dev libsnappy-dev vde2 zstd libzstd-dev \
  libgnutls28-dev libgmp10 libgmp3-dev libgtk-3-dev libsdl2-dev \
  python3 python3-pip python3-venv curl ca-certificates unzip wget \
  liblzfse-dev lzfse || true

# Debian bookworm ships nettle 3.8; Inferno needs >= 3.10. Build it if too old.
NETTLE_VER="$(pkg-config --modversion nettle 2>/dev/null || echo 0)"
need_nettle=0
case "$NETTLE_VER" in
  3.1[0-9]*|3.[2-9][0-9]*|[4-9].*) need_nettle=0 ;;
  *) need_nettle=1 ;;
esac
if [ "$need_nettle" = "1" ]; then
  echo "[*] Nettle $NETTLE_VER too old; building 3.10.2 from source..."
  cd /tmp
  wget -O nettle.tar.gz https://ftpmirror.gnu.org/gnu/nettle/nettle-3.10.2.tar.gz
  echo "fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5  nettle.tar.gz" | sha256sum -c -
  tar -xf nettle.tar.gz && cd nettle-3.10.2
  ./configure && make -j"$(nproc)" && make install && ldconfig
  echo "[*] Nettle installed to /usr/local; pass PKG_CONFIG_PATH=/usr/local/lib64/pkgconfig to build-inferno.sh"
fi
echo "[done] build deps installed."
