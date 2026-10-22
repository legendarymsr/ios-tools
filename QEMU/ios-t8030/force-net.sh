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

# iOS only asks for an address when told to, and the USB ethernet is not
# always en0. Once the root shell is up, run DHCP on en0-en9 and check every
# 30 s; the first interface with a 10.0.2.x lease wins and the kick stops.
# Runs as long as the VM does.
#
# Long lines sent in one burst lose characters on the guest serial port and
# leave bash stuck at its ">" continuation prompt, so every command is
# preceded by Ctrl-C (drops any half-typed line) and typed 8 bytes at a time.
type_cmd() {
  printf '\003' >&3
  sleep 1
  local s="$1"
  while [ -n "$s" ]; do
    printf '%s' "${s:0:8}" >&3
    s=${s:8}
    sleep 0.1
  done
  printf '\n' >&3
}
IFS_EN='en0 en1 en2 en3 en4 en5 en6 en7 en8 en9'
(
  sleep 120
  n=0
  while kill -0 "$IOS" 2>/dev/null; do
    if [ $((n % 4)) = 0 ]; then
      type_cmd "for i in $IFS_EN; do /usr/sbin/ipconfig set \$i DHCP; done 2>/dev/null"
    fi
    sleep 20
    type_cmd "for i in $IFS_EN; do echo NETIF=\$i:\$(/usr/sbin/ipconfig getifaddr \$i); done 2>/dev/null"
    sleep 5
    HIT=$(grep -a -o 'NETIF=en[0-9]*:10\.0\.2\.[0-9]*' "$SERLOG" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -n "$HIT" ]; then
      echo "[*] iOS has network: ${HIT%%:*} ${HIT#*:} (gateway 10.0.2.2, DNS 10.0.2.3) - DHCP kick done"
      exit 0
    fi
    n=$((n + 1))
    [ $((n % 10)) = 0 ] && echo "[*] DHCP kick: no 10.0.2.x lease on en0-en9 yet ($((n / 2)) min), still trying"
  done
) &
KICK=$!

echo "[*] DHCP kick runs by itself; by hand on the serial console it is:"
echo "/usr/sbin/ipconfig set enN DHCP      (N: the USB ethernet, often en0)"
echo "/usr/sbin/ipconfig getifaddr enN"
echo "Expected: 10.0.2.x (gateway 10.0.2.2, DNS 10.0.2.3)"
echo
echo "[*] if it panics on mode-3, boot without NET=1, start companion after, then ipconfig"
wait $IOS || true
kill "$KICK" 2>/dev/null || true
rm -f "$FIFO"
