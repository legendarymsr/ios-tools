#!/usr/bin/env bash
#
# vhci-usb.sh -- Inferno usb-tcp <-> Linux VHCI, run inside the Debian chroot.
# Replaces the companion USB-host VM when the Larry kernel has
# CONFIG_USBIP_VHCI_HCD=y. usbmuxd + idevicerestore then see the iPhone on
# /dev/bus/usb directly (no second QEMU, no USBMUXD_SOCKET_ADDRESS).
#
# Usage:
#   vhci-usb.sh start   # listen on $USB_SOCK, attach to vhci when iOS connects
#   vhci-usb.sh stop
#   vhci-usb.sh status  # "vhci" | "missing" | "running" | "stopped"
#   vhci-usb.sh available  # exit 0 if vhci_hcd is usable
#
set -u
DATA="${DATA:-/root/InfernoData}"
R="$DATA/restore"
J="$R/vhci"
USB_SOCK="${USB_SOCK:-$R/usb.sock}"
PREFIX="${PREFIX:-/opt/inferno-restore}"
HERE=$(cd "$(dirname "$0")" && pwd)
BRIDGE="${BRIDGE:-$PREFIX/bin/vhci-bridge}"
VHCI_SYSFS="${VHCI_SYSFS:-}"
MUX_UDID_SOCK="${MUX_UDID_SOCK:-}"  # unused; local usbmuxd uses default /var/run/usbmuxd

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*"; exit 1; }

find_vhci() {
  local d
  for d in "$VHCI_SYSFS" \
           /sys/devices/platform/vhci_hcd.0 \
           /sys/devices/platform/vhci_hcd \
           /sys/bus/platform/devices/vhci_hcd.0; do
    [ -n "$d" ] && [ -w "$d/attach" ] && { echo "$d"; return 0; }
  done
  return 1
}

available() {
  find_vhci >/dev/null || return 1
  [ -x "$BRIDGE" ] && return 0
  [ -f "$HERE/vhci-bridge/bridge.c" ] && return 0
  [ -f "$HERE/vhci-bridge.c" ] && return 0
  [ -f "$HERE/vhci-bridge.tgz" ] && return 0
  [ -f "$HERE/vhci-bridge.tar.gz" ] && return 0
  [ -f /data/local/tmp/qemu-t8030/vhci-bridge.c ] && return 0
  [ -f /data/local/tmp/qemu-t8030/vhci-bridge/bridge.c ] && return 0
  return 1
}

ensure_bridge() {
  if [ -x "$BRIDGE" ]; then return 0; fi
  local srcc=""
  if [ -f "$HERE/vhci-bridge/bridge.c" ]; then srcc="$HERE/vhci-bridge/bridge.c"
  elif [ -f "$HERE/vhci-bridge.c" ]; then srcc="$HERE/vhci-bridge.c"
  elif [ -f /root/vhci-bridge.c ]; then srcc=/root/vhci-bridge.c
  elif [ -f /data/local/tmp/qemu-t8030/vhci-bridge.c ]; then srcc=/data/local/tmp/qemu-t8030/vhci-bridge.c
  elif [ -f /data/local/tmp/qemu-t8030/vhci-bridge/bridge.c ]; then srcc=/data/local/tmp/qemu-t8030/vhci-bridge/bridge.c
  elif [ -f "$HERE/vhci-bridge.tgz" ] || [ -f /root/vhci-bridge.tgz ]; then
    local tgz="$HERE/vhci-bridge.tgz"
    [ -f "$tgz" ] || tgz=/root/vhci-bridge.tgz
    mkdir -p "$HERE"
    tar -xzf "$tgz" -C "$HERE" 2>/dev/null || tar -xzf "$tgz" -C /root
    [ -f "$HERE/vhci-bridge/bridge.c" ] && srcc="$HERE/vhci-bridge/bridge.c"
  fi
  [ -n "$srcc" ] || die "vhci-bridge not at $BRIDGE; no source (checked $HERE/vhci-bridge{,.c,.tar.gz}, /data/local/tmp/qemu-t8030/). Reinstall qemu-t8030 v1.4.4+"
  log "building vhci-bridge from $srcc"
  mkdir -p "$(dirname "$BRIDGE")"
  if [ "$(basename "$srcc")" = "vhci-bridge.c" ]; then
    gcc -O2 -Wall -pthread -o "$BRIDGE" "$srcc" \
      || die "vhci-bridge build failed (need gcc in the chroot)"
  else
    gcc -O2 -Wall -pthread -o "$BRIDGE" -I"$(dirname "$srcc")" "$srcc" \
      || die "vhci-bridge build failed (need gcc in the chroot)"
  fi
}

