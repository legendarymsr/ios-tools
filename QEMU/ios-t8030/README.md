# ios-t8030 — emulated iPhone 11 (iOS) on Android via Inferno

Boot an emulated **iPhone 11 (t8030, Apple A13)** running **iOS 14.x** under
**Inferno** (ChefKiss; formerly *QEMUAppleSilicon*, originally the
*qemu-t8030* fork by TrungNguyen1909). Packaged as a KernelSU/Magisk module that
installs the **iOS Emu (t8030)** launcher app.

- Module zip: **`qemu-t8030-launcher-v1.6.0.zip`**
- App package: `com.qemut8030.launcher` (label "iOS Emu (t8030)")
- App source: [`launcher-app/`](launcher-app/)
- Upstream: https://github.com/ChefKissInc/Inferno · guide: https://chefkiss.dev/applehax/inferno/

## Built-in VNC viewer (v1.1.4)

The launcher app has its own VNC viewer, so no separate VNC app is needed.

- **Open VNC viewer (127.0.0.1:5900)** button at the top of the step list. It
  stays enabled while a step is running, so you can open it while the VM is up.
- The **Boot** step opens the viewer automatically as soon as
  `127.0.0.1:5900` accepts connections (it watches for about 60 s).
- The viewer retries the connection for about 60 s while QEMU is still starting,
  and shows **Disconnected — tap to reconnect** if the VM stops.
- Screen is drawn **fit-to-screen**; **pinch** to zoom (up to 8×), **two-finger
  drag** to pan, **Fit** resets.
- **Tap** = left click, **one-finger drag** = move with the left button held,
  **long press** = right click. A hardware mouse (hover + wheel) also works.
- **Keyboard** toolbar button shows/hides the soft keyboard; typed text is sent
  as key events. Extra toolbar keys: **Esc** and **Ctrl+C**. Hardware keyboards
  work too (arrows, Home/End, PgUp/PgDn, modifiers).
- **Back** closes the viewer only; the VM keeps running.
- Protocol: RFB 3.8 (3.3/3.7 accepted), security type *None* (QEMU's default
  `-display vnc=127.0.0.1:0` has no password), Raw + CopyRect encodings,
  DesktopSize so guest resolution changes are followed. Written in plain Java,
  no extra libraries.

## Automatic restore (v1.2.0, step 5)

