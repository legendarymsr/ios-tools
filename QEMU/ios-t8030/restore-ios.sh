#!/usr/bin/env bash
#
# restore-ios.sh -- automatic IPSW restore of the Inferno t8030 guest, run
# INSIDE the Debian chroot (app step "5. Restore iOS (automatic)").
#
# What ChefKiss documents (chefkiss.dev/guides/inferno/companion-setup/,
# .../running-restoring/, .../fs-patches/), and what this script does instead:
#   1. "Companion VM" with usb-tcp-remote + usbmuxd       -> companion-vm.sh usbmux
#      (a tiny aarch64 virt VM here; idevicerestore itself runs in the chroot
#       and talks to that usbmuxd over TCP via USBMUXD_SOCKET_ADDRESS)
#   2. Main VM with the Erase restore ramdisk + usb-conn-* -> run-t8030.sh, RESTORE_MODE=1
#   3. idevicerestore --erase --restore-mode -i 0x1122334455667788 IPSW -T root_ticket.der
#      ("The VM should automatically close when restore stage 1 is finished")
#   4. Filesystem patches (macOS-only in the guide)         -> companion-vm.sh apfs-run
#      (linux-apfs-rw inside the USB-host VM: InfernoFSPatcher on the dyld cache
#       + Disabled=true for vmd/CommCenter*/locationd in launchd.plist)
#   5. Next normal boot finishes data migration (stage 2)   -> app step "Boot iOS"
#
# Resumable: progress is kept in $DATA/restore/state. Re-running after a
# failure restores the blank-disk backup and starts stage 1 again; a finished
# stage is never repeated. Running it while a restore is already going on just
# re-attaches to its log. FORCE_RESTORE=1 wipes an already restored guest back
# to the blank backup and restores again.
#
# Env: DATA (/root/InfernoData), ECID (0x1122334455667788), MUX_PORT (27015),
#      DEVICE_TIMEOUT (s to wait for the restore ramdisk, default 10800),
#      SKIP_FS_PATCHES=1 (mark restored without the FS patches).
set -u
DATA="${DATA:-/root/InfernoData}"
R="$DATA/restore"
PREFIX="${PREFIX:-/opt/inferno-restore}"
HERE=$(cd "$(dirname "$0")" && pwd)
ECID="${ECID:-0x1122334455667788}"
MUX_PORT="${MUX_PORT:-27015}"
export DATA PREFIX MUX_PORT
export USB_SOCK="$R/usb.sock"
DISKS="root firmware syscfg ctrl_bits nvram effaceable panic_log sep_nvram sep_ssc"

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*"; echo "failed:$(state)" > "$R/state.failed" 2>/dev/null; exit 1; }
state() { cat "$R/state" 2>/dev/null || echo new; }
set_state() { echo "$1" > "$R/state"; log "state -> $1"; }
mkdir -p "$R"

# ---------------------------------------------------------------- front end --
# The app's root shell can be killed when Android reclaims the app. The real
# work runs detached (setsid) and the front end only follows its log, so
# re-tapping the step re-attaches instead of starting a second restore.
if [ "${1:-}" != "--worker" ]; then
  case "${1:-}" in
    status) echo "restore state: $(state)"; [ -f "$DATA/RESTORED" ] && echo "RESTORED: $(cat "$DATA/RESTORED")"; exit 0 ;;
    stop)
      p=$(cat "$R/worker.pid" 2>/dev/null || true)
      [ -n "$p" ] && kill "$p" 2>/dev/null && log "stopped restore worker $p"
      pkill -f 'qemu-system-aarch64.*-M t8030' 2>/dev/null || true
      bash "$HERE/companion-vm.sh" stop || true
      exit 0 ;;
  esac
  if [ -f "$DATA/RESTORED" ] && [ "${FORCE_RESTORE:-0}" != 1 ]; then
    log "already restored ($(cat "$DATA/RESTORED")). Next: Boot iOS. FORCE_RESTORE=1 restores again from the blank backup."
    exit 0
  fi
  p=$(cat "$R/worker.pid" 2>/dev/null || true)
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    log "a restore is already running (pid $p) - attaching to its log"
  else
    rm -f "$R/worker.rc"
    : > "$R/restore.log"
    FORCE_RESTORE="${FORCE_RESTORE:-0}" setsid bash "$0" --worker >> "$R/restore.log" 2>&1 < /dev/null &
    p=$!
    echo "$p" > "$R/worker.pid"
    log "restore started in the background (pid $p); log: $R/restore.log"
    log "closing the app does not stop it; tap this step again to re-attach"
  fi
  tail -n +1 -f --pid="$p" "$R/restore.log" 2>/dev/null || { while kill -0 "$p" 2>/dev/null; do sleep 5; done; cat "$R/restore.log"; }
  rc=$(cat "$R/worker.rc" 2>/dev/null || echo 1)
  exit "$rc"