ensure_usbfs() {
  # Android bind-mounts /dev into the chroot; VHCI creates nodes under
  # /dev/bus/usb. Make sure the tree exists and usbfs is mounted if needed.
  mkdir -p /dev/bus/usb
  if [ ! -d /sys/bus/usb/devices ]; then
    warn "/sys/bus/usb missing - is sysfs mounted?"
  fi
  # Some Android builds need usbfs explicitly:
  if [ ! -d /proc/bus/usb ] && ! mount | grep -q 'usbfs\|/dev/bus/usb'; then
    mount -t usbfs usbfs /dev/bus/usb 2>/dev/null || true
  fi
}

start_usbmuxd_local() {
  mkdir -p /var/run /run/lockdown "$J"
  # no-udev libusb: usbmuxd gets hotplug via netlink. -f foreground in a
  # setsid so we can kill it later; listen on the default unix socket so
  # idevice_id / idevicerestore need no USBMUXD_SOCKET_ADDRESS.
  if pgrep -x usbmuxd >/dev/null 2>&1; then
    log "usbmuxd already running"
    return 0
  fi
  if [ -x "$PREFIX/sbin/usbmuxd" ]; then
    PATH="$PREFIX/sbin:$PREFIX/bin:$PATH" \
      LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      setsid "$PREFIX/sbin/usbmuxd" -f -v -U root -P NONE \
        >> "$J/usbmuxd.log" 2>&1 < /dev/null &
    echo $! > "$J/usbmuxd.pid"
  else
    setsid usbmuxd -f -v -U root -P NONE >> "$J/usbmuxd.log" 2>&1 < /dev/null &
    echo $! > "$J/usbmuxd.pid"
  fi
  sleep 1
  kill -0 "$(cat "$J/usbmuxd.pid")" 2>/dev/null || die "usbmuxd did not start (see $J/usbmuxd.log)"
  log "usbmuxd started (pid $(cat "$J/usbmuxd.pid"), log $J/usbmuxd.log)"
}

rescan_hint() {
  # Without udev, a device that appeared before usbmuxd started can be missed.
  # Restarting usbmuxd forces a libusb cold plug scan.
  local p; p=$(cat "$J/usbmuxd.pid" 2>/dev/null || true)
  [ -n "$p" ] && kill "$p" 2>/dev/null || pkill -x usbmuxd 2>/dev/null || true
  sleep 1
  start_usbmuxd_local
}

start() {
  available || die "VHCI not available (flash Larry kernel with USBIP/VHCI, or use companion-vm.sh)"
  ensure_bridge
  ensure_usbfs
  mkdir -p "$J" "$(dirname "$USB_SOCK")"
  rm -f "$USB_SOCK"
  local vhci; vhci=$(find_vhci)
  start_usbmuxd_local
  : > "$J/bridge.log"
  setsid "$BRIDGE" -s "$USB_SOCK" -V "$vhci" -v >> "$J/bridge.log" 2>&1 < /dev/null &
  echo $! > "$J/bridge.pid"
  local i
  for i in $(seq 1 50); do
    [ -S "$USB_SOCK" ] && break
    kill -0 "$(cat "$J/bridge.pid")" 2>/dev/null || {
      cat "$J/bridge.log" >&2
      die "vhci-bridge exited before creating $USB_SOCK"
    }
    sleep 0.1
  done
  [ -S "$USB_SOCK" ] || die "vhci-bridge did not create $USB_SOCK"
  echo "vhci" > "$J/mode"
  log "VHCI USB ready: bridge pid $(cat "$J/bridge.pid"), socket $USB_SOCK, sysfs $vhci"
  log "usbmuxd is local (no USBMUXD_SOCKET_ADDRESS); idevice_id should list the iPhone after iOS connects"
}

stop() {
  local p
  p=$(cat "$J/bridge.pid" 2>/dev/null || true)
  [ -n "$p" ] && kill "$p" 2>/dev/null || true
  pkill -f '[v]hci-bridge' 2>/dev/null || true
  p=$(cat "$J/usbmuxd.pid" 2>/dev/null || true)
  [ -n "$p" ] && kill "$p" 2>/dev/null || true
  # only kill a usbmuxd we started for vhci (pid file present)
  rm -f "$J/bridge.pid" "$J/usbmuxd.pid" "$USB_SOCK" "$J/mode"
  # detach any leftover vhci port
  local vhci; vhci=$(find_vhci 2>/dev/null || true)
  if [ -n "$vhci" ] && [ -w "$vhci/detach" ]; then
    awk '/^hs / && $3 != "004" {print $2}' "$vhci/status" 2>/dev/null | while read -r port; do
      echo "$port" > "$vhci/detach" 2>/dev/null || true
    done
  fi
  log "VHCI USB stopped"
}

status() {
  if ! find_vhci >/dev/null; then echo "missing"; return 0; fi
  local p; p=$(cat "$J/bridge.pid" 2>/dev/null || true)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then echo "running"; else echo "stopped"; fi
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  available) available ;;
  rescan) rescan_hint ;;
  *) echo "usage: $0 start|stop|status|available|rescan"; exit 2 ;;
esac
