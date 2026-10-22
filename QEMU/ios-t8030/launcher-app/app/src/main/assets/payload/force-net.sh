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
SERLOG="$DATA/serial-boot.log"
# The serial console is QEMU's stdin; feed it from a FIFO so the DHCP kick
# below can type into the guest's root shell.
FIFO="$DATA/.serial-in"
rm -f "$FIFO"; mkfifo "$FIFO"
exec 3<>"$FIFO"
if [ ! -f "$DATA/JAILBREAK_APPLIED" ]; then
  echo "[!] no root shell on the serial console (step 8 not applied) - the DHCP kick below will not reach iOS"
fi
NET=1 NET_RETRY=0 bash "$HERE/run-t8030.sh" <&3 &
IOS=$!
echo "[*] iOS VM pid $IOS"
echo "[*] wait for SpringBoard on VNC 127.0.0.1:5900"

# iOS only asks for an address when told to: once the root shell is up,
# send "ipconfig set en0 DHCP" every 30 s until en0 reports 10.0.2.x.
(
  sleep 120
  for i in $(seq 1 60); do
    kill -0 "$IOS" 2>/dev/null || exit 0
    printf '/usr/sbin/ipconfig set en0 DHCP\n' >&3
    sleep 25
    printf 'echo NETIP=$(/usr/sbin/ipconfig getifaddr en0)\n' >&3
    sleep 5
    IP=$(grep -a -o 'NETIP=10\.0\.2\.[0-9]*' "$SERLOG" 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$IP" ]; then
      echo "[*] iOS has network: en0 $IP (gateway 10.0.2.2, DNS 10.0.2.3)"
      exit 0
    fi
  done
  echo "[!] no DHCP address after 30 min - check the [net] lines above"
) &
KICK=$!

echo "[*] DHCP kick runs by itself; by hand on the serial console it is:"
echo "/usr/sbin/ipconfig set en0 DHCP"
echo "/usr/sbin/ipconfig getifaddr en0"
echo "Expected: 10.0.2.20 (gateway 10.0.2.2, DNS 10.0.2.3)"
echo
echo "[*] if it panics on mode-3, boot without NET=1, start companion after, then ipconfig"
wait $IOS || true
kill "$KICK" 2>/dev/null || true
rm -f "$FIFO"