fi

# ------------------------------------------------------------------ worker --
trap 'rc=$?; echo "$rc" > "$R/worker.rc"; cleanup_vms; exit $rc' EXIT
IOS_PID=""
cleanup_vms() {
  if [ -n "$IOS_PID" ] && kill -0 "$IOS_PID" 2>/dev/null; then
    kill "$IOS_PID" 2>/dev/null; sleep 3; kill -9 "$IOS_PID" 2>/dev/null || true
  fi
  bash "$HERE/companion-vm.sh" stop >/dev/null 2>&1 || true
}
echo "===== restore worker $(date -Iseconds 2>/dev/null || date) state=$(state) ====="

# --- preflight ---
[ -f "$DATA/run.env" ] || die "no $DATA/run.env - run step 4 (Download & Configure) first"
set -a; . "$DATA/run.env"; set +a
[ -n "${RAMDISK:-}" ] && [ -f "$RAMDISK" ] || die "restore ramdisk (RAMDISK in run.env) missing - re-run step 4"
[ -f "$DATA/root_ticket.der" ] || die "missing $DATA/root_ticket.der - re-run step 4"
for f in $DISKS; do [ -f "$DATA/$f" ] || die "missing disk $DATA/$f - re-run step 4"; done
[ -x /root/Inferno/build/qemu-system-aarch64 ] || die "Inferno is not built - run step 3"
[ -f "$HERE/run-t8030.sh" ] || die "run-t8030.sh missing next to $0"

# IPSW: the downloaded zip (ChefKiss's tested path); if it was deleted, the
# fully extracted Restore/ folder works too (idevicerestore accepts a folder).
IPSW_ARG=""
if [ -n "${IPSW:-}" ] && [ -f "$IPSW" ]; then IPSW_ARG="$IPSW"
elif [ -f "${RESTORE:-$DATA/Restore}/BuildManifest.plist" ] \
     && find "${RESTORE:-$DATA/Restore}" -maxdepth 1 -name '*.dmg' -size +2000M | grep -q .; then
  IPSW_ARG="${RESTORE:-$DATA/Restore}"
else die "the IPSW (${IPSW:-?}) is gone and Restore/ has no OS image - re-run step 4 to download it again"; fi
log "IPSW: $IPSW_ARG"

avail_kb=$(df -Pk "$DATA" | awk 'NR==2{print $4}')
[ "${avail_kb:-0}" -gt 6291456 ] || warn "less than 6 GB free on $DATA - the restored disk needs ~5 GB"

# --- tools ---
log "checking restore tools (first run builds them: ~10-30 min on a phone)"
bash "$HERE/build-restore-tools.sh" || die "building the restore tools failed (see above)"
export PATH="$PREFIX/bin:$PREFIX/sbin:$PATH"

root_blank() { [ "$(head -c 1048576 "$DATA/root" | tr -d '\000' | wc -c)" = "0" ]; }

backup_blank() {
  if [ -f "$R/blank/.complete" ]; then return 0; fi
  mkdir -p "$R/blank"
  if root_blank; then
    log "backing up the blank disks to $R/blank (sparse, small)"
    for f in $DISKS; do cp --sparse=always "$DATA/$f" "$R/blank/$f" || die "backup of $f failed"; done
  else
    warn "root disk is not blank and there is no backup: recreating blank disks of the same sizes"
    for f in $DISKS; do
      rm -f "$R/blank/$f"; truncate -s "$(stat -c %s "$DATA/$f")" "$R/blank/$f" || die "could not create blank $f"
    done
  fi
  touch "$R/blank/.complete"
}

restore_blank() {
  [ -f "$R/blank/.complete" ] || die "no blank-disk backup in $R/blank"
  log "resetting all Inferno disks from the blank backup"
  for f in $DISKS; do
    cp --sparse=always "$R/blank/$f" "$DATA/$f.tmp" && mv -f "$DATA/$f.tmp" "$DATA/$f" || die "could not reset $f"
  done
  rm -f "$DATA/RESTORED" "$DATA/JAILBREAK_APPLIED"
}

if [ "${FORCE_RESTORE:-0}" = 1 ]; then
  [ -f "$R/blank/.complete" ] || die "FORCE_RESTORE=1 needs the blank backup in $R/blank (made on the first restore)"
  restore_blank; set_state new
fi

backup_blank
case "$(state)" in
  new|stage1-done|fs-patched) ;;
  *) warn "previous restore attempt stopped in state '$(state)' - starting stage 1 again from blank disks"
     restore_blank; set_state new ;;