A blank Inferno disk has to be restored with `idevicerestore` before iOS
boots. ChefKiss does that from a separate **companion VM**: the emulated
iPhone's USB port is a socket that only another QEMU's `usb-tcp-remote`
device can plug into ([Companion VM Setup](https://chefkiss.dev/guides/inferno/companion-setup/)),
and that VM runs `usbmuxd` + `idevicerestore`. Then the restored System volume
gets the [Filesystem Patches](https://chefkiss.dev/guides/inferno/fs-patches/),
which the guide does on macOS. Step 5 **Restore iOS (automatic)** does all of
it on the phone:

1. **Tools (first run only, ~10-30 min).** `build-restore-tools.sh` builds
   into `/opt/inferno-restore` at pinned commits: libplist,
   libimobiledevice-glue, libusbmuxd, libtatsu, libimobiledevice, libirecovery,
   usbmuxd, and idevicerestore with ChefKiss's
   [`idevicerestore.patch`](https://chefkiss.dev/Extras/Inferno/idevicerestore.patch)
   (`idevicerestore-inferno.patch`). It also builds libusb 1.0.29 without udev,
   InfernoFSPatcher, and the USB-host VM: Debian's own `linux-image-arm64`
   kernel (via apt), [linux-apfs-rw](https://github.com/linux-apfs/linux-apfs-rw)
   built against the matching `linux-headers`, and a busybox initramfs
   (`companion-init.sh`). Inferno itself is **not** rebuilt; the build from step
   3 already has the `virt` machine, `usb-ehci`, `usb-tcp-remote`, 9p and slirp.
2. **USB-host VM** (`companion-vm.sh usbmux`). It's a small aarch64 `virt` VM
   (TCG, 512 MB) running the same Inferno `qemu-system-aarch64`, with
   `-device usb-ehci -device usb-tcp-remote,conn-type=unix,conn-addr=InfernoData/restore/usb.sock`.
   Its userland is this Debian chroot, shared read-only over 9p, so nothing
   else is downloaded. It only runs `usbmuxd -S 0.0.0.0:27015`, forwarded to
   `127.0.0.1:27015` in the chroot.
3. **Restore ramdisk.** It boots `run-t8030.sh` with `RESTORE_MODE=1` and
   `usb-conn-type=unix,usb-conn-addr=…` (the same flags as ChefKiss's
   `-M t8030,…,usb-conn-*`). The VNC screen shows the restore, so you can
   watch with **Open VNC viewer**.
4. **idevicerestore** runs natively in the chroot. It talks to the VM's
   usbmuxd via `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015`:
   `idevicerestore --erase --restore-mode --no-input -i 0x1122334455667788 -T root_ticket.der <ipsw>`
   (the guide's command plus `--no-input`). The OS image is streamed straight
   from the downloaded `.ipsw`; it's stored uncompressed in that zip, so
   nothing is extracted. Progress is logged every 5 %. The guest closes itself
   when restore stage 1 is done.
5. **Filesystem patches** (`companion-vm.sh apfs-run`). The USB-host VM boots
   again with `root` attached and mounts the System volume read-write with
   linux-apfs-rw. It runs InfernoFSPatcher on `dyld_shared_cache_arm64e`, then
   `patch-launchd.py --no-bash` sets `Disabled` on vmd, CommCenter*, and
   locationd. The original `launchd.plist` is saved to `InfernoData/restore/`.
6. Writes `InfernoData/RESTORED`. **Boot iOS** now boots normally. The first
   boot runs data migration (restore stage 2) and can take a long time under
   TCG before the setup screen. Don't set a passcode, don't enable location
   services, and never use "Erase All Content and Settings" (ChefKiss).

Resuming and retrying:
- The work runs detached inside the chroot (`setsid`). Closing the app doesn't
  stop it, and tapping step 5 again re-attaches to `InfernoData/restore/restore.log`.
- On the first run, all nine Inferno disks are backed up (sparse) to
  `InfernoData/restore/blank/`. If stage 1 fails or gets interrupted, the next
  tap resets the disks from that backup and restores again. A failed FS-patch
  stage is retried on its own. `FORCE_RESTORE=1` wipes a restored guest back to
  blank and restores again.
- Errors print one `[ERROR] …` line plus the tail of the relevant log
  (`restore/inferno.log`, `restore/ios-serial.log`, `restore/idevicerestore.log.raw`,
  `companion/console.log`, `companion/job.log`).
- Inside the chroot: `bash /root/restore-ios.sh status | stop`.

Limits:
- Under TCG on a phone, the restore ramdisk can take 10-40+ min to come up and
  the restore itself can take hours. The step waits up to 3 h for the device
  (`DEVICE_TIMEOUT`, default 6 h).
- linux-apfs-rw write support is marked experimental upstream. If the FS-patch
  stage fails, the restore itself is still on disk. Do the patches on a Mac
  (fs-patches guide), then re-run step 5 with `SKIP_FS_PATCHES=1`.
- Not tested end to end here: the build host has no phone and no 5.5 GB IPSW
  restore. See "Verified vs not".

## Reality check (important)

- The guest CPU is an **Apple A13**, so there is **no KVM** — it's pure **TCG
  emulation**: very slow (multi-minute boots), **no GPU** acceleration, software
  rendering only. This is bring-up/research quality, not a daily driver.
  Inferno `@ cc4302a` hardcodes `TYPE_APPLE_A13` and `minimum_page_bits=14`
  (16 KiB pages); `-accel kvm` / `-cpu host` are not usable for this machine.
  `run-t8030.sh` probes `/dev/kvm` for logging but always launches with
  `-accel tcg`.
- **v1.3.2 step 3 upgrade fix:** a source tree patched by any earlier version (or partly patched / edited) no longer stops step 3 with "does not apply": the patched files are reset to pristine cc4302a and the current patches applied fresh, no CLEAN_SRC needed.
- **v1.3.1 USB link fixes:** the USB-host side only cancels packets the iOS side really has (no more "TCP_USB_CANCEL ... not found"), and drops stale answers for cancelled packets until the iOS side acknowledges the cancel. The iOS side answers a cancel or a request for a vanished endpoint without closing the link, and no longer reads a packet after it was freed (that corrupted the stream and made the USB-host VM drop the iPhone). The USB-host VM's USB messages and warnings are shown on screen; the status lines show usbmuxd's device count and idevicerestore's last line; while restored waits for the host, step 5 polls every second. Re-run step 3 (recompiles two files), then step 5.
- **v1.3.0 restore audit (everything after the USB link connects):**
  - **idevicerestore crash:** when libusb cannot start in the chroot (no usbfs, or the uevent netlink socket is denied on Android), libirecovery's event thread used a NULL libusb context and idevicerestore died with SIGSEGV before it even asked usbmuxd. Fixed by `libirecovery-no-usb.patch`; restore-mode devices go through usbmuxd anyway.
  - **TCG timeouts (`idevicerestore-tcg-timeouts.patch`):**
    - ASR receive: 10 min instead of libusbmuxd's 5 s default (`ASR_TIMEOUT_MS`).
    - Connect attempts: ASR 300 s, FDR/baseband/bootability 60 attempts.
    - Reconnect window: 180 s.
    - Initial device discovery: 60 s.
  - **Filesystem patches:**
    - **launchd.plist:** linux-apfs-rw refuses to write APFS-compressed files, and iOS's launchd.plist usually is one. It is now written as a new file and renamed over the old one, keeping owner and mode.
    - **dyld cache:** a compressed dyld cache is first rewritten as a plain copy.
    - **Read-only fallback:** a silent read-only mount is detected (`/proc/mounts` plus a write test) instead of failing later.
  - **iOS side (`hcd-tcp.c`):** a request that arrives after iOS turned USB off is answered NODEV instead of tripping QEMU's `usb_handle_packet` assertion (abort). An unknown message type reconnects instead of `assert_not_reached`, and a reset is ignored while detached.
  - **Restore ramdisk:** it boots with `-no-reboot`, so the VM really closes at the end of stage 1 instead of booting the ramdisk again.
  - **USB-host VM:**
    - **Modules:** a built-in (`=y`) EHCI/usbcore/crc32c no longer aborts the module list.
    - **Logging:** it logs its USB buses and the EHCI driver.
    - **usbmuxd rescan:** usbmuxd is restarted to rescan if the iPhone (05ac:129x/12ax) sits on the bus for 60 s without being listed. libusb there has no udev, so a missed hotplug event used to be final.
  - **IPSW check:** step 5 checks that the IPSW is readable in the chroot and has a BuildManifest.plist.
  - **Re-run:** step 3 (re-applies the iOS-side patch; `hcd-tcp.c` + relink), then step 5. Its first run rebuilds libirecovery, idevicerestore and the USB-host VM initramfs (a few minutes).
- **v1.2.11 NAK no longer drops the USB link:**
  - **Cause:** Inferno dev's async `usb-tcp-remote` (brought in by v1.2.9) answers every USB transfer asynchronously. When the iPhone side replied NAK ("no data yet", the normal answer to interrupt/bulk IN polling), it printed `USB_RET_NAK|ASYNC an ASYNC packet` and closed the whole link. With cc4302a's blocking version the same NAK simply went back to EHCI synchronously, and EHCI polled again. QEMU does not allow an async packet to be completed with NAK, so this case needs its own handling.
  - **Fix (in `inferno-usb-tcp-remote-async.patch`):**
    - **NAK:** the packet stays pending and the same request is sent to the iPhone side again after 2 ms, just as EHCI would re-poll. A cancel removes it from that retry list, and a disconnect drops the list (the detach cancels the packets).
    - **ASYNC reply:** an `ASYNC` reply leaves the packet pending until its final reply.
    - **Unknown status:** it is logged (`usb-tcp-remote: unexpected status …`, also shown by step 5) and fails only that packet with `USB_RET_IOERROR`.
    - **No status closes the link any more.**
  - **Re-run step 3:** it replaces the v1.2.10 version of the patch; only `hw/usb/dev-tcp-remote.c` is recompiled, plus the relink, ~5 min. Then run step 5.
- **v1.2.10 iOS side of the USB link:**
  - **How Inferno cc4302a connects (`hw/usb/hcd-tcp.c`):**
    - The iOS QEMU connects to the USB-host socket only in `usb_tcp_host_attach`. That runs when iOS sets DCTL RUN_STOP on the emulated DWC3 (`hcd-dwc3.c`), i.e. when the restore ramdisk enables USB. Nothing connects at machine init.
    - If `connect()` fails, it logs one "Cannot connect to server" line and never tries again until iOS turns USB off and on.
    - When the link drops (e.g. a USB-host VM restart), it never reconnects.
    - It also returns silently if the port has no attached device.
    - The `t8030` machine options are `usb-conn-type=unix|ipv4|ipv6` (no `unix:` prefix), `usb-conn-addr=<path>` and `usb-conn-port`. They are aliased through `atc` → OTG → `usb-tcp-host`. The ChefKiss guide's command passes none of them and uses the default socket path. Step 5 passes `usb-conn-type=unix,usb-conn-addr=/root/InfernoData/restore/usb.sock`, the same absolute path the USB-host VM binds. Both QEMUs are started by the same step-5 worker, so they share one mount namespace.
  - **New `inferno-usb-tcp-host-retry.patch` (iOS side, step 3):**
    - While iOS has USB on, a failed connect is retried every 2 s, and a dropped link reconnects by itself, so a restarted USB-host VM no longer needs an iOS reboot.
    - Every step is logged as `usb-tcp-host: …` (USB on / connect attempts / connected / closed).
    - The USB-host side logs `usb-tcp-remote: the iPhone connected/disconnected`.
  - **Step 5:**
    - Before booting iOS, it checks that the socket exists, has a listener, and that both QEMUs share the same mount namespace and root (these are printed).
    - Those USB messages from both QEMUs appear on screen as they happen.
    - The link check now reads the socket state in `/proc/net/unix` (listener `St 01`, accepted connection `St 03`).
    - If iOS reaches "waiting for host" without a link for 30 s, it says which side is missing: iOS never turned USB on, iOS is still trying, or iOS connected but the USB-host VM did not accept.
    - `run-t8030.sh` logs the full `-M t8030,…` line.
  - **Re-run step 3:** it recompiles `hw/usb/hcd-tcp.c` and `hw/usb/dev-tcp-remote.c` and relinks, about 5-10 min. Then run step 5.
- **v1.2.9 USB-host VM: Inferno's async usb-tcp-remote + crash fixes:**
  - **Why it still died:** in cc4302a the USB-host side of the virtual cable (`hw/usb/dev-tcp-remote.c`) runs a reader thread next to the QEMU main loop and busy-waits, with the global lock dropped, for every USB transfer. That leaves several ways to abort or crash under a slow, racy link:
    - responses parked in the completion queue for packets that EHCI had already cancelled and freed (use-after-free: "usb packet state check failed" or SIGSEGV);
    - the reader holding a packet pointer while it waits for the payload;
    - completing packets out of order (`usb_packet_complete` asserts the packet is first on its endpoint);
    - completing non-async packets on disconnect;
    - `error_abort` on a reattach.
  - **New `inferno-usb-tcp-remote-async.patch` (replaces the v1.2.7 patch; step 3 undoes the old one):**
    - It brings in Inferno `dev`'s rewrite of this device (7900ece "dev-tcp-remote: make async"): no thread, no busy-wait, every transfer async in the main loop. It only touches the USB-host side and the wire protocol is unchanged, so the iOS side (`hcd-tcp.c`) stays as is. Inferno `dev`'s iOS-side changes need newer QEMU I/O-channel APIs and are not backported.
    - On top of that: payloads are read before the packet is looked up, and a cancelled packet is removed from the completion queue. Completion waits for older packets on the same endpoint and skips packets that are no longer async. A disconnect leaves outstanding packets to the detach, which cancels them. A coroutine of an old connection cannot close the new one, a pending cleanup is finished before a new accept, and a failed attach is logged instead of aborting.
  - **XHCI was not used:** ChefKiss troubleshooting says not to use an XHCI controller ("currently not supported by the main VM side", Inferno #233), so the companion stays on EHCI.
  - **What step 5 prints when the USB-host VM stops:** right above the final `[ERROR]`, on one screen:
    - the exit status or signal and what it means;
    - where QEMU ended up: `oom_score_adj` and its cgroup, with a warning if it is still in an Android app cgroup;
    - any host OOM line;
    - the last 15 lines of the QEMU stderr, which carry the assertion text;
    - the last 8 guest console lines.
    
    The full report is saved as `restore/companion-report.<time>.txt`. The cgroup placement is also logged every time the USB-host VM starts.
  - **Re-run step 3:** it recompiles `hw/usb/dev-tcp-remote.c` (plus `dart.c` if v1.2.8's step 3 never ran) and relinks, usually 5-10 min. Then run step 5.
- **v1.2.8 SEP DART panic with verified SEP files:**
  - **What the panic is:** `t8020dart invalid lock state` comes from the iOS kernel's SEP DART driver. It panics when a DART interrupt arrives (`DART interrupt while disabled by the client`) while the driver has the DART disabled. In Inferno, the emulated SEP is its own vCPU whose whole DMA window goes through `dart-sep` (`apple_sep_from_node(..., apple_dart_iommu_mr(dart-sep))`). Under MTTCG it runs in parallel with, and on a slow phone often behind, the AP kernel. So an SEP access that faults just as the kernel turns the DART off raises exactly this interrupt. With good SEP files this is timing, not bad files. step 4's `check-sep.py` already verifies the ROM and firmware, and steps 5 and 6 refuse to boot otherwise.
  - **Inferno patch `inferno-dart-error-lock.patch` (step 3, incremental):** the AP clearing DART error bits (`ERROR_STATUS` write) was done without the lock that the SEP vCPU holds while it records a fault and raises the IRQ. A clear racing with a new fault could put back bits the kernel had already handled (a stale interrupt after it disabled the DART), or lower the IRQ over a new error. The clear and the IRQ re-evaluation now run under that lock. This removes one way to get the panic. It cannot remove the underlying SEP-vs-AP timing.
  - **Retried instead of stopping:** with verified SEP files (no `SKIP_SEP_CHECK=1`), `t8020dart invalid lock state` and `dart-sep … TTBR invalid` now reboot the iOS VM up to `PANIC_RETRIES` (3) times, without the "re-run step 4" hint. `SEP ROM boot panic` / `Img4Decode` still stop.
  - **`TCG_OPTS`:** e.g. `TCG_OPTS=thread=single` runs all vCPUs in one host thread, so the SEP and the AP cannot run truly in parallel. It is many times slower on a phone, so it is only an experiment.
  - **Checked against the current ChefKiss guide:** the machine options are the same (`sep-fw=sep-firmware.n104.RELEASE.new.img4,sep-rom=AppleSEPROM-Cebu-B1,ticket=root_ticket.der,kaslr-off=true`, same `-append`, `-smp 7 -m 4G`). Inferno reads exactly those files (`sep_fw_filename` / `sep_rom_filename`), and step 5 passes `$DATA/sep-firmware.n104.RELEASE.new.img4` and `$DATA/AppleSEPROM-Cebu-B1`, the same files `check-sep.py` checks. The Inferno `dev` branch has no DART/SEP fix for this panic: its DART changes are atomics with a per-stream TLB cache, and "maybe properly handle bypass" makes disabled translation an error instead of a bypass.
  - **Re-run step 3** (two files recompiled + relink), then step 5.
- **v1.2.7 USB-host VM crash fixed in Inferno, panics retried:**
  - **Inferno patch (`inferno-usb-tcp-remote-fix.patch`, applied by step 3):** Inferno's `usb-tcp-remote` cleanup completed packets that EHCI had already cancelled (the normal completion path checks `usb_packet_is_inflight`, the cleanup path did not), which aborts QEMU with "usb packet state check failed" (SIGABRT, exit 134) when the link drops. The patch adds that check. It also waits for the old connection to be torn down before accepting a new one, and reports a failed attach instead of aborting. Inferno's `dev` branch rewrote this device ("dev-tcp-remote: make async"), but it also renames the USB protocol and options and reworks the CPU locking, so it is not cherry-picked onto the pinned commit.
  - **Re-run step 3 once:** it applies the patch to the existing tree, and ninja recompiles only `hw/usb/dev-tcp-remote.c` and relinks `qemu-system-aarch64`, usually 3-10 min on a phone. Step 5 refuses to start until step 3 has written the `build/.ios-tools-patches` marker (`SKIP_PATCH_CHECK=1` skips the check).
  - **Lost USB host = reboot iOS right away:** Inferno's iOS side connects its USB cable only once, when iOS turns USB on. If the USB-host VM is restarted after that point, iOS never reconnects, and restored gives up after its 120 s "waiting for host to trigger start of restore" window. Step 5 now reboots the iOS VM immediately in that case, instead of waiting 15 min.
  - **Panic classification:** a panic is now detected while iOS is still running. Panics that mean bad SEP or firmware files stop step 5 with the `panic(cpu…)` line on the `[ERROR]` line itself: `dart-sep … TTBR invalid` and `t8020dart invalid lock state` (ChefKiss troubleshooting: "bad SEP ROM or SEP Firmware"), and `SEP ROM boot panic` / `Img4Decode`. Timing panics reboot the iOS VM, up to `PANIC_RETRIES` (3) times: `SEP/OS failed to boot`, `SEP ROM timeout - no response` (Inferno #54: "a random chance that SEP won't boot … just reboot"), watchdog, and restored giving up on its host.
- **v1.2.6 restore recovers from a lost USB-host VM:**
  - **Most likely cause of the companion dying when the ramdisk is ready:** Inferno's `usb-tcp-remote` relays every USB transfer between the two QEMUs asynchronously. Its reconnect/cleanup path completes queued packets without checking that they are still in flight, so a packet that EHCI already cancelled hits QEMU's packet-state assertion (SIGABRT). On the phone, the USB-host VM ran under TCG with **1 vCPU** (since v1.2.2), next to 7 iOS vCPUs, and also polled `lsusb` every 10 s. Its guest then time-outs and cancels URBs while iOS enumerates, which is exactly that race.
  - **USB-host VM now matches the ChefKiss reference companion:** `-m 1G -smp 2`, plus `nice -10`. It watches the bus through sysfs only (no `lsusb` control requests), and restarts usbmuxd forever instead of powering off.
  - **Step 5 keeps the iOS VM running if the USB-host VM stops:** it prints the reason (exit status / signal, e.g. 134 = assertion), restarts the USB-host VM (up to 6 times) and keeps the iOS VM running. iOS reconnects the next time it brings USB up. If it hasn't reconnected within `RECONNECT_WAIT` (900 s), the iOS VM is rebooted. Nothing is on its disks yet at that point.
  - **Failed attempts are retried:** a failed idevicerestore run (e.g. the USB-host VM died mid-restore) retries stage 1 from the blank disks, up to `STAGE1_ATTEMPTS` (3).
  - **idevicerestore starts within ~2 s of the device appearing:** polling is every 2 s (`DEVICE_POLL`), because iOS waits only 120 s for the host ("waiting for host to trigger start of restore").
- **v1.2.5 USB-host VM kept alive:**
  - **Why the VM died:** the app's root shell and everything it starts (both QEMUs) lived in the app's cgroup. There, Android's phantom-process killer and its per-app process-group kill can SIGKILL a CPU-heavy QEMU once the launcher is in the background (for example while you watch the VNC viewer).
  - **Steps now leave the app's cgroup:** steps 2-8 move themselves to the root cgroup (`/sys/fs/cgroup`, `/acct`) first. The USB-host VM also gets `oom_score_adj -800` and a 128 MB TCG code buffer (`COMPANION_TB_MB`).
  - **usbmuxd is restarted:** if usbmuxd exits inside the VM, it is restarted (up to 5 times) and the exit status is logged, instead of the VM powering off.
  - **Clearer failure report:** a wrapper records how QEMU ended (`companion/qemu.exit`: exit status or signal; 137 = SIGKILL). On failure, step 5 prints that reason, any host OOM lines, the last 40 console lines, the QEMU log, and the usbmuxd log without the client connect/disconnect lines. The same report is available with `bash /root/companion-vm.sh report`.
  - **USB link in the progress line:** the 2-minute progress line shows whether the iOS VM has connected to the USB-host VM yet (`USB link connected/not yet`). Inferno connects only once, when iOS enables its USB controller, which can take an hour under TCG on a phone. If that connect fails, step 5 stops with a clear error. `DEVICE_TIMEOUT` is now 6 h.
- **v1.2.4 SEP firmware rewrap fix:** on the phone, step 4's `img4 -A -F … -T rsep` wrote the IM4P type as `pesr`. xerub's img4lib only byte-swaps fourccs when `__LITTLE_ENDIAN__`, `__x86_64__` or `__i386__` is defined, and GCC on arm64 Linux defines none of them (it defines `__AARCH64EL__` / `__BYTE_ORDER__`). Every SEP firmware that step 4 built on the phone, in all earlier versions, therefore had the wrong type. That is the most likely cause of the `dart-sep` / `t8020dart invalid lock state` restore panic. Step 4 now writes the IMG4 itself (`check-sep.py wrap`): `IMG4 { IM4P { "rsep", <version string copied from the IPSW's im4p>, <decrypted payload> }, [0] <sep_root_ticket.der> }`. The output is byte-identical to what img4lib builds on x86_64. img4lib is still used only to decrypt, which is endian-safe, and new img4lib builds get `-D__LITTLE_ENDIAN__=1`. The `none` line in the log is img4lib's normal output, not an empty version string. Re-run step 4 (it replaces the bad file), then step 5.
- **v1.2.3 SEP checks:** `panic(... caller 0xfffffff009686304): "t8020dart invalid lock state"` right after `Id(dart-sep) AppleT8020DART::_interruptHandler: DART interrupt while disabled by the client` means the SEP made a DMA access that faulted in the SEP DART. The ChefKiss FAQ entry for the related `dart-sep ... DART(DART) error` panic says "User error; bad SEP ROM or SEP Firmware", and issue #314 (iOS VM crashing after idevicerestore) was a wrong IV/key. iOS 14.0 beta 5 (18A5351d) on iPhone12,1 is still the target of the ChefKiss guide. New `check-sep.py` checks that the SEP ROM is the Cebu B1 dump (86016 bytes, sha256 `e3b11f62…`). It also checks that `sep-firmware.n104.RELEASE.new.img4` is an IMG4 of type `rsep` that holds a *decrypted* SEPOS, has the SEP ticket attached, and uses the exact IM4P version string of the IPSW's `sep-firmware.n104.RELEASE.im4p`. Step 4 now runs these checks: it downloads a bad SEP ROM again, moves a bad SEP firmware to `.bad` and rebuilds it, and stops with an `[ERROR]` if the IV/Key (from The Apple Wiki or `sep_ivkey.txt`) does not decrypt the SEP firmware. Steps 5 and 6 refuse to boot with bad SEP files. Re-run step 4 once after updating (it only redoes the SEP part); step 3 does not need to be re-run.
- **v1.2.2 restore panic diagnostics:** the `IOPlatformPanicAction -> AppleS8960XWatchDogTimer / AppleT8030PMGR` and `wdog panic (attempt 1)` lines are printed for *every* iOS panic, so they don't show the cause, and `wdt=-1` is already passed. On failure, step 5 now prints the 40 lines before and after the first panic line and keeps every attempt's full serial log as `InfernoData/restore/ios-serial.<time>.log`. `-smp` now defaults to 7, as in the ChefKiss guide: Inferno uses one of the `-smp` CPUs for the emulated SEP, so 6 gave only 5 A13 cores. The USB-host VM uses 1 vCPU during the restore so the SEP and iOS cores get more of the phone's CPU. No Inferno rebuild needed.
- **v1.2.1 keymap fix:** the iOS VM died at start with `could not read keymap file: 'en-us'`: the step 3 build-tree QEMU was never installed, so it had no data dir. `run-t8030.sh` and `companion-vm.sh` now find one at runtime (build `qemu-bundle`/`pc-bios`, `/usr/local/share/qemu`, `/usr/share/qemu`, else the Inferno source's `pc-bios/keymaps`) and pass it with `-L`. No rebuild needed.
- **v1.2.0:** new step 5 **Restore iOS (automatic)** (see above). Steps after it
  are renumbered: 6 Boot, 7 Status, 8 Jailbreak. Boot now refuses a blank or
  half-restored disk and tells you to run step 5. Step 8 writes the jailbreak
  bootstrap with the same USB-host VM (linux-apfs-rw), so no Mac is needed.
- **v1.1.8 Boot VNC fix:** QEMU 10 rejected `-display vnc=…,show-cursor=on` (`Invalid parameter 'show-cursor'`). Default is now `-display vnc=127.0.0.1:0`.
- **v1.1.7 step 3/4 fixes:**
  - Step 3 never produced `qemu-img` / `qemu-system-aarch64`. Inferno's
    `--enable-nettle` needs nettle >= 3.10; step 2 builds 3.10.2, but nettle
    installs into `/usr/local/lib64`, which pkg-config and ld.so do not search,
    so configure kept seeing bookworm's 3.8. Both paths are now registered.
  - Step 3 only fetches the `util/mlib` submodule. The old
    `submodule update --init --recursive` also pulled every QEMU firmware ROM
    repo (edk2, u-boot, seabios, ...: several GB) that the build never uses.
  - Source is a shallow fetch of the pinned commit with retries; if git keeps
    dropping the connection (`GnuTLS recv error`), it falls back to GitHub's
    source tarball.
  - Re-runs: an identical finished configure is resumed with `ninja`, anything
    else (other commit/flags, failed configure, interrupted clone) is wiped
    first. `CLEAN=1` forces a fresh build dir, `CLEAN_SRC=1` a fresh source.
  - The job count follows free RAM, and an OOM-killed compile is resumed with
    `-j1`. Only `aarch64-softmmu` is built (`FULL_TARGETS=1` adds x86_64), and
    GTK/SDL are off because the display is VNC. The step ends by checking that
    the binary has the `t8030` machine.
  - Step 4: the SEP IV/Key lookup no longer depends on one HTML page fetch (that
    got a 403 on some networks). It tries The Apple Wiki raw wikitext, its API, and
    the rendered page, each with browser headers through both curl and
    Python. The keys stay in memory only. If every source fails, paste the
    SEPFirmware IV followed by the Key (no spaces) into `/data/local/debian/root/InfernoData/sep_ivkey.txt` and re-run.
  - Step 4: the SEP `-V` version string is now taken from the decrypt command's
    output, as in the ChefKiss guide. Kernel, DeviceTree, Erase ramdisk, its
    trustcache, and SEP paths are read from `BuildManifest.plist`.
  - Step 5: the restore ramdisk is only passed while the `root` disk is blank
    (`RESTORE_MODE=1` forces it), and `sep_nvram` is kept at 64 KiB.
- **v1.1.3 Install & update Debian:** step 1 is now **Install & update Debian**.
  After the rootfs is in place (or if it already is) it runs `apt-get update`
  and `apt-get upgrade -y` inside the chroot and stops with a clear error if
  either fails. Re-running it on an existing install just updates Debian.
  apt downloads as root (`APT::Sandbox::User "root"`), because Android only
  lets the inet group open sockets. `enter-debian.sh` now enters with a clean
  Debian environment, which removes the `/etc/profile: id: command not found`
  noise.
- **v1.1.3 lzfse fix (step 2):** Debian bookworm has no `liblzfse-dev` / `lzfse`
  packages, so `apt-get install` failed. `setup-build-deps.sh` now installs the
  rest from apt (plus `cmake`), then builds lzfse from
  [lzfse/lzfse](https://github.com/lzfse/lzfse) at pinned commit `e634ca5`
  into `/usr/local` (`liblzfse.so`, `lzfse.h`, `lzfse` CLI), and checks that a
  test program links against `-llzfse`. Any apt or build failure stops the step
  with an `[ERROR]` line.
- **v1.1.2 chroot fix:** the "can't create .../etc/resolv.conf" failure came
  from the Debian image's `etc/resolv.conf`, which is an absolute symlink into
  `/run/systemd/...`. Writing through it from Android followed it onto the
  phone's own `/run`. It is now replaced with a real file. The rootfs is also
  extracted into a staging dir and moved into place only after verification,
  with xz/tar exit codes logged and full cleanup on failure. `setup-build-deps.sh`
  now installs Debian's `libjpeg62-turbo-dev` (the Ubuntu-only package name
  used before made the whole `apt-get install` fail without saying so) and stops
  if apt fails.
- **v1.1.1 chroot fix:** Debian rootfs now comes from linuxcontainers.org
  (multi-MB `rootfs.tar.xz`); a static `xz-arm64` is bundled because Android
  toybox `tar` cannot decompress xz. Failed/partial downloads are removed so
  re-running works.
- **IPSW auto-download.** On first "Download & Configure" the app pulls the
  Inferno reference IPSW **directly from Apple's CDN** onto your phone
  (~5.5 GB). Nothing from Apple is shipped in this repo or the module zip.
  Apple's license covers downloading firmware yourself from Apple; it does
  **not** cover redistributing IPSWs. Do not re-upload the file.
- Reference target: **iOS 14.0 beta 5 for iPhone12,1** (build `18A5351d`).
  Inferno supports iOS 14.x on t8030 today.
- Inferno is built **on-device inside a Debian (glibc) chroot**. On an 8 GB-class
  phone the build is heavy; a strong phone with lots of RAM/storage is strongly
  recommended. Plan on **≥10 GB free** before Download & Configure
  (IPSW + extract + sparse root disk).

## Install

1. KernelSU manager → Modules → install `qemu-t8030-launcher-v1.6.0.zip`, reboot.
2. Open "iOS Emu (t8030)", grant root.

## Use (buttons, top to bottom)

The module also adds an **iOS Emu Logs** icon (green page): the full step log on its own
screen (Copy / Clear), live while a step runs and kept across runs in the
app's `files/launcher.log` (rotated at 4 MB). The main screen keeps a short
log strip under the buttons.

1. **Install & update Debian** — Debian arm64 rootfs at `/data/local/debian` +
   `/data/local/enter-debian.sh`, then `apt-get update` + `apt-get upgrade -y`
   inside the chroot. Re-run any time to update Debian.
2. **Install build deps** — git, ninja, meson >= 1.5 (from PyPI; bookworm's is 1.0.1), glib, pixman, gnutls, nettle
   (built from source if Debian's is < 3.10), lzfse (built from source;
   bookworm has no package), etc.
3. **Compile Inferno / qemu-t8030 in the chroot**: checks meson >= 1.5 and
   nettle >= 3.10, fetches `ChefKissInc/Inferno` at the pinned commit (+ `util/mlib`),
   configures `aarch64-softmmu` with VNC output, and builds `qemu-system-aarch64` +
   `qemu-img` into `/root/Inferno/build`. **Long build** (30-90 min). Safe to
   re-run: it resumes or cleans as needed.
4. **Download & Configure (Apple IPSW)** — the one-tap setup:
   - `curl -C -` resumes the IPSW from Apple's CDN
   - verifies the expected `Content-Length` (5507405643 bytes)
   - creates Inferno backing disks (`qemu-img`)
   - extracts the IPSW into `/root/InfernoData/Restore`
   - fetches ChefKiss `create_apticket.py` / `create_septicket.py` / `ticket.shsh2`
   - fetches `AppleSEPROM-Cebu-B1` from [securerom.fun](https://securerom.fun)
   - forges `root_ticket.der` + `sep_root_ticket.der`
   - builds [xerub/img4lib](https://github.com/xerub/img4lib), looks up the
     SEP IV+Key for this build from
     [The Apple Wiki](https://theapplewiki.com/wiki/Keys:AzulSeed_18A5351d_(iPhone12,1))
     at runtime (keys are **not** stored in the repo), decrypts/rewraps
     `sep-firmware.n104.RELEASE.new.img4`
   - auto-detects kernel / DeviceTree / trustcache / ramdisk filenames
   - writes `run.env` + `READY` so Boot just works
5. **Restore iOS (automatic)**: builds the restore tools on first run, then
   restores the IPSW onto the blank disk and applies the filesystem patches.
   See [Automatic restore](#automatic-restore-v120-step-5). Long; tap again to
   re-attach.
6. **Boot iOS (t8030)**: runs `run-t8030.sh` (VNC on `127.0.0.1:5900`). The
   built-in viewer opens by itself once the VNC port is up. The first boot
   after the restore finishes data migration.
6b. **Boot iOS with network (experimental)**: `NET=1 run-t8030.sh`, USB
   ethernet (reverse tethering) through the USB-host VM. Can panic iOS 14.0 on
   the mode-3 switch (it then retries once without network), or the guest may
   never take a DHCP address. Prefer 6c.
6c. **Force network (companion first + NET=1)**: runs `force-net.sh`. It stops
   any running VMs, starts the USB-host VM in net mode first
   (`companion-vm.sh net`: mode 3 + bridge to SLIRP), then boots iOS with
   `NET=1 NET_RETRY=0`. iOS only takes an address when told to, and its USB
   ethernet is not always `en0`, so 6c also types into the root shell on the
   serial console (needs step 8 applied): it waits until the shell answers
   (`[*] DHCP kick: iOS shell answered`), then asks iOS for its interfaces
   (`ipconfig getiflist`, logged as `[*] iOS network interfaces: ...`), runs
   DHCP on the `en*` ones and checks their addresses. Commands are typed 8
   bytes at a time (long bursts lose characters on the guest serial port) and
   each one is waited for before the next is sent (every `ipconfig` call takes
   seconds under TCG); Ctrl-C only clears a hung command. The first
   interface with a `10.0.2.x` lease wins, the kick stops and logs
   `[*] iOS has network: en2 10.0.2.15 ...`; it keeps trying for as long as
   the VM runs. By hand, on the serial console (`enN` = that interface):

   ```sh
   /usr/sbin/ipconfig set enN DHCP
   /usr/sbin/ipconfig getifaddr enN   # expect 10.0.2.x
   ```

   Gateway `10.0.2.2`, DNS `10.0.2.3` (the USB-host VM's SLIRP). If iOS
   panics on the mode-3 switch, boot with step 6 (no network), start
   `companion-vm.sh net` afterwards, then run the same `ipconfig` commands.
7. **Show READY / restore status**: shows what's configured, what's still
   missing, the restore state, and the jailbreak status.
8. **Jailbreak bootstrap (after restore)**: see [Jailbreak](#jailbreak-what-you-get-honestly).

### Apple IPSW URL used

```
https://updates.cdn-apple.com/2020SummerSeed/fullrestores/001-35886/5FE9BE2E-17F8-41C8-96BB-B76E2B225888/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw
```

Filename: `iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw` · size `5507405643`
bytes (verified via HTTP HEAD, Oct 2026). Same URL the ChefKiss file-setup guide
and the NixOS iOS-emulation wiki document.

### Manual / advanced

```sh
# inside the chroot
DATA=/root/InfernoData bash /root/download-and-configure.sh
cd /root/InfernoData && bash /root/run-t8030.sh
# restore/upgrade ramdisk:
RESTORE_MODE=1 bash /root/run-t8030.sh   # force the restore ramdisk
RESTORE_MODE=0 bash /root/run-t8030.sh   # force a normal boot

# restore (what step 5 does):
DATA=/root/InfernoData bash /root/restore-ios.sh          # start / re-attach
DATA=/root/InfernoData bash /root/restore-ios.sh status
DATA=/root/InfernoData bash /root/restore-ios.sh stop
```

```sh
# the USB-host VM by hand
DATA=/root/InfernoData bash /root/companion-vm.sh usbmux   # usbmuxd on 127.0.0.1:27015
USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015 /opt/inferno-restore/bin/idevice_id -l
DATA=/root/InfernoData bash /root/companion-vm.sh apfs-run 'ls "$SYSVOL"'
DATA=/root/InfernoData bash /root/companion-vm.sh stop
```

## Jailbreak (what you get, honestly)

**Kernel side, always on.** Inferno patches the iOS kernel inside QEMU on every
boot (`hw/arm/apple-silicon/kernel_patches.c` at `cc4302a`). That covers the
AMFI trust-cache bypass (every binary counts as trusted), the code-signature and
`pmap_cs` bypasses, unsigned img4, rootfs remount and union mounts, and the APFS
update snapshot being disabled. So unsigned binaries already run, and there's no
`amfi=` boot-arg to add.

**Userland: added by step 8 / `jailbreak-prep.sh`.** This follows ChefKiss's
documented [Filesystem Patches](https://chefkiss.dev/guides/inferno/fs-patches/)
and [Jailbreak Utility Bootstrap](https://chefkiss.dev/guides/inferno-post-setup/jailbreak-bootstrap/)
pages:
- downloads the checkra1n **core bootstrap** (`strap.tar.lzma`: bash, apt,
  coreutils, ...) from `assets.checkra.in` at runtime. It is never stored in the
  repo. `WITH_CYDIA=1` also stages Cydia.app.
- builds [InfernoFSPatcher](https://git.chefkiss.dev/AppleHax/InfernoFSPatcher)
  (AGPL-3.0, cloned at runtime), which patches the dyld cache for software
  rendering.
- `check-sep.py` - checks the SEP ROM and the prepared SEP firmware (used by steps 4-6)
- `patch-launchd.py` disables the services that break on the emulator (vmd,
  CommCenter*, locationd) and adds a root `/bin/bash` daemon on `/dev/console`.
- after applying, `run-t8030.sh` adds `launchd_unsecure_cache=1`, and you get a
  root shell on the serial console.

**What it can't do:**
- **palera1n/checkra1n can't run against this guest.** The emulator jumps
  straight into the kernel with no SecureROM, iBoot or DFU, so there's nothing
  for checkm8 to hit (Inferno maintainer, Discussion #162). No Sileo/Dopamine-style
  on-device jailbreak app is involved.
- **It isn't there on first boot by itself.** The bootstrap has to be written
  onto the *restored* APFS System volume, so run step 5 first. ChefKiss
  documents writing that volume only from macOS (`hdiutil`/`diskutil`). On
  Linux it needs the out-of-tree linux-apfs-rw driver, which stock Android
  kernels don't have. So:
  - step 8 boots the USB-host VM from step 5 (Debian kernel + linux-apfs-rw)
    and applies everything there. It makes a sparse backup
    `root.pre-jailbreak` first if there's room. If your phone kernel lists
    `apfs` in `/proc/filesystems`, that is used instead.
  - fallback: step 8 also stages `jailbreak/apply-on-mac.sh`. Copy `root` and
    `jailbreak/` to a Mac, run `sudo ./apply-on-mac.sh /path/to/root`, copy
    `root` back, then `touch /root/InfernoData/JAILBREAK_APPLIED`.
- Not tested on a real restored disk (none on the build host).

## Scripts

- `setup-debian-chroot.sh` — shared chroot bootstrap (same as general-kvm).
- `setup-build-deps.sh` — install Inferno build dependencies (+ nettle 3.10 if
  needed).
- `build-inferno.sh` — clone + configure + build Inferno (pinned commit
  `cc4302a`, override with `REF=`).
- `download-and-configure.sh` — **new in v1.1.0**: Apple IPSW download + full
  file prep + `run.env`.
- `prepare-ios-files.sh` — create disks + extract IPSW (called by the
  downloader; safe to re-run).
- `jailbreak-prep.sh` — **v1.1.2**: stage/apply the jailbreak bootstrap
  (`stage` | `apply` with `SYSVOL=` | `status`). Also run automatically at the
  end of Download & Configure (stage only unless an APFS rw driver exists).
- `patch-launchd.py` — idempotent launchd.plist editor (Linux/macOS, stdlib).
- `run-t8030.sh` — the full `qemu-system-aarch64 -M t8030 …` command line;
  sources `run.env` when present. `RESTORE_MODE=1|0`, `USB_CONN_TYPE/ADDR/PORT`,
  `SERIAL_QEMU` overrides.
- `force-net.sh` — **v1.5.3** step 6c: USB-host VM in net mode first, then
  `NET=1` boot; types the guest `ipconfig` DHCP kick (every `en*` interface iOS lists) into the serial console.
- `restore-ios.sh` — **v1.2.0** step 5 orchestrator (detached worker, state in
  `InfernoData/restore/state`).
- `build-restore-tools.sh` — **v1.2.0** builds `/opt/inferno-restore`
  (libimobiledevice stack, idevicerestore + patch, usbmuxd, no-udev libusb,
  InfernoFSPatcher, USB-host VM kernel/initramfs + apfs.ko).
- `companion-vm.sh` / `companion-init.sh` — **v1.2.0** the USB-host VM
  (`usbmux` | `apfs-run CMD` | `stop` | `status`) and its initramfs `/init`.
- `idevicerestore-inferno.patch` — ChefKiss's idevicerestore patch (maps the
  emulated `…DEV` hardware model to `…AP`).

## Verified vs not

- Verified on the build host: APK assembles; scripts pass `bash -n`; module zip
  has `module.prop` at root; Apple CDN URL returns HTTP 200 with the expected
  `Content-Length`; ChefKiss extras + SEPROM URLs return 200; Apple Wiki keys
  page parses (`#keypage-sepfirmware-iv` / `-key`).
- **Not** verified: the on-device Inferno build, a live 5.5 GB IPSW download on a
  phone, img4 decrypt/rewrap of SEP firmware, and an actual iOS boot (no phone
  on the build host). Treat on-device steps as "should work", not "tested here".
- v1.2.0 restore, verified on the build host: against the Inferno source at
  `cc4302a`, `usb-tcp-remote` (`CONFIG_USB_TCP`, default y) and the `virt`
  machine are in the aarch64 build, and step 3 already enables slirp and
  virtfs. In the pinned sources, `usbmuxd -S ADDR:PORT`, libusbmuxd's
  `USBMUXD_SOCKET_ADDRESS`, and idevicerestore's `--restore-mode/--no-input/
  --plain-progress/-T/--cache-path` options all exist, and ChefKiss's patch
  applies to the pinned idevicerestore. All the bookworm arm64 package names
  exist. Debian 6.1.0-50-arm64 builds virtio/9p/EHCI as modules with 4 KiB
  pages. The OS image in the 18A5351d IPSW is stored uncompressed (zip
  central directory read from Apple's CDN), so it is never extracted. The
  libusb tarball sha256 is checked. The scripts pass `bash -n`.
- v1.2.0 restore, **not** verified: the full tool build, the USB-host VM
  boot, usbmuxd seeing the emulated iPhone, the idevicerestore run itself,
  and linux-apfs-rw writes to a real iOS System volume. The first run on the
  phone is the real test, so send the step 5 log if it fails.
