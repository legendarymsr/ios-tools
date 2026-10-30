#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# companion-vm.sh -- the small aarch64 "USB host" VM that stands in for
# ChefKiss's companion VM, run INSIDE the Debian chroot.
#
#   companion-vm.sh usbmux        start it in the background: EHCI +
#                                 usb-tcp-remote (the emulated iPhone plugs in
#                                 here) + usbmuxd, reachable from the chroot at
#                                 127.0.0.1:$MUX_PORT (USBMUXD_SOCKET_ADDRESS)
#   companion-vm.sh net           same, plus reverse tethering: the iPhone is
#                                 switched to USB ethernet (CDC-NCM); the VM
#                                 serves it DHCP (dnsmasq, 10.11.12.20+) and NATs
#                                 it out through its slirp NIC. NET_MODE=bridge:
#                                 bridged to the slirp NIC instead (10.0.2.20).
#   companion-vm.sh stop          stop it
#   companion-vm.sh apfs-run CMD  boot it with $DATA/root attached, mount the
#                                 restored iOS System volume READ-WRITE with
#                                 linux-apfs-rw, run CMD there with
#                                 SYSVOL=<mountpoint>, unmount, power off.
#                                 Returns CMD's exit code. Inferno must be off.
#
# The VM boots Debian's own arm64 kernel with a busybox initramfs
# (companion-init.sh); its userland is this chroot itself, shared read-only
# over 9p, plus $DATA shared read-write. TCG only (no KVM on the phone), so
# boot takes a minute or two.
set -eu
DATA="${DATA:-/root/InfernoData}"
PREFIX="${PREFIX:-/opt/inferno-restore}"
QEMU="${QEMU:-/root/Inferno/build/qemu-system-aarch64}"
CVM="$PREFIX/companion"
J="$DATA/companion"
MUX_PORT="${MUX_PORT:-27015}"
USB_SOCK="${USB_SOCK:-$DATA/restore/usb.sock}"
# ChefKiss's reference companion: -m 1G -smp 2 (with KVM). Under TCG a single
# vCPU is too slow for the EHCI <-> usb-tcp-remote traffic.
CMEM="${COMPANION_MEM:-1G}"
CSMP="${COMPANION_SMP:-2}"
# The VM's userland: this chroot's / (read-only). Overridable for testing.
GUEST_ROOT="${GUEST_ROOT:-/}"
IDEVICE_ID="${IDEVICE_ID:-$PREFIX/bin/idevice_id}"

# QEMU data dir (keymaps for -display vnc, firmware ROMs). A build-tree
# qemu-system-aarch64 that was never "make install"ed can't find
# keymaps/en-us ("could not read keymap file: 'en-us'"), so locate one at
# runtime and pass it with -L. Falls back to copying the keymaps that ship in
# the Inferno source tree (pc-bios/keymaps) next to the build.
qemu_datadir() {
  local qd src d
  qd=$(cd "$(dirname "$QEMU")" 2>/dev/null && pwd) || qd=""
  src="${INFERNO_SRC:-$(dirname "$qd")}"
  for d in "${QEMU_DATADIR:-}" "$qd/qemu-bundle/usr/local/share/qemu" "$qd/pc-bios" \
           "$qd/ios-tools-qemu-data" /usr/local/share/qemu /usr/share/qemu "$src/pc-bios"; do
    [ -n "$d" ] && [ -f "$d/keymaps/en-us" ] && { echo "$d"; return 0; }
  done
  if [ -f "$src/pc-bios/keymaps/en-us" ] && [ -n "$qd" ]; then
    mkdir -p "$qd/ios-tools-qemu-data" && cp -r "$src/pc-bios/keymaps" "$qd/ios-tools-qemu-data/" \
      && [ -f "$qd/ios-tools-qemu-data/keymaps/en-us" ] && { echo "$qd/ios-tools-qemu-data"; return 0; }
  fi
  return 1
}