esac

# Keep every attempt's full serial log and show the real panic string: the
# "IOPlatformPanicAction -> ...WatchDogTimer / ...PMGR" and "wdog panic
# (attempt 1)" lines are printed for EVERY iOS panic; the cause is the
# "panic(cpu N caller ...): ..." line above them.
keep_serial() {
  [ -s "$R/ios-serial.log" ] || return 0
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  cp -f "$R/ios-serial.log" "$R/ios-serial.$ts.log" && log "full iOS serial log kept: $R/ios-serial.$ts.log"
}
show_panic() {
  local f="$R/ios-serial.log" n
  [ -s "$f" ] || { warn "the iOS serial log is empty"; tail -n 30 "$R/inferno.log"; return 0; }
  n=$(tr -d '\r' < "$f" | grep -n -m1 -E 'panic\(|[Pp]anic:|SEP Panic|panicString|IOPlatformPanicAction' | cut -d: -f1)
  if [ -n "$n" ]; then
    echo "----- iOS serial: 40 lines before/after the first panic line (line $n) -----"
    tr -d '\r' < "$f" | sed -n "$(( n > 40 ? n - 40 : 1 )),$(( n + 40 ))p"
    echo "----- end -----"
  else
    echo "----- iOS serial: last 60 lines (no panic line found) -----"
    tr -d '\r' < "$f" | tail -n 60
  fi
  echo "----- inferno.log (QEMU) -----"; tail -n 15 "$R/inferno.log"
  if tr -d '\r' < "$f" | grep -qE 'dart-sep|t8020dart invalid lock state|SEP ROM boot panic|SEP Panic'; then
    echo "[!] this is a SEP-side panic. ChefKiss FAQ: 'bad SEP ROM or SEP Firmware'."
    echo "[!] re-run step 4 (it re-checks the SEP ROM and rebuilds a bad sep-firmware...new.img4),"
    echo "[!] then run this step again. Check: python3 $HERE/check-sep.py fw $DATA/sep-firmware.n104.RELEASE.new.img4"
  fi
  keep_serial
}

