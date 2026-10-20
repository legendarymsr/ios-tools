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
#   vhci-usb.sh rescan     # sync /dev/bus/usb nodes + restart usbmuxd
#   vhci-usb.sh sync-dev   # mknod /dev/bus/usb from sysfs (+ host bind)
#   vhci-usb.sh diagnostics
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
  # Rebuild when the shipped source is newer than the binary (app updates).
  if [ -x "$BRIDGE" ]; then
    local s
    for s in "$HERE/vhci-bridge/bridge.c" "$HERE/vhci-bridge.c"; do
      [ -f "$s" ] && [ "$s" -nt "$BRIDGE" ] && { log "vhci-bridge source newer than binary - rebuilding"; rm -f "$BRIDGE"; break; }
    done
    [ -x "$BRIDGE" ] && return 0
  fi
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
  [ -n "$srcc" ] || die "vhci-bridge not at $BRIDGE; no source (checked $HERE/vhci-bridge{,.c,.tgz}, /data/local/tmp/qemu-t8030/). Reinstall qemu-t8030 v1.4.5+"
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

# Android: enter-debian bind-mounts /dev once. VHCI devices appear later via
# ueventd on the *host* tree; the chroot may miss nodes if /dev/bus/usb is a
# separate mount or ueventd never mknods for usbip. Do NOT mount usbfs over
# /dev/bus/usb (that hides char nodes). Instead: bind host usb bus if richer,
# and always mknod from /sys/bus/usb/devices/*/dev.
sync_usb_devnodes() {
  mkdir -p /dev/bus/usb
  if [ ! -d /sys/bus/usb/devices ]; then
    warn "/sys/bus/usb/devices missing - is sysfs mounted into the chroot?"
  fi

  local host_usb=/proc/1/root/dev/bus/usb
  if [ -d "$host_usb" ]; then
    local hn cn
    hn=$(find "$host_usb" -type c 2>/dev/null | wc -l)
    cn=$(find /dev/bus/usb -type c 2>/dev/null | wc -l)
    if [ "$hn" -gt "$cn" ]; then
      # Re-bind host's usb bus so Android ueventd nodes are visible here.
      if mountpoint -q /dev/bus/usb 2>/dev/null; then
        umount /dev/bus/usb 2>/dev/null || umount -l /dev/bus/usb 2>/dev/null || true
      fi
      mkdir -p /dev/bus/usb
      if mount --bind "$host_usb" /dev/bus/usb 2>/dev/null \
         || busybox mount --bind "$host_usb" /dev/bus/usb 2>/dev/null; then
        log "bind-mounted host $host_usb -> /dev/bus/usb ($hn char nodes)"
      else
        warn "could not bind-mount $host_usb (hn=$hn cn=$cn); falling back to mknod"
      fi
    fi
  fi

  # Unmount a mistaken usbfs that would hide char devices
  if mount | grep -q 'usbfs on /dev/bus/usb'; then
    warn "usbfs is mounted on /dev/bus/usb - unmounting (libusb needs char nodes)"
    umount /dev/bus/usb 2>/dev/null || umount -l /dev/bus/usb 2>/dev/null || true
    mkdir -p /dev/bus/usb
  fi

  local d busnum devnum maj min dir node made=0
  for d in /sys/bus/usb/devices/[0-9]*:* /sys/bus/usb/devices/[0-9]*; do
    [ -e "$d" ] || continue
    [ -f "$d/busnum" ] && [ -f "$d/devnum" ] && [ -f "$d/dev" ] || continue
    # skip interfaces (N-N:N.N) — only real usb_device has busnum+devnum+dev
    busnum=$(cat "$d/busnum" 2>/dev/null) || continue
    devnum=$(cat "$d/devnum" 2>/dev/null) || continue
    maj=$(cut -d: -f1 "$d/dev" 2>/dev/null) || continue
    min=$(cut -d: -f2 "$d/dev" 2>/dev/null) || continue
    [ -n "$busnum" ] && [ -n "$devnum" ] && [ -n "$maj" ] && [ -n "$min" ] || continue
    dir=$(printf '/dev/bus/usb/%03d' "$busnum")
    node=$(printf '%s/%03d' "$dir" "$devnum")
    mkdir -p "$dir"
    if [ ! -e "$node" ]; then
      if mknod "$node" c "$maj" "$min" 2>/dev/null; then
        made=$((made + 1))
        log "mknod $node c $maj:$min ($(basename "$d") vid=$(cat "$d/idVendor" 2>/dev/null) pid=$(cat "$d/idProduct" 2>/dev/null))"
      else
        warn "mknod $node c $maj:$min failed: $?"
      fi
    fi
    chmod 666 "$node" 2>/dev/null || true
  done
  [ "$made" -gt 0 ] && log "created $made USB device node(s) under /dev/bus/usb"
  return 0
}

