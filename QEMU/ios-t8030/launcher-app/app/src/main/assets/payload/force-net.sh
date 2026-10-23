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
# always en0. Once the root shell is up, ask iOS for its interfaces
# (ipconfig getiflist, else en0-en9), run DHCP on the en* ones and check their
# addresses; the first with a 10.0.2.x lease wins and the kick stops. Runs as
# long as the VM does.
#
# Long lines sent in one burst lose characters on the guest serial port, so
# commands are typed 8 bytes at a time. Each ipconfig call takes seconds under
# TCG, so every command ends with a marker (computed by the guest, so the echo
# of the typed line can't match it) and the next one is only sent once that
# marker shows up. Ctrl-C is sent once at the start and when a command hangs.
type_cmd() {
  local s="$1"
  while [ -n "$s" ]; do
    printf '%s' "${s:0:8}" >&3
    s=${s:8}
    sleep 0.1
  done
  printf '\n' >&3
}
SEQ=0
run_guest() {   # run_guest CMD TIMEOUT_S: type CMD, wait until it has finished
  SEQ=$((SEQ + 1))
  type_cmd "$1; echo KICKDONE\$((7000+$SEQ))"
  local t=0
  until grep -a -q "KICKDONE$((7000 + SEQ))" "$SERLOG" 2>/dev/null; do
    kill -0 "$IOS" 2>/dev/null || return 1
    sleep 1
    t=$((t + 1))
    if [ "$t" -ge "$2" ]; then
      printf '\003' >&3
      sleep 1
      return 1
    fi
  done
}
(
  sleep 120
  printf '\003' >&3   # drop anything half-typed on the console
  sleep 1
  START=$SECONDS; NEXT_NOTE=300; n=0; last_list=""
  while kill -0 "$IOS" 2>/dev/null; do
    run_guest 'L=$(/usr/sbin/ipconfig getiflist 2>/dev/null); [ -n "$L" ] || L="en0 en1 en2 en3 en4 en5 en6 en7 en8 en9"; echo IFLIST=$L' 60
    LIST=$(grep -a -o 'IFLIST=[a-z].*' "$SERLOG" 2>/dev/null | tail -1 | tr -d '\r')
    LIST=${LIST#IFLIST=}
    force=0
    if [ -n "$LIST" ] && [ "$LIST" != "$last_list" ]; then
      echo "[*] iOS network interfaces: $LIST"
      last_list=$LIST
      force=1
    fi
    if [ "$force" = 1 ] || [ $((n % 4)) = 0 ]; then
      run_guest 'for i in $L; do case $i in en*) /usr/sbin/ipconfig set $i DHCP;; esac; done 2>/dev/null' 180
      sleep 15
    fi
    run_guest 'for i in $L; do echo NETIF=$i:$(/usr/sbin/ipconfig getifaddr $i); done 2>/dev/null' 180
    HIT=$(grep -a -o 'NETIF=en[0-9]*:10\.0\.2\.[0-9]*' "$SERLOG" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -n "$HIT" ]; then
      echo "[*] iOS has network: ${HIT%%:*} ${HIT#*:} (gateway 10.0.2.2, DNS 10.0.2.3) - DHCP kick done"
      exit 0
    fi
    n=$((n + 1))
    if [ $((SECONDS - START)) -ge "$NEXT_NOTE" ]; then
      echo "[*] DHCP kick: no 10.0.2.x lease yet ($(( (SECONDS - START) / 60 )) min), still trying"
      NEXT_NOTE=$((NEXT_NOTE + 300))
    fi
    sleep 10
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