log()  { printf '[usbhost] %s\n' "$*"; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

preflight() {
  [ -x "$QEMU" ] || die "qemu-system-aarch64 not found at $QEMU (run the Inferno build step first)"
  [ -s "$CVM/vmlinuz" ] && [ -s "$CVM/initrd.img" ] || die "USB-host VM not built - run build-restore-tools.sh"
  "$QEMU" -M help 2>/dev/null | grep -q '^virt ' || die "this QEMU build has no 'virt' machine"
  "$QEMU" -device help 2>/dev/null | grep -q '"usb-tcp-remote"' || die "this QEMU build has no usb-tcp-remote device"
  "$QEMU" -device help 2>/dev/null | grep -q '"virtio-9p-pci"' || die "this QEMU build has no virtio-9p (virtfs)"
  mkdir -p "$J" "$(dirname "$USB_SOCK")"
}

qemu_pid() { local p; p=$(cat "$J/qemu.pid" 2>/dev/null || true); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "$p"; }

# base_cmd MODE -> fills the CMD array
base_cmd() {
  local qdata; qdata=$(qemu_datadir) || die "no QEMU data dir (keymaps) found for $QEMU - re-run step 3"
  # tb-size: QEMU's default 1 GiB TCG code buffer is far more than this small
  # guest needs; keep the VM's footprint on the phone small.
  CMD=("$QEMU" -L "$qdata" -M virt -cpu cortex-a72 -accel "tcg,tb-size=${COMPANION_TB_MB:-128}" -smp "$CSMP" -m "$CMEM"
    -display none -monitor none -serial "file:$J/console.log" -no-reboot
    -kernel "$CVM/vmlinuz" -initrd "$CVM/initrd.img"
    -append "console=ttyAMA0 panic=-1 loglevel=5 inferno.data=$DATA"
    -fsdev "local,id=fsroot,path=$GUEST_ROOT,security_model=passthrough,readonly=on,multidevs=remap"
    -device "virtio-9p-pci,fsdev=fsroot,mount_tag=hostroot"
    -fsdev "local,id=fsdata,path=$DATA,security_model=passthrough,multidevs=remap"
    -device "virtio-9p-pci,fsdev=fsdata,mount_tag=data")
}

start_usbmux() {
  preflight
  if qemu_pid >/dev/null; then log "already running (pid $(qemu_pid))"; return 0; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$MUX_PORT") 2>/dev/null; then
    die "127.0.0.1:$MUX_PORT is already in use (another usbmuxd/VM?). Set MUX_PORT=..."
  fi
  rm -f "$J/net.status"
  rm -f "$USB_SOCK" "$J/job.rc" "$J/job.log" "$J/console.log" "$J/qemu.exit" "$J/qemu.pid" "$J/stopped-by-script"
  if [ "${NET:-0}" = 1 ]; then
    printf 'NET_MODE=%s\n' "${NET_MODE:-routed}" > "$J/job.sh"
    cat >> "$J/job.sh" <<'NETJOB'
# generated by companion-vm.sh (net mode: reverse tethering, ChefKiss style)
# usbmuxd switches the iPhone to USB mode 3 (usbmux + CDC-NCM ethernet); iOS is
# the DHCP client on that link. Its traffic leaves through the phone's own
# connection via this VM's slirp NIC (eth0).
# routed (default, the ChefKiss wiki's method): the NCM interface gets
#   10.11.12.1/24, dnsmasq hands iOS 10.11.12.20+ (router and DNS 10.11.12.1,
#   DNS forwarded to slirp's 10.0.2.3) and nftables masquerades it out of eth0.
#   dnsmasq logs every DHCP request it sees ([net] dnsmasq-dhcp...).
# bridge (NET_MODE=bridge): the NCM interface is bridged onto eth0 and slirp's
#   own DHCP answers (10.0.2.20+, gateway 10.0.2.2, DNS 10.0.2.3).
export USBMUXD_DEFAULT_DEVICE_MODE=3
LOCKDIR="$DATA/companion/lockdown"; mkdir -p "$LOCKDIR"
net() { echo "[net] $*"; echo "$*" > "$DATA/companion/net.status"; }
IP() { if command -v ip >/dev/null 2>&1; then ip "$@"; else busybox ip "$@"; fi; }
RNET=10.11.12
if [ "$NET_MODE" = bridge ]; then
  mac=$(cat /sys/class/net/eth0/address)
  if IP link add br0 type bridge 2>/dev/null || busybox brctl addbr br0; then
    echo 0 > /sys/class/net/br0/bridge/forward_delay 2>/dev/null
    echo 0 > /sys/class/net/br0/bridge/stp_state 2>/dev/null
    IP link set br0 address "$mac"
    IP addr flush dev eth0
    IP link set eth0 master br0 2>/dev/null || busybox brctl addif br0 eth0
    IP link set br0 up
    IP addr add 10.0.2.15/24 dev br0
    IP route add default via 10.0.2.2 2>/dev/null
    net "bridge br0 ready (slirp 10.0.2.0/24); waiting for the iPhone's USB ethernet"
  else
    net "ERROR: cannot create a network bridge in the USB-host VM (bridge module missing? rebuild with step 5's tools: build-restore-tools.sh)"
  fi
else
  echo 1 > /proc/sys/net/ipv4/ip_forward
  if command -v nft >/dev/null 2>&1 && nft -f - <<'NFT'
table ip iosnat {
  chain post {
    type nat hook postrouting priority 100;
    oifname "eth0" masquerade
  }
}
NFT
  then
    net "routed mode: NAT out via eth0 ready; waiting for the iPhone's USB ethernet"
  else
    net "ERROR: NAT setup failed (nft missing, or no nf_tables modules in the USB-host VM) - rerun build-restore-tools.sh"
  fi
  command -v dnsmasq >/dev/null 2>&1 \
    || net "ERROR: dnsmasq missing in the Debian chroot (apt-get install dnsmasq-base, or rerun build-restore-tools.sh)"
fi
( done_if=""; routed_if=""; paired=""; t0=$(date +%s); warned=""; linkst=""; pairerr=""
  while :; do
    # iOS re-enumerating its USB drops the interface: forget it (and its
    # dnsmasq) so the one that comes back is set up again.
    for i in $done_if; do
      [ -e "/sys/class/net/$i" ] && continue
      net "iPhone USB ethernet $i is gone (USB reconnect?) - waiting for it to come back"
      done_if=$(echo " $done_if " | sed "s/ $i / /g")
      if [ "$i" = "$routed_if" ]; then
        kill "$(cat /tmp/dnsmasq.pid 2>/dev/null)" 2>/dev/null
        routed_if=""
      fi
    done
    for n in /sys/class/net/*; do
      i=${n##*/}
      case "$(readlink "$n/device/driver" 2>/dev/null)" in *cdc_ncm*|*cdc_ether*) ;; *) continue ;; esac
      case " $done_if " in *" $i "*) continue ;; esac
      IP link set "$i" up
      if [ "$NET_MODE" = bridge ]; then
        if IP link set "$i" master br0 2>/dev/null || busybox brctl addif br0 "$i"; then
          done_if="$done_if $i"
          net "iPhone USB ethernet $i bridged - iOS should get 10.0.2.20 by DHCP (gateway 10.0.2.2, DNS 10.0.2.3)"
          # Show whether iOS's DHCP requests reach this side at all.
          command -v tcpdump >/dev/null 2>&1 && \
            timeout 1800 tcpdump -lni "$i" -c 40 'udp port 67 or udp port 68' 2>/dev/null \
              | sed -u 's/^/[net] dhcp seen: /' &
        else
          net "ERROR: could not add $i to the bridge"
        fi
      elif [ -z "$routed_if" ]; then
        IP addr add "$RNET.1/24" dev "$i"
        dnsmasq --keep-in-foreground --interface="$i" --bind-interfaces --except-interface=lo \
          --dhcp-range="$RNET.20,$RNET.200,12h" --dhcp-option=3,"$RNET.1" --dhcp-option=6,"$RNET.1" \
          --no-resolv --server=10.0.2.3 --dhcp-leasefile=/tmp/dnsmasq.leases --pid-file=/tmp/dnsmasq.pid \
          --log-facility=- --user=root --group=root --conf-file=/dev/null 2>&1 | sed -u 's/^/[net] /' &
        routed_if=$i; done_if="$done_if $i"
        net "iPhone USB ethernet $i routed: $RNET.1/24, dnsmasq DHCP $RNET.20+ (router and DNS $RNET.1), NAT out via eth0"
      else
        done_if="$done_if $i"
        net "another iPhone USB ethernet ($i) left unconfigured; $routed_if is the routed one"
      fi
    done
    # Link state and traffic of the iPhone's USB ethernet, logged on change.
    # The stock cdc_ncm keeps carrier off until iOS reports the link connected
    # (build-restore-tools.sh builds one that starts with the link up); rx
    # counting up means frames from iOS arrive.
    st=""
    for i in $done_if; do
      st="$st $i carrier=$(cat /sys/class/net/$i/carrier 2>/dev/null || echo ?) state=$(cat /sys/class/net/$i/operstate 2>/dev/null) rx=$(cat /sys/class/net/$i/statistics/rx_packets 2>/dev/null) tx=$(cat /sys/class/net/$i/statistics/tx_packets 2>/dev/null)"
    done
    if [ -n "$st" ] && [ "$st" != "$linkst" ]; then linkst=$st; net "link:$st"; fi
    # iOS may only bring its USB ethernet up once paired with this host.
    if [ -z "$paired" ] && [ -n "$(USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 idevice_id -l 2>/dev/null)" ]; then
      if out=$(USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 idevicepair pair 2>&1); then paired=1; net "paired with iOS ($out)"
      else
        case "$out" in *"Please accept"*|*"trust"*|*"passcode"*) out="tap 'Trust' on the iOS screen if asked ($out)";; esac
        [ "$out" != "$pairerr" ] && { pairerr=$out; net "pairing not done yet: $out"; }
      fi
    fi
    if [ -z "$done_if" ] && [ -z "$warned" ] && [ $(( $(date +%s) - t0 )) -gt 900 ]; then
      warned=1
      if grep -q cdc_ncm /proc/modules; then net "no iPhone USB ethernet yet after 15 min (iOS still booting, or it did not switch to USB mode 3)"
      else net "ERROR: cdc_ncm driver not loaded in the USB-host VM - rebuild it (build-restore-tools.sh)"; fi
    fi
    sleep 5
  done ) &
