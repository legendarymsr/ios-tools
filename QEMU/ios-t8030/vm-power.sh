#!/usr/bin/env bash
# vm-power.sh off|status - power off the Inferno t8030 VM.
# 1. system_powerdown via the QEMU monitor socket ($DATA/qemu-monitor.sock),
#    wait up to POWERDOWN_WAIT (20 s) for the VM to stop;
# 2. "quit" via the monitor (clean QEMU exit, disks flushed);
# 3. kill the process (TERM, then KILL).
# The USB-host VM (companion) is stopped as well.
set -u
DATA="${DATA:-/root/InfernoData}"
HERE=$(cd "$(dirname "$0")" && pwd)
MON="${MON:-$DATA/qemu-monitor.sock}"
PAT="${VM_PATTERN:-qemu-system-aarch64.*-M t8030}"
log() { printf '[power] %s\n' "$*"; }
pids() { pgrep -f "$PAT" 2>/dev/null; }
running() { [ -n "$(pids)" ]; }
wait_gone() { local i; for i in $(seq 1 "$1"); do running || return 0; sleep 1; done; ! running; }
mon() {
  [ -S "$MON" ] || return 1
  python3 - "$MON" "$1" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
try: s.recv(4096)
except Exception: pass
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.5); s.close()
PY
}
off() {
  if ! running; then
    log "the iOS VM is not running"
  else
    log "iOS VM running (pid $(pids | tr '\n' ' '))"
    if mon system_powerdown 2>/dev/null; then
      log "sent system_powerdown via the QEMU monitor - waiting up to ${POWERDOWN_WAIT:-20} s"
      if wait_gone "${POWERDOWN_WAIT:-20}"; then log "VM powered off"; fi
      if running; then
        log "no shutdown after ${POWERDOWN_WAIT:-20} s (the guest ignored it) - sending 'quit' (QEMU exits, disks flushed)"
        mon quit 2>/dev/null; wait_gone 15 && log "QEMU quit"
      fi
    else
      log "no QEMU monitor socket at $MON (VM started before v1.5.0?) - killing the process instead"
    fi
    if running; then
      log "killing: pkill -f '$PAT'"
      pkill -TERM -f "$PAT"; wait_gone 10 || { pkill -KILL -f "$PAT"; wait_gone 5; }
    fi
    if running; then log "ERROR: could not stop pid $(pids | tr '\n' ' ')"; return 1; fi
    log "iOS VM is off"
  fi
  if [ -f "$HERE/companion-vm.sh" ] && [ "$(bash "$HERE/companion-vm.sh" status 2>/dev/null)" != stopped ]; then
    bash "$HERE/companion-vm.sh" stop >/dev/null 2>&1 && log "USB-host VM stopped"
  fi
  rm -f "$MON"
  return 0
}
case "${1:-off}" in
  off) off ;;
  status) if running; then log "iOS VM running (pid $(pids | tr '\n' ' '))"; else log "iOS VM not running"; fi ;;
  *) echo "usage: $0 off|status"; exit 2 ;;
esac
