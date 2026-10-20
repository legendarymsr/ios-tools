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
#      DEVICE_TIMEOUT (s to wait for the restore ramdisk, default 21600),
#      SKIP_FS_PATCHES=1 (mark restored without the FS patches).
set -u
DATA="${DATA:-/root/InfernoData}"
R="$DATA/restore"
PREFIX="${PREFIX:-/opt/inferno-restore}"
HERE=$(cd "$(dirname "$0")" && pwd)
ECID="${ECID:-0x1122334455667788}"
MUX_PORT="${MUX_PORT:-27015}"
INFERNO_BUILD="${INFERNO_BUILD:-/root/Inferno/build}"
export DATA PREFIX MUX_PORT
export USB_SOCK="$R/usb.sock"
DISKS="root firmware syscfg ctrl_bits nvram effaceable panic_log sep_nvram sep_ssc"

log()  { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  {
  # keep the USB-host VM's reason directly above the [ERROR] line
  [ -s "$R/companion-last.txt" ] && { echo "===== last USB-host VM stop in this run ====="; cat "$R/companion-last.txt"; }
  printf '[ERROR] %s\n' "$*"; echo "failed:$(state)" > "$R/state.failed" 2>/dev/null; exit 1; }
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
rm -f "$R/companion-last.txt"
echo "===== restore worker $(date -Iseconds 2>/dev/null || date) state=$(state) ====="

# --- preflight ---
[ -f "$DATA/run.env" ] || die "no $DATA/run.env - run step 4 (Download & Configure) first"
set -a; . "$DATA/run.env"; set +a
[ -n "${RAMDISK:-}" ] && [ -f "$RAMDISK" ] || die "restore ramdisk (RAMDISK in run.env) missing - re-run step 4"
[ -f "$DATA/root_ticket.der" ] || die "missing $DATA/root_ticket.der - re-run step 4"
for f in $DISKS; do [ -f "$DATA/$f" ] || die "missing disk $DATA/$f - re-run step 4"; done
[ -x "$INFERNO_BUILD/qemu-system-aarch64" ] || die "Inferno is not built - run step 3"
# v1.2.7/v1.2.8 patch Inferno (usb-tcp-remote crash, DART error race);
# step 3 applies it and rebuilds just that file (a few minutes).
if [ "${SKIP_PATCH_CHECK:-0}" != 1 ] && ! grep -qsx 'ios-tools-patches-6' "$INFERNO_BUILD/.ios-tools-patches"; then
  die "Inferno needs the v1.3.0 patches (USB link on both sides + DART): run step 3 again (recompiles two files + relink, ~5-10 min), then this step"
fi
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
# idevicerestore reads it from this chroot: make sure it is a readable IPSW
python3 - "$IPSW_ARG" <<'PY' || die "the IPSW $IPSW_ARG is not readable or has no BuildManifest.plist - re-run step 4"
import os, sys, zipfile
p = sys.argv[1]
if os.path.isdir(p):
    sys.exit(0 if os.access(os.path.join(p, "BuildManifest.plist"), os.R_OK) else 1)
with zipfile.ZipFile(p) as z:
    z.getinfo("BuildManifest.plist")
PY

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
  if [ "$(panic_kind)" = fatal ]; then
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
# usb_link: has the iOS VM connected to the USB-host VM's usb-tcp-remote
# socket? Inferno's iOS side connects when iOS turns its USB controller on
# (DCTL run/stop), so after the USB-host VM is restarted it reconnects the
# next time iOS brings USB up (e.g. after the ramdisk reboots).
# /proc/net/unix: "Num RefCount Protocol Flags Type St Inode Path"; the
# listener has St 01 (unconnected), the socket accepted for the iPhone has St
# 03 (connected) and the same path.
usb_link() {
  local l c
  l=$(awk -v p="$USB_SOCK" '$NF == p && $6 == "01"' /proc/net/unix 2>/dev/null | wc -l)
  c=$(awk -v p="$USB_SOCK" '$NF == p && $6 == "03"' /proc/net/unix 2>/dev/null | wc -l)
  if [ "$c" -ge 1 ]; then echo "connected"
  elif [ "$l" -ge 1 ]; then echo "not yet"
  else echo "no listener at $USB_SOCK"; fi
}
# Both QEMUs must see the same socket file: same mount namespace and root.
check_usb_socket() {
  local cp me_ns cp_ns me_root cp_root
  [ -S "$USB_SOCK" ] || die "the USB-host VM's socket $USB_SOCK does not exist"
  awk -v p="$USB_SOCK" '$NF == p && $6 == "01"' /proc/net/unix | grep -q . \
    || die "nothing listens on $USB_SOCK (USB-host VM not ready)"
  cp=$(cat "$DATA/companion/qemu.pid" 2>/dev/null || true)
  if [ -n "$cp" ] && [ -e "/proc/$cp" ]; then
    me_ns=$(readlink /proc/self/ns/mnt); cp_ns=$(readlink "/proc/$cp/ns/mnt")
    me_root=$(readlink /proc/self/root); cp_root=$(readlink "/proc/$cp/root")
    log "USB socket $USB_SOCK: listening; mount ns $me_ns (USB-host VM $cp_ns), root $me_root (USB-host VM $cp_root)"
    [ "$me_ns" = "$cp_ns" ] && [ "$me_root" = "$cp_root" ] \
      || die "the USB-host VM runs in a different mount namespace/root than the iOS VM, so the iOS VM cannot see $USB_SOCK"
  fi
}
# Print new USB link messages from both QEMUs on screen as they appear.
USBMSG_I=0; USBMSG_C=0
show_usb_msgs() {
  local n
  n=$(wc -l < "$R/inferno.log" 2>/dev/null || echo 0)
  [ "$n" -lt "$USBMSG_I" ] && USBMSG_I=0
  if [ "$n" -gt "$USBMSG_I" ]; then
    sed -n "$((USBMSG_I + 1)),${n}p" "$R/inferno.log" | grep -E 'usb-tcp-host|usb_tcp_host|Cannot connect|Socket path|Port specified|usb-conn' | cut -c1-200 | sed 's/^/[iOS QEMU] /'
    USBMSG_I=$n
  fi
  n=$(wc -l < "$DATA/companion/qemu.log" 2>/dev/null || echo 0)
  [ "$n" -lt "$USBMSG_C" ] && USBMSG_C=0
  if [ "$n" -gt "$USBMSG_C" ]; then
    sed -n "$((USBMSG_C + 1)),${n}p" "$DATA/companion/qemu.log" | grep -E 'usb-tcp-remote: (the iPhone|unexpected status)' | cut -c1-200 | sed 's/^/[USB-host QEMU] /'
    USBMSG_C=$n
  fi
}
has_panic() { tr -d '\r' < "$R/ios-serial.log" 2>/dev/null | grep -qE 'panic\(cpu|SEP Panic|SEP ROM boot panic'; }
# panic_line: the one line that names the cause
panic_line() {
  tr -d '\r' < "$R/ios-serial.log" 2>/dev/null \
    | grep -m1 -E 'panic\(cpu|SEP Panic|SEP ROM boot panic' | cut -c1-220
}
# panic_kind: "fatal" when the panic means bad SEP ROM / SEP firmware / IPSW
# files (ChefKiss troubleshooting: dart-sep TTBR invalid = "bad SEP ROM or SEP
# Firmware"; Img4Decode / SEP ROM boot panic = the img4 did not parse), else
# "retry". Everything else seen on Inferno is timing: "SEP/OS failed to boot",
# "SEP ROM timeout - no response" ("random chance that SEP won't boot ... just
# reboot", Inferno #54), watchdog, restored giving up on a lost USB host.
panic_kind() {
  local log; log=$(tr -d '\r' < "$R/ios-serial.log" 2>/dev/null)
  if printf '%s\n' "$log" | grep -qE 'SEP ROM boot panic|Img4Decode|cannot find IOAESAccelerator|AppleSEPROM.*(invalid|bad)'; then
    echo fatal
  elif printf '%s\n' "$log" | grep -qE 'dart-sep.*TTBR invalid|t8020dart invalid lock state'; then
    # run-t8030.sh only boots after check-sep.py passed the SEP ROM and SEP
    # firmware, so with verified files this is the SEP-DART timing race
    # under MTTCG, not bad files: retry. Fatal only if the check was skipped.
    if [ "${SKIP_SEP_CHECK:-0}" = 1 ]; then echo fatal; else echo retry; fi
  else
    echo retry
  fi
}
# handle_panic WHERE: show it, then reboot iOS (up to PANIC_RETRIES) or stop
handle_panic() {
  local pl kind; pl=$(panic_line); kind=$(panic_kind)
  show_panic
  stop_ios
  if [ "$kind" = fatal ]; then
    die "iOS panicked $1 (SEP/firmware files): ${pl:-see above}"
  fi
  PANIC_REBOOTS=$((PANIC_REBOOTS + 1))
  if [ "$PANIC_REBOOTS" -gt "${PANIC_RETRIES:-3}" ]; then
    die "iOS panicked $1 $PANIC_REBOOTS times: ${pl:-see above}"
  fi
  warn "iOS panicked $1: ${pl:-no panic string} - SEP files are verified, so this is a timing/USB panic; rebooting the iOS VM ($PANIC_REBOOTS/${PANIC_RETRIES:-3})"
  companion_up || restart_companion
  start_ios
}
companion_up() { bash "$HERE/companion-vm.sh" status | grep -q running; }

start_ios() {
  [ -s "$R/ios-serial.log" ] && cp -f "$R/ios-serial.log" "$R/ios-serial.$(date +%Y%m%d-%H%M%S).log"
  : > "$R/ios-serial.log"
  WAS_LINKED=0
  log "booting the iOS restore ramdisk ($(basename "$RAMDISK")); watch it with 'Open VNC viewer'"
  RESTORE_MODE=1 SMP="${RESTORE_SMP:-${SMP:-7}}" USB_CONN_TYPE=unix USB_CONN_ADDR="$USB_SOCK" \
    SERIAL_QEMU="-serial file:$R/ios-serial.log" \
    setsid bash "$HERE/run-t8030.sh" >> "$R/inferno.log" 2>&1 < /dev/null &
  IOS_PID=$!
}
stop_ios() {
  [ -n "$IOS_PID" ] || return 0
  kill "$IOS_PID" 2>/dev/null; sleep 3; kill -9 "$IOS_PID" 2>/dev/null || true
  pkill -f 'qemu-system-aarch64.*-M t8030' 2>/dev/null || true
  IOS_PID=""
}
restart_companion() {
  COMP_RESTARTS=$((COMP_RESTARTS + 1))
  bash "$HERE/companion-vm.sh" report > "$R/companion-report.$(date +%Y%m%d-%H%M%S).txt" 2>&1
  bash "$HERE/companion-vm.sh" brief > "$R/companion-last.txt" 2>&1
  cat "$R/companion-last.txt"
  [ "$COMP_RESTARTS" -le "${COMPANION_RESTARTS:-6}" ] \
    || die "the USB-host VM stopped $COMP_RESTARTS times (reason and logs above)"
  warn "the USB-host VM stopped (reason above) - restarting it ($COMP_RESTARTS/${COMPANION_RESTARTS:-6})"
  bash "$HERE/companion-vm.sh" stop >/dev/null 2>&1 || true
  bash "$HERE/companion-vm.sh" usbmux || die "the USB-host VM did not start again"
  log "USB-host VM placement (cgroup move check): $(head -c 200 "$DATA/companion/placement.txt" 2>/dev/null || echo unknown)"
  COMP_RESTART_T=$(date +%s)
  # Inferno's iOS side connects its USB cable once, when iOS turns USB on.
  # If that already happened, iOS will never see the new USB-host VM and
  # restored gives up after its 120 s "waiting for host" window - reboot the
  # iOS VM right away instead of waiting (nothing is written to disk yet).
  # The patched iOS side reconnects by itself within ~2 s; only restored's
  # 120 s "waiting for host" window may already be lost.
  if tr -d '\r' < "$R/ios-serial.log" 2>/dev/null | grep -qE 'waiting for host to trigger'; then
    if [ -n "$IOS_PID" ] && kill -0 "$IOS_PID" 2>/dev/null; then
      warn "iOS had already brought USB up - rebooting the iOS VM so it connects to the new USB-host VM"
      stop_ios; IOS_STARTS=$((IOS_STARTS + 1))
      [ "$IOS_STARTS" -le $((3 + ${PANIC_RETRIES:-3})) ] || die "the iOS VM had to be rebooted $IOS_STARTS times"
      start_ios
    fi
    COMP_RESTART_T=0
  else
    log "the iOS QEMU reconnects to the new USB-host VM by itself (it retries every 2 s)"
  fi
  WAS_LINKED=0
}

# One stage-1 attempt: returns 0 when idevicerestore finished, 10 when it is
# worth retrying from the blank disks; dies on errors a retry won't fix.
stage1_once() {
  COMP_RESTARTS=0; COMP_RESTART_T=0; IOS_STARTS=1; PANIC_REBOOTS=0; WAS_LINKED=0
  bash "$HERE/companion-vm.sh" usbmux || die "the USB-host VM did not start"
  log "USB-host VM placement (cgroup move check): $(head -c 200 "$DATA/companion/placement.txt" 2>/dev/null || echo unknown)"
  : > "$R/inferno.log"
  USBMSG_I=0; USBMSG_C=0; WFH_T=0; WFH_SAID=0
  check_usb_socket
  start_ios
  log "waiting for the restore ramdisk to show up over USB (TCG on a phone: often 20-90 min)"
  local t0 next el udid=""
  t0=$(date +%s); next=0
  while :; do
    if has_panic; then
      # give the panic log a moment to finish, then reboot or stop
      sleep 15
      handle_panic "before the device appeared"
      continue
    fi
    if ! kill -0 "$IOS_PID" 2>/dev/null; then
      show_panic
      IOS_STARTS=$((IOS_STARTS + 1))
      [ "$IOS_STARTS" -le 3 ] || die "the iOS VM exited 3 times before the device appeared (log above)"
      warn "the iOS VM exited without a panic - booting it again ($IOS_STARTS/3)"
      start_ios
    fi
    companion_up || restart_companion
    show_usb_msgs
    # The patched iOS side retries a failed connect every 2 s by itself;
    # only a wrong socket setting is fatal.
    if grep -qE 'Socket path too long|Port specified for UNIX socket' "$R/inferno.log" 2>/dev/null; then
      die "the iOS VM rejects its USB socket setting: $(grep -E 'Socket path|Port specified' "$R/inferno.log" | tail -n1)"
    fi
    # restored waits 120 s for the host. If it got there without a link,
    # say on screen which side is missing.
    if [ "$WFH_T" = 0 ] && tr -d '\r' < "$R/ios-serial.log" 2>/dev/null | grep -q 'waiting for host to trigger start of restore'; then
      WFH_T=$(date +%s)
    fi
    if [ "$WFH_T" -gt 0 ] && [ "$WFH_SAID" = 0 ] && [ $(( $(date +%s) - WFH_T )) -ge 30 ] && [ "$(usb_link)" != connected ]; then
      WFH_SAID=1
      warn "iOS is waiting for the host but the USB link is '$(usb_link)':"
      if grep -q 'usb-tcp-host: connected' "$R/inferno.log"; then
        warn "  the iOS QEMU says it connected - the USB-host VM did not accept it (see [USB-host QEMU] lines)"
      elif grep -q 'usb-tcp-host: iOS turned USB on' "$R/inferno.log"; then
        warn "  the iOS QEMU is trying to connect: $(grep 'usb-tcp-host:' "$R/inferno.log" | tail -n1 | cut -c1-160)"
      else
        warn "  the iOS QEMU never started its USB link (no 'usb-tcp-host:' line): iOS did not turn the emulated USB controller on"
      fi
      warn "  socket: $(awk -v p="$USB_SOCK" '$NF == p {print "St=" $6}' /proc/net/unix | tr '\n' ' ')"
    fi
    # After a USB-host VM restart, iOS has to bring USB up again to reconnect.
    # Give it RECONNECT_WAIT seconds, then reboot the iOS VM (nothing has been
    # written to its disks before idevicerestore starts).
    if [ "$COMP_RESTART_T" -gt 0 ] && [ "$(usb_link)" != connected ] \
       && grep -q 'usb-tcp-host: iOS turned USB on' "$R/inferno.log" 2>/dev/null \
       && [ $(( $(date +%s) - COMP_RESTART_T )) -gt "${RECONNECT_WAIT:-180}" ]; then
      warn "iOS did not reconnect to the restarted USB-host VM within ${RECONNECT_WAIT:-180} s - rebooting the iOS VM"
      stop_ios; IOS_STARTS=$((IOS_STARTS + 1))
      [ "$IOS_STARTS" -le 3 ] || die "the iOS VM did not reconnect to the USB-host VM"
      start_ios; COMP_RESTART_T=0
    fi
    [ "$(usb_link)" = connected ] && { COMP_RESTART_T=0; WAS_LINKED=1; }
    # iOS waits only 120 s for the host ("waiting for host to trigger start
    # of restore"), so poll often: idevice_id is cheap.
    udid=$(USBMUXD_SOCKET_ADDRESS="127.0.0.1:$MUX_PORT" idevice_id -l 2>/dev/null | head -n1)
    [ -n "$udid" ] && break
    el=$(( $(date +%s) - t0 ))
    [ "$el" -lt "${DEVICE_TIMEOUT:-21600}" ] || { show_panic; bash "$HERE/companion-vm.sh" report; echo "iOS USB link: $(usb_link)"; die "no device after ${DEVICE_TIMEOUT:-21600} s"; }
    if [ "$el" -ge "$next" ]; then
      printf '[*] %3d min: USB link %s; iOS: %s\n' $((el / 60)) "$(usb_link)" "$(tail -c 2000 "$R/ios-serial.log" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-110)"
      next=$((next + 120))
    fi
    sleep "${DEVICE_POLL:-2}"
  done
  log "device in restore mode: $udid ($(( ($(date +%s) - t0) / 60 )) min) - starting idevicerestore now"

  mkdir -p "$R/cache"
  local irc
  set -o pipefail
  # ASR waits up to 10 min per message under TCG (patched idevicerestore)
  IDEVICERESTORE_ASR_TIMEOUT_MS="${ASR_TIMEOUT_MS:-600000}" \
  USBMUXD_SOCKET_ADDRESS="127.0.0.1:$MUX_PORT" stdbuf -oL -eL \
    idevicerestore --erase --restore-mode --no-input --plain-progress -i "$ECID" -T "$DATA/root_ticket.der" \
      --cache-path "$R/cache" "$IPSW_ARG" 2>&1 | tee "$R/idevicerestore.log.raw" | progress_filter
  irc=$?
  set +o pipefail
  if [ "$irc" != 0 ]; then
    show_panic
    companion_up || bash "$HERE/companion-vm.sh" report
    grep -E 'ERROR|error' "$R/idevicerestore.log.raw" | tail -n 5
    if has_panic; then
      local pl; pl=$(panic_line)
      [ "$(panic_kind)" = fatal ] && die "idevicerestore failed (exit $irc), iOS panicked (SEP/firmware files): ${pl:-see above}"
      warn "idevicerestore failed (exit $irc) after an iOS panic: ${pl:-?} - retrying stage 1"
      return 10
    fi
    warn "idevicerestore failed (exit $irc). Full log: $R/idevicerestore.log.raw"
    return 10
  fi
  grep -q '^DONE' "$R/idevicerestore.log.raw" || warn "idevicerestore exited 0 but did not print DONE"
  log "idevicerestore finished; waiting for the iOS VM to close (up to 15 min)"
  local i
  for i in $(seq 1 180); do kill -0 "$IOS_PID" 2>/dev/null || break; sleep 5; done
  if kill -0 "$IOS_PID" 2>/dev/null; then
    warn "iOS VM did not close by itself - stopping it"
    kill "$IOS_PID"; sleep 10; kill -9 "$IOS_PID" 2>/dev/null || true
  fi
  IOS_PID=""
  bash "$HERE/companion-vm.sh" stop
  root_blank && die "idevicerestore reported success but the root disk is still blank"
  return 0
}

if [ "$(state)" = new ]; then
  if pgrep -f 'qemu-system-aarch64.*-M t8030' >/dev/null 2>&1; then
    die "an iOS VM is already running (Boot step?) - stop it first"
  fi
  set_state stage1-running
  attempt=1
  while :; do
    log "stage 1, attempt $attempt/${STAGE1_ATTEMPTS:-3}"
    rc=0; stage1_once || rc=$?
    [ "$rc" = 0 ] && break
    [ "$attempt" -lt "${STAGE1_ATTEMPTS:-3}" ] || die "stage 1 failed $attempt times (logs above). Tap the step again to retry."
    warn "retrying stage 1 from the blank disks"
    stop_ios
    bash "$HERE/companion-vm.sh" stop >/dev/null 2>&1 || true
    restore_blank
    attempt=$((attempt + 1))
  done
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
  # linux-apfs-rw cannot write APFS-compressed files: if the cache is one,
  # replace it with a plain copy first (same owner/mode).
  if ! python3 -c "import sys; open(sys.argv[1], \"r+b\").close()" "$C" 2>/dev/null; then
    echo "[*] dyld cache is not writable in place (APFS-compressed?) - rewriting it as a plain file (~1.5 GB)"
    cp -p "$C" "$C.ios-tools.tmp" && mv -f "$C.ios-tools.tmp" "$C"
  fi
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