NETJOB
  else
    : > "$J/job.sh"
  fi
  cat >> "$J/job.sh" <<JOB
# generated by companion-vm.sh (usbmux mode)
mkdir -p /run/lockdown
echo "[usbhost] guest kernel \$(uname -r)"
if ls -d /sys/bus/usb/devices/usb[0-9]* >/dev/null 2>&1; then
  echo "[usbhost] USB buses: \$(cd /sys/bus/usb/devices && ls -d usb[0-9]* | tr '\\n' ' ')(EHCI driver: \$(ls /sys/bus/pci/drivers 2>/dev/null | grep -i hci | tr '\\n' ' '))"
else
  echo "[usbhost] ERROR: no USB bus in the VM - the EHCI driver (ehci_pci) did not load; usbmuxd cannot see the iPhone"
fi
# Watch the USB bus through sysfs only: lsusb opens the device and sends it
# control requests, which competes with usbmuxd on the slow emulated link.
( last=""; while :; do
    now=\$(for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do [ -f "\$d/idVendor" ] && echo "\$(cat "\$d/idVendor"):\$(cat "\$d/idProduct") \$(cat "\$d/product" 2>/dev/null) [\${d##*/}]"; done 2>/dev/null)
    if [ "\$now" != "\$last" ]; then echo "[usbhost] usb devices: \${now:-none}"; last="\$now"; seen=\$(date +%s); fi
    # usbmuxd only handles Apple PIDs 0x1290-0x12af (normal/restore mode;
    # 0x1227 DFU / 0x1281 recovery belong to idevicerestore via libirecovery).
    # libusb here has no udev: if a hotplug event was missed, the iPhone is on
    # the bus but usbmuxd does not list it. Restart usbmuxd then (it rescans).
    if echo "\$now" | grep -qE '^05ac:12[9a][0-9a-f] '; then
      if [ \$(( \$(date +%s) - \${seen:-0} )) -ge 60 ] && [ -z "\$(USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 idevice_id -l 2>/dev/null)" ]; then
        echo "[usbhost] the iPhone is on the USB bus for 60 s but usbmuxd does not list it - restarting usbmuxd to rescan"
        kill \$(pidof usbmuxd) 2>/dev/null; seen=\$(date +%s)
      fi
    fi
    sleep 5
  done ) &