ensure_usbfs() {
  # Name kept for callers; modern path is sync_usb_devnodes (no usbfs overlay).
  sync_usb_devnodes
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
  # Sync device nodes first (common miss: kernel enumerated, no /dev node in
  # chroot), then restart usbmuxd so libusb cold-plugs again.
  sync_usb_devnodes
  local p; p=$(cat "$J/usbmuxd.pid" 2>/dev/null || true)
  [ -n "$p" ] && kill "$p" 2>/dev/null || pkill -x usbmuxd 2>/dev/null || true
  sleep 1
  start_usbmuxd_local
}

diagnostics() {
  echo "===== VHCI / USB diagnostics ====="
  local vhci; vhci=$(find_vhci 2>/dev/null || true)
  echo "--- vhci sysfs ($vhci) ---"
  if [ -n "$vhci" ]; then
    echo "attach writable: $([ -w "$vhci/attach" ] && echo yes || echo no)"
    for s in status status.0 status.1; do
      [ -f "$vhci/$s" ] || continue
      echo ">> $s"
      cat "$vhci/$s" 2>/dev/null || true
    done
  else
    echo "(no vhci_hcd)"
  fi
  echo "--- /sys/bus/usb/devices (usb_device) ---"
  local d
  for d in /sys/bus/usb/devices/[0-9]*; do
    [ -f "$d/busnum" ] && [ -f "$d/idVendor" ] || continue
    printf '  %s bus=%s dev=%s vid=%s pid=%s class=%s speed=%s\n' \
      "$(basename "$d")" \
      "$(cat "$d/busnum" 2>/dev/null)" \
      "$(cat "$d/devnum" 2>/dev/null)" \
      "$(cat "$d/idVendor" 2>/dev/null)" \
      "$(cat "$d/idProduct" 2>/dev/null)" \
      "$(cat "$d/bDeviceClass" 2>/dev/null)" \
      "$(cat "$d/speed" 2>/dev/null)"
  done
  echo "--- Apple (05ac) devices ---"
  for d in /sys/bus/usb/devices/[0-9]*; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "05ac" ] || continue
    printf '  %s pid=%s manufacturer=%s product=%s\n' \
      "$(basename "$d")" "$(cat "$d/idProduct" 2>/dev/null)" \
      "$(cat "$d/manufacturer" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)"
  done
  echo "--- /dev/bus/usb (chroot) ---"
  find /dev/bus/usb -type c -printf '  %p %m %CY\n' 2>/dev/null \
    || find /dev/bus/usb -type c -ls 2>/dev/null \
    || echo "  (empty or missing)"
  ls -laR /dev/bus/usb 2>/dev/null | head -40 || true
  echo "--- host /proc/1/root/dev/bus/usb ---"
  find /proc/1/root/dev/bus/usb -type c 2>/dev/null | head -40 || echo "  (unavailable)"
  echo "--- lsusb ---"
  if command -v lsusb >/dev/null 2>&1; then
    lsusb 2>&1 || true
  elif [ -x "$PREFIX/bin/lsusb" ]; then
    "$PREFIX/bin/lsusb" 2>&1 || true
  else
    echo "(no lsusb binary; sysfs list above is the substitute)"
  fi
  echo "--- dmesg (usb|vhci|usbip, last 50) ---"
  if command -v dmesg >/dev/null 2>&1; then
    dmesg 2>/dev/null | grep -iE 'usb|vhci|usbip' | tail -n 50 || true
  else
    # Android often has no dmesg in chroot PATH; try host
    /system/bin/dmesg 2>/dev/null | grep -iE 'usb|vhci|usbip' | tail -n 50 \
      || cat /proc/1/root/proc/kmsg 2>/dev/null | grep -iE 'usb|vhci|usbip' | tail -n 20 \
      || echo "(dmesg unavailable in chroot)"
  fi
  echo "--- bridge.log (last 40) ---"
  tail -n 40 "$J/bridge.log" 2>/dev/null || echo "(no bridge log)"
  echo "--- usbmuxd.log (last 30) ---"
  tail -n 30 "$J/usbmuxd.log" 2>/dev/null || echo "(no usbmuxd log)"
  echo "--- mounts involving /dev/bus ---"
  mount | grep -E '/dev/bus|/dev ' || true
  echo "===== end diagnostics ====="
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
  log "usbmuxd is local (no USBMUXD_SOCKET_ADDRESS); idevice_id should list the iPhone after iOS connects + host enumerates"
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
    awk '/^hs / && $3 != "004" && $3 != "4" {print $2}' "$vhci/status" 2>/dev/null | while read -r port; do
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
  sync-dev|sync) sync_usb_devnodes ;;
  diagnostics|diag) diagnostics ;;
  *) echo "usage: $0 start|stop|status|available|rescan|sync-dev|diagnostics"; exit 2 ;;
esac
