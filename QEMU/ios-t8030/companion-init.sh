#!/bin/busybox sh
# /init of the USB-host ("companion") VM initramfs (built by
# build-restore-tools.sh). Loads the virtio/9p/EHCI/apfs modules, mounts the
# Debian chroot read-only (9p tag "hostroot") and the Inferno data folder
# read-write (9p tag "data"), brings up slirp networking, then runs
# $DATA/companion/job.sh inside the chroot view and powers off.
/bin/busybox mkdir -p /proc /sys /dev /host /sbin /usr/bin /usr/sbin
/bin/busybox --install -s
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
say() { echo "[companion] $*"; }
fail() { say "FATAL: $*"; sync; poweroff -f; }

DATA=/root/InfernoData
for a in $(cat /proc/cmdline); do
  case "$a" in inferno.data=*) DATA="${a#inferno.data=}" ;; esac
done

for m in $(cat /modules/order); do
  if ! err=$(insmod "/modules/$m.ko" 2>&1) && ! grep -q "^$m " /proc/modules; then
    say "insmod $m failed: $err"
    echo "insmod $m failed: $err" >> /modfail.log
  fi
done

O9="trans=virtio,version=9p2000.L,msize=262144"
mount -t 9p -o "$O9,ro,cache=loose" hostroot /host || fail "cannot mount the chroot (9p hostroot)"
mount -t 9p -o "$O9,cache=none" data "/host$DATA" || fail "cannot mount $DATA (9p data)"
mount -t proc proc /host/proc
mount -t sysfs sysfs /host/sys
mount -t devtmpfs devtmpfs /host/dev
mkdir -p /host/dev/pts /host/dev/shm
mount -t devpts devpts /host/dev/pts
mount -t tmpfs tmpfs /host/run
mount -t tmpfs tmpfs /host/tmp
mount -t tmpfs tmpfs /host/dev/shm

ip link set lo up
ip link set eth0 up && ip addr add 10.0.2.15/24 dev eth0 && ip route add default via 10.0.2.2 \
  || say "network setup failed (usbmuxd will not be reachable)"

J="$DATA/companion"
{ echo "order: $(tr '\n' ' ' < /modules/order)"; cat /modfail.log 2>/dev/null
  dmesg | grep -iE 'apfs|crc32c|unknown symbol' | tail -n 10 | sed 's/^/dmesg: /'; } > "/host$J/initrd-modules.log" 2>/dev/null
if [ -f "/host$J/job.sh" ]; then
  say "running $J/job.sh"
  chroot /host /usr/bin/env -i HOME=/root LANG=C.UTF-8 DATA="$DATA" \
    PATH=/opt/inferno-restore/bin:/opt/inferno-restore/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash "$J/job.sh" > "/host$J/job.log" 2>&1
  rc=$?
  echo "$rc" > "/host$J/job.rc"
  say "job exit $rc"
else
  say "no $J/job.sh"
  echo 99 > "/host$J/job.rc"
fi
sync
umount "/host$DATA" 2>/dev/null
poweroff -f