# Do not exec usbmuxd: if it exits, this job (and with it the VM) would end.
# Restart it (forever) and log why it stopped.
n=0
while :; do
  usbmuxd -f -v -S 0.0.0.0:27015 -C \${LOCKDIR:-/run/lockdown} -P NONE
  rc=\$?; n=\$((n + 1))
  echo "[usbhost] usbmuxd exited with status \$rc (restart \$n); guest MemAvailable: \$(awk '/MemAvailable/ {print \$2 " kB"}' /proc/meminfo)"
  dmesg 2>/dev/null | tail -n 15 | sed 's/^/[usbhost] dmesg: /'
  sleep 1
done
JOB
  base_cmd
  # dhcpstart: keep 10.0.2.15 for this VM; iOS (net mode) gets .20 from slirp.
  CMD+=(-netdev "user,id=n0,dhcpstart=10.0.2.20,hostfwd=tcp:127.0.0.1:$MUX_PORT-10.0.2.15:27015"
        -device "virtio-net-pci,netdev=n0,romfile="
        -device "usb-ehci,id=ehci"
        -device "usb-tcp-remote,conn-type=unix,conn-addr=$USB_SOCK,bus=ehci.0")
  log "starting USB-host VM (usbmuxd -> 127.0.0.1:$MUX_PORT, iPhone USB socket $USB_SOCK)"
  # A small wrapper waits for QEMU and records how it ended in qemu.exit
  # (128+N = killed by signal N; 137 = SIGKILL, e.g. the low-memory killer).
  # The VM gets a lower OOM score so Android's/Linux's low-memory killer picks
  # something else first: it is small, but losing it kills the restore.
  J="$J" OOMADJ="${COMPANION_OOM_ADJ:--800}" setsid bash -c '
    "$@" & p=$!
    echo "$p" > "$J/qemu.pid"
    echo "$OOMADJ" > "/proc/$p/oom_score_adj" 2>/dev/null || true
    renice -n "${COMPANION_NICE:--10}" -p "$p" >/dev/null 2>&1 || true
    for c in /sys/fs/cgroup /acct; do [ -w "$c/cgroup.procs" ] && echo "$p" > "$c/cgroup.procs"; done 2>/dev/null || true
    { echo "oom_score_adj=$(cat /proc/$p/oom_score_adj 2>/dev/null)"; tr "\n" " " < /proc/$p/cgroup 2>/dev/null; echo; } > "$J/placement.txt"
    wait "$p"; echo "$? $(date +%s)" > "$J/qemu.exit"' companion-wrap "${CMD[@]}" > "$J/qemu.log" 2>&1 < /dev/null &
  local i
  for i in $(seq 1 50); do [ -s "$J/qemu.pid" ] && break; sleep 0.1; done
  for i in $(seq 1 30); do
    [ -S "$USB_SOCK" ] && break
    qemu_pid >/dev/null || { report >&2; die "USB-host VM exited right away (log above)"; }
    sleep 1
  done
  [ -S "$USB_SOCK" ] || die "usb-tcp-remote did not create $USB_SOCK"
  log "waiting for usbmuxd in the VM (TCG boot, usually 1-3 min)"
  local t0; t0=$(date +%s)
  while :; do
    if USBMUXD_SOCKET_ADDRESS="127.0.0.1:$MUX_PORT" $IDEVICE_ID -l >/dev/null 2>&1; then
      log "usbmuxd is up after $(( $(date +%s) - t0 )) s"; return 0
    fi
    qemu_pid >/dev/null || { report >&2; die "USB-host VM stopped before usbmuxd came up (logs above)"; }
    [ $(( $(date +%s) - t0 )) -lt "${COMPANION_TIMEOUT:-600}" ] || { report >&2; stop_vm; die "usbmuxd did not come up within ${COMPANION_TIMEOUT:-600} s"; }
    sleep 5
  done
}