# idevicerestore --plain-progress prints "progress: STEP FRACTION" and
# "LABEL:  PCT" lines very often; keep one line per 5 % per step/label.
progress_filter() {
  python3 -u -c '
import re, sys
last = {}
p1 = re.compile(r"^progress: (\d+) ([0-9.]+)$")
p2 = re.compile(r"^(.{1,60}?):\s+([0-9]+(?:\.[0-9]+)?)$")
for raw in sys.stdin:
    for line in re.split(r"\r", raw.rstrip("\n")):
        line = line.strip()
        if not line:
            continue
        m = p1.match(line)
        if m:
            key, pct = "step" + m.group(1), float(m.group(2)) * 100
            label = "progress (step %s)" % m.group(1)
        else:
            m = p2.match(line)
            if not m:
                print(line, flush=True)
                continue
            key, pct, label = m.group(1), float(m.group(2)), m.group(1)
        b = int(pct // 5)
        if last.get(key) == b:
            continue
        last[key] = b
        print("[%%] %s: %3d%%" % (label, int(pct)), flush=True)
'
}

# ------------------------------------------------------------ stage 1 --------
if [ "$(state)" = new ]; then
  if pgrep -f 'qemu-system-aarch64.*-M t8030' >/dev/null 2>&1; then
    die "an iOS VM is already running (Boot step?) - stop it first"
  fi
  set_state stage1-running
  COMPANION_SMP="${COMPANION_SMP:-1}" bash "$HERE/companion-vm.sh" usbmux || die "the USB-host VM did not start"

  log "booting the iOS restore ramdisk ($(basename "$RAMDISK")); watch it with 'Open VNC viewer'"
  : > "$R/ios-serial.log"
  RESTORE_MODE=1 SMP="${RESTORE_SMP:-${SMP:-7}}" USB_CONN_TYPE=unix USB_CONN_ADDR="$USB_SOCK" \
    SERIAL_QEMU="-serial file:$R/ios-serial.log" \
    setsid bash "$HERE/run-t8030.sh" > "$R/inferno.log" 2>&1 < /dev/null &
  IOS_PID=$!

  log "waiting for the restore ramdisk to show up over USB (TCG: often 10-40 min)"
  t0=$(date +%s); next=0; udid=""
  while :; do
    kill -0 "$IOS_PID" 2>/dev/null || { show_panic; die "the iOS VM exited before the device appeared (panic/log above)"; }
    bash "$HERE/companion-vm.sh" status | grep -q running || { tail -n 30 "$DATA/companion/console.log" "$DATA/companion/job.log"; die "the USB-host VM stopped (logs above)"; }
    udid=$(USBMUXD_SOCKET_ADDRESS="127.0.0.1:$MUX_PORT" idevice_id -l 2>/dev/null | head -n1)
    [ -n "$udid" ] && break
    el=$(( $(date +%s) - t0 ))
    [ "$el" -lt "${DEVICE_TIMEOUT:-10800}" ] || { show_panic; grep -A6 'lsusb' "$DATA/companion/job.log" | tail -n 8; die "no device after ${DEVICE_TIMEOUT:-10800} s"; }
    if [ "$el" -ge "$next" ]; then
      printf '[*] %3d min: iOS: %s\n' $((el / 60)) "$(tail -c 2000 "$R/ios-serial.log" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-110)"
      next=$((next + 120))
    fi
    sleep 10
  done
  log "device in restore mode: $udid ($(( ($(date +%s) - t0) / 60 )) min)"

  log "running idevicerestore (erase restore; the guest closes itself when stage 1 is done)"
  mkdir -p "$R/cache"
  set -o pipefail
  USBMUXD_SOCKET_ADDRESS="127.0.0.1:$MUX_PORT" stdbuf -oL -eL \
    idevicerestore --erase --restore-mode --no-input --plain-progress -i "$ECID" -T "$DATA/root_ticket.der" \
      --cache-path "$R/cache" "$IPSW_ARG" 2>&1 | tee "$R/idevicerestore.log.raw" | progress_filter
  irc=$?
  set +o pipefail
  if [ "$irc" != 0 ]; then
    show_panic
    die "idevicerestore failed (exit $irc). Full log: $R/idevicerestore.log.raw. Tap the step again to retry from the blank backup."
  fi
  grep -q '^DONE' "$R/idevicerestore.log.raw" || warn "idevicerestore exited 0 but did not print DONE"
  log "idevicerestore finished; waiting for the iOS VM to close (up to 15 min)"
  for i in $(seq 1 180); do kill -0 "$IOS_PID" 2>/dev/null || break; sleep 5; done
  if kill -0 "$IOS_PID" 2>/dev/null; then
    warn "iOS VM did not close by itself - stopping it"
    kill "$IOS_PID"; sleep 10; kill -9 "$IOS_PID" 2>/dev/null || true
  fi
  IOS_PID=""
  bash "$HERE/companion-vm.sh" stop
  root_blank && die "idevicerestore reported success but the root disk is still blank"
  set_state stage1-done
fi

# ------------------------------------------------- filesystem patches --------
if [ "$(state)" = stage1-done ]; then
  if [ "${SKIP_FS_PATCHES:-0}" = 1 ]; then
    warn "SKIP_FS_PATCHES=1: not patching (stage 2 data migration may not complete without them)"
  else
    log "applying ChefKiss filesystem patches on the restored System volume (linux-apfs-rw in the USB-host VM)"
    [ -f "$HERE/patch-launchd.py" ] || die "patch-launchd.py missing next to $0"
    cp -f "$HERE/patch-launchd.py" "$R/patch-launchd.py"
    JOB='set -e
L="$SYSVOL/System/Library/xpc/launchd.plist"
C="$SYSVOL/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e"
[ -f "$DATA/restore/launchd.plist.orig" ] || cp "$L" "$DATA/restore/launchd.plist.orig"
if [ -e "$SYSVOL/.ios-tools-fs-patched" ]; then echo "[*] dyld cache already patched"; else
  [ -f "$C" ] || { echo "[ERROR] no dyld cache at $C"; exit 3; }
  echo "[*] InfernoFSPatcher: $C"
  inferno_fs_patcher "$C"
  touch "$SYSVOL/.ios-tools-fs-patched"
fi
python3 "$DATA/restore/patch-launchd.py" "$L" --no-bash
echo "[*] filesystem patches applied"'
    bash "$HERE/companion-vm.sh" apfs-run "$JOB" \
      || die "filesystem patches failed (see above). Fallback: copy $DATA/root to a Mac and follow chefkiss.dev/guides/inferno/fs-patches/, then run this step with SKIP_FS_PATCHES=1"
  fi
  set_state fs-patched
fi

if [ "$(state)" = fs-patched ]; then
  date -Iseconds > "$DATA/RESTORED" 2>/dev/null || date > "$DATA/RESTORED"
  set_state done
fi
log "restore complete. Next: tap 'Boot iOS'. The first boot finishes data migration (restore stage 2) and"
log "can take a long time under TCG before the setup screen. Don't set a passcode, don't enable location"
log "services, never use 'Erase All Content and Settings' (ChefKiss)."
exit 0
