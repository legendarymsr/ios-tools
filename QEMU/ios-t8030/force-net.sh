#!/usr/bin/env bash
# force-net.sh — working reverse-tether for Inferno t8030 on Android
# iOS first (no network), the USB-host VM in net mode once iOS is up, then the
# DHCP kick typed into the guest's root shell.
set -eu
DATA="${DATA:-/root/InfernoData}"
HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX="${PREFIX:-/opt/inferno-restore}"
USB_SOCK="${USB_SOCK:-$DATA/restore/usb.sock}"
export USB_SOCK

echo "[*] stopping old VMs"
bash "$HERE/companion-vm.sh" stop || true
pkill -f 'qemu-system-aarch64.*-M t8030' || true
sleep 2

# USB ethernet needs the v6 USB-host VM (cdc_ncm, bridge and NAT modules;
# dnsmasq/nftables/tcpdump in the chroot).
if ! grep -q ' v6$' "$PREFIX/.built-companion" 2>/dev/null; then
  echo "[net] USB-host VM needs a rebuild for USB ethernet (cdc_ncm, bridge and NAT modules, dnsmasq) - running build-restore-tools.sh (a few minutes, once)"
  bash "$HERE/build-restore-tools.sh" || echo "[net] ERROR: build-restore-tools.sh failed - no network this boot"
fi

# Boot iOS with networking off, its USB port pointed at the USB-host VM's
# socket. That VM is not running yet: Inferno's USB host side (step 3's
# usb-tcp-host-retry patch) retries the socket every 2 s, so iOS plugs into the
# VM once it is started below, after iOS is up. Starting it first (NET=1) has
# had iOS panic during boot.
echo "[*] booting iOS (network comes up once iOS is running)"
mkdir -p "$(dirname "$USB_SOCK")"
rm -f "$USB_SOCK"
cd "$DATA"
SERLOG="$DATA/serial-boot.log"
: > "$SERLOG"   # don't let the kick read the previous boot's markers
BOOT=$$         # per-boot tag in the guest markers
# The serial console is QEMU's stdin; feed it from a FIFO so the DHCP kick
# below can type into the guest's root shell.
FIFO="$DATA/.serial-in"
rm -f "$FIFO"; mkfifo "$FIFO"
exec 3<>"$FIFO"
if [ ! -f "$DATA/JAILBREAK_APPLIED" ]; then
  echo "[!] no root shell on the serial console (step 8 not applied) - the DHCP kick below will not reach iOS"
fi
NET=0 NET_RETRY=0 PANIC_WATCH=1 USB_CONN_TYPE=unix USB_CONN_ADDR="$USB_SOCK" bash "$HERE/run-t8030.sh" <&3 &
IOS=$!
echo "[*] iOS VM pid $IOS"
echo "[*] wait for SpringBoard on VNC 127.0.0.1:5900"

# iOS only asks for an address when told to, and the USB ethernet is not
# always en0. Once the root shell is up, ask iOS for its interfaces
# (ipconfig getiflist, else en0-en9), run DHCP on the en* ones and check their
# addresses; the first with a lease from the USB-host VM (10.11.12.x routed,
# 10.0.2.x with NET_MODE=bridge) wins and the kick stops. Runs as
# long as the VM does.
#
# Long lines sent in one burst lose characters on the guest serial port, so
# commands are typed 8 bytes at a time. Each ipconfig call takes seconds under
# TCG, so every command ends with a marker (computed by the guest, so the echo
# of the typed line can't match it) and the next one is only sent once that
# marker shows up. Ctrl-C is only sent when a command hangs.
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
  type_cmd "$1; echo KICKDONE${BOOT}x\$((7000+$SEQ))"
  local t=0
  until grep -a -q "KICKDONE${BOOT}x$((7000 + SEQ))" "$SERLOG" 2>/dev/null; do
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
  set +e   # a timed-out guest command must not end the kick
  sleep 60
  # Wait for the root shell: a bare marker every 20 s until one comes back,
  # so the real commands don't burn their long timeouts while iOS boots.
  echo "[*] DHCP kick: waiting for the iOS root shell on the serial console"
  until run_guest 'true' 20; do
    kill -0 "$IOS" 2>/dev/null || exit 0
  done
  echo "[*] DHCP kick: iOS shell answered - starting the USB-host VM in net mode (mode 3, ${NET_MODE:-routed})"
  if DATA="$DATA" bash "$HERE/companion-vm.sh" net; then
    echo "[*] USB-host VM up; iOS plugs into it within seconds"
    tail -n +1 -F "$DATA/companion/job.log" 2>/dev/null |
      grep --line-buffered -E '^\[net\]|Switching device|mode' &
  else
    echo "[net] ERROR: the USB-host VM did not start (see above) - iOS stays up without network"
    exit 0
  fi
  echo "[*] DHCP kick: setting up the network"
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
      run_guest 'for i in ${L:-en0 en1 en2 en3 en4 en5}; do case $i in en*) /usr/sbin/ipconfig set $i DHCP;; esac; done 2>/dev/null' 180
      sleep 15
    fi
    run_guest 'for i in ${L:-en0 en1 en2 en3 en4 en5}; do echo NETIF=$i:$(/usr/sbin/ipconfig getifaddr $i); done 2>/dev/null' 180
    HIT=$(grep -a -o 'NETIF=en[0-9]*:10\.\(11\.12\|0\.2\)\.[0-9]*' "$SERLOG" 2>/dev/null | head -1 | cut -d= -f2)
    if [ -n "$HIT" ]; then
      case "${HIT#*:}" in
        10.11.12.*) GW="gateway and DNS 10.11.12.1" ;;
        *) GW="gateway 10.0.2.2, DNS 10.0.2.3" ;;
      esac
      echo "[*] iOS has network: ${HIT%%:*} ${HIT#*:} ($GW) - DHCP kick done"
      exit 0
    fi
    n=$((n + 1))
    if [ $((SECONDS - START)) -ge "$NEXT_NOTE" ]; then
      echo "[*] DHCP kick: no lease yet ($(( (SECONDS - START) / 60 )) min), still trying"
      NEXT_NOTE=$((NEXT_NOTE + 300))
    fi
    sleep 10
  done
) &
KICK=$!

echo "[*] DHCP kick runs by itself; by hand on the serial console it is:"
echo "/usr/sbin/ipconfig set enN DHCP      (N: the USB ethernet, often en0)"
echo "/usr/sbin/ipconfig getifaddr enN"
echo "Expected: 10.11.12.x (gateway/DNS 10.11.12.1; NET_MODE=bridge: 10.0.2.x, gateway 10.0.2.2, DNS 10.0.2.3)"
echo
cleanup() {
  trap - EXIT INT TERM
  pkill -P "$KICK" 2>/dev/null || true   # the kick's tail/grep/sleep/companion start
  kill "$KICK" 2>/dev/null || true
  pkill -f "tail -n [+]1 -F $DATA/companion/job.log" 2>/dev/null || true   # outlives a finished kick
  pkill -f 'qemu-system-aarch64.*-M t8030' 2>/dev/null || true
  echo "[*] iOS VM exited - stopping the USB-host VM"
  bash "$HERE/companion-vm.sh" stop || true
  rm -f "$FIFO"
}
trap cleanup EXIT INT TERM
wait $IOS || true
