#!/usr/bin/env bash
# force-net.sh — working reverse-tether for Inferno t8030 on Android
# Companion first, then NET=1 boot. Guest still needs one ipconfig kick.
set -eu
DATA="${DATA:-/root/InfernoData}"
HERE=$(cd "$(dirname "$0")" && pwd)

echo "[*] stopping old VMs"
bash "$HERE/companion-vm.sh" stop || true
pkill -f 'qemu-system-aarch64.*-M t8030' || true
sleep 2

echo "[*] starting companion in net mode (mode 3 + bridge to SLIRP)"
DATA="$DATA" bash "$HERE/companion-vm.sh" net
echo "[*] companion up"

echo "[*] booting iOS with NET=1"
cd "$DATA"
NET=1 NET_RETRY=0 bash "$HERE/run-t8030.sh" &
IOS=$!
echo "[*] iOS VM pid $IOS"
echo "[*] wait for SpringBoard on VNC 127.0.0.1:5900"
echo
echo "=== once home screen is up, run this on the guest serial console: ==="
echo "/usr/sbin/ipconfig set en0 DHCP"
echo "/usr/sbin/ipconfig getifaddr en0"
echo "Expected: 10.0.2.20 (gateway 10.0.2.2, DNS 10.0.2.3)"
echo
echo "[*] if it panics on mode-3, boot without NET=1, start companion after, then ipconfig"
wait $IOS || true