stop_vm() {
  local p; p=$(qemu_pid || true)
  [ -n "$p" ] || { rm -f "$J/qemu.pid"; return 0; }
  log "stopping USB-host VM (pid $p)"
  date +%s > "$J/stopped-by-script"
  kill "$p" 2>/dev/null || true
  local i; for i in $(seq 1 20); do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  kill -9 "$p" 2>/dev/null || true
  rm -f "$J/qemu.pid" "$USB_SOCK"
}

apfs_run() {
  [ $# -ge 1 ] || die "usage: $0 apfs-run COMMAND..."
  preflight
  [ -f "$DATA/root" ] || die "no $DATA/root disk"
  qemu_pid >/dev/null && die "the USB-host VM is already running - stop it first"
  if pgrep -f 'qemu-system-aarch64.*-M t8030' >/dev/null 2>&1; then
    die "the iOS VM is running - power it off before touching its disk"
  fi
  rm -f "$J/job.rc" "$J/job.log" "$J/console.log"
  {
    echo '# generated by companion-vm.sh (apfs-run mode)'
    echo 'set -u'
    echo 'if ! grep -qw apfs /proc/filesystems; then'
    echo '  echo "[ERROR] apfs module not loaded in the USB-host VM. Cause:"'
    echo '  [ -s "$DATA/companion/initrd-modules.log" ] && sed "s/^/[ERROR]   /" "$DATA/companion/initrd-modules.log"'
    echo '  grep -q crc32c_generic "$DATA/companion/initrd-modules.log" 2>/dev/null || echo "[ERROR]   crc32c_generic is missing from the USB-host VM initramfs (libcrc32c needs it) - rerun step 5 so build-restore-tools.sh rebuilds the VM"'
    echo '  exit 90'
    echo 'fi'
    echo 'MNT=/run/sysvol; mkdir -p "$MNT"; FOUND=""'
    echo 'for dev in /dev/vda[0-9]* /dev/vda; do'
    echo '  [ -b "$dev" ] || continue'
    echo '  [ "$(dd if="$dev" bs=4096 count=1 2>/dev/null | dd bs=1 skip=32 count=4 2>/dev/null)" = NXSB ] || continue'
    echo '  for v in 0 1 2 3 4 5 6 7; do'
    echo '    if mount -t apfs -o ro,vol=$v "$dev" "$MNT" 2>/dev/null; then'
    echo '      if [ -f "$MNT/System/Library/xpc/launchd.plist" ]; then FOUND="$dev vol=$v"; fi'
    echo '      umount "$MNT"'
    echo '      [ -n "$FOUND" ] && break 2'
    echo '    fi'
    echo '  done'
    echo 'done'
    echo '[ -n "$FOUND" ] || { echo "[ERROR] no APFS System volume (System/Library/xpc/launchd.plist) on the root disk - is it restored?"; dmesg | grep -i apfs | tail -n 20; exit 91; }'
    echo 'set -- $FOUND'
    echo 'echo "[usbhost] System volume: $1 $2"'
    echo 'mount -t apfs -o readwrite,$2 "$1" "$MNT" || { echo "[ERROR] read-write APFS mount failed"; dmesg | grep -i apfs | tail -n 20; exit 92; }'
    # linux-apfs-rw silently falls back to read-only for some volumes
    echo 'if ! awk -v m="$MNT" '"'"'$2 == m && $4 ~ /(^|,)rw(,|$)/'"'"' /proc/mounts | grep -q . || ! touch "$MNT/.ios-tools-rwtest"; then echo "[ERROR] the System volume mounted read-only (linux-apfs-rw refused writes):"; dmesg | grep -i apfs | tail -n 20; umount "$MNT"; exit 94; fi'
    echo 'rm -f "$MNT/.ios-tools-rwtest"'
    echo 'export SYSVOL="$MNT"'
    printf '%s\n' "( $* )"
    echo 'rc=$?'
    echo 'sync'
    echo 'umount "$MNT" || { echo "[ERROR] unmount failed"; rc=93; }'
    echo 'dmesg | grep -i apfs | tail -n 5'
    echo 'exit $rc'
  } > "$J/job.sh"
  CMEM="${COMPANION_MEM:-1G}"
  CSMP="${COMPANION_SMP:-4}"
  base_cmd
  CMD+=(-drive "file=$DATA/root,format=raw,if=none,id=iosroot,cache=writeback"
        -device "virtio-blk-pci,drive=iosroot,logical_block_size=4096,physical_block_size=4096")
  log "booting USB-host VM with the iOS root disk attached"
  local rc=0
  "${CMD[@]}" > "$J/qemu.log" 2>&1 < /dev/null &
  local p=$!; echo "$p" > "$J/qemu.pid"
  # stream the job log while it runs
  local shown=0 t0; t0=$(date +%s)
  while kill -0 "$p" 2>/dev/null; do
    if [ -f "$J/job.log" ]; then
      local n; n=$(wc -l < "$J/job.log")
      [ "$n" -gt "$shown" ] && { sed -n "$((shown + 1)),${n}p" "$J/job.log"; shown=$n; }
    fi
    if [ $(( $(date +%s) - t0 )) -gt "${APFS_TIMEOUT:-5400}" ]; then
      kill "$p" 2>/dev/null || true; sleep 5; kill -9 "$p" 2>/dev/null || true
      die "USB-host VM job timed out after ${APFS_TIMEOUT:-5400} s"
    fi
    sleep 3
  done
  wait "$p" 2>/dev/null || true
  rm -f "$J/qemu.pid"
  [ -f "$J/job.log" ] && sed -n "$((shown + 1)),\$p" "$J/job.log"
  if [ ! -f "$J/job.rc" ]; then
    tail -n 40 "$J/console.log" "$J/qemu.log" >&2 2>/dev/null || true
    die "USB-host VM stopped without finishing the job (console log above)"
  fi
  rc=$(cat "$J/job.rc")
  return "$rc"
}

# report: why the USB-host VM ended + the useful part of its logs
# brief: what step 5 prints right above its final [ERROR] (fits one screen)
brief() {
  echo "----- USB-host VM: why it stopped -----"
  reason
  if [ -s "$J/placement.txt" ]; then
    echo "placement: $(head -c 300 "$J/placement.txt")"
    if grep -q uid_ "$J/placement.txt"; then echo "WARNING: QEMU stayed in an Android app cgroup - the phantom-process killer can SIGKILL it"; fi
  fi
  echo "--- QEMU stderr (last 15) ---"
  grep -vE 'TCP_USB_RESPONSE.*Invalid packet|dropping a response' "$J/qemu.log" 2>/dev/null | tail -n 15 | cut -c1-200
  echo "--- guest console (last 8) ---"
  tail -n 8 "$J/console.log" 2>/dev/null | tr -d '\r' | cut -c1-200
  return 0
}
reason() {
  local code ts sig
  if p=$(qemu_pid); then
    echo "still running (pid $p)"
  elif [ -s "$J/qemu.exit" ]; then
    read -r code ts < "$J/qemu.exit"
    if [ -f "$J/stopped-by-script" ]; then
      echo "stopped by the restore script (QEMU exit status $code)"
    elif [ "$code" -gt 128 ] 2>/dev/null; then
      sig=$(kill -l $(( code - 128 )) 2>/dev/null || echo "?")
      echo "QEMU was killed by signal $(( code - 128 )) (SIG$sig)"
      [ "$code" = 134 ] && echo "SIGABRT: QEMU hit an internal assertion (usb-tcp-remote / EHCI); see the QEMU log below"
      [ "$code" = 139 ] && echo "SIGSEGV: QEMU crashed; see the QEMU log below"
      [ "$code" = 137 ] && echo "SIGKILL from outside: Android's phantom-process killer (app in the background) or the low-memory killer (iOS VM ${MEM:-4G} + this VM ${CMEM})"
    elif [ "$code" = 0 ]; then
      echo "QEMU exited normally (status 0): the guest powered off or its kernel panicked (panic=-1 + -no-reboot)"
    else
      echo "QEMU exited with status $code (error, see qemu.log below)"
    fi
  else
    echo "QEMU is gone and left no exit status (killed together with its wrapper?)"
  fi
  if command -v dmesg >/dev/null 2>&1; then
    local oom; oom=$(dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|lowmemorykiller|lmkd' | grep -i qemu | tail -n 3)
    [ -n "$oom" ] && { echo "host kernel log mentions an OOM kill of QEMU:"; echo "$oom"; }
  fi
  return 0
}
report() {
  echo "----- USB-host VM: why it stopped -----"
  reason
  [ -f "$J/job.rc" ] && echo "guest job (usbmuxd) exit status: $(cat "$J/job.rc")"
  [ -s "$J/placement.txt" ] && echo "placement: $(cat "$J/placement.txt")"
  echo "----- USB-host VM console (last 40 lines) -----"
  tail -n 40 "$J/console.log" 2>/dev/null | tr -d '\r'
  echo "----- USB-host VM QEMU log (last 20 lines) -----"
  tail -n 20 "$J/qemu.log" 2>/dev/null
  echo "----- usbmuxd / job log (last 20 lines, client connect lines dropped) -----"
  grep -vE '\] Client [0-9]+ (accepted|connection closed|is going to be disconnected)' "$J/job.log" 2>/dev/null | tail -n 20
  echo "----- end -----"
}

case "${1:-}" in
  usbmux) start_usbmux ;;
  net) NET=1 start_usbmux ;;
  stop) stop_vm ;;
  apfs-run) shift; apfs_run "$@" ;;
  status) if p=$(qemu_pid); then echo "running (pid $p)"; else echo "stopped"; fi ;;
  report) report ;;
  brief) brief ;;
  *) die "usage: $0 usbmux | net | stop | apfs-run COMMAND... | status | report | brief" ;;
esac
