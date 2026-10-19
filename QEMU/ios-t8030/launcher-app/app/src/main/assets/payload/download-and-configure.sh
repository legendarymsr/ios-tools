#!/usr/bin/env bash
#
# download-and-configure.sh
# On first run: download the Inferno reference IPSW from Apple's official CDN
# onto THIS device, extract it, create backing disks, fetch ChefKiss tooling +
# SEPROM, forge the AP/SEP tickets, prepare sep-firmware, auto-detect firmware
# filenames, and write run.env so "Boot iOS" just works.
#
# LEGAL / HONEST:
#   - The IPSW is downloaded at runtime from Apple's servers for your personal
#     use. Nothing from Apple is shipped in the repo or the module zip.
#   - Apple's license covers downloading firmware yourself from Apple; it does
#     NOT cover redistributing IPSWs. Do not upload the downloaded IPSW.
#   - ChefKiss's guide asks users not to automate their file-setup. This script
#     exists because you asked for a one-tap on-device flow; it still pulls every
#     copyrighted blob from the original host (Apple / securerom.fun) at runtime.
#   - TCG only, SLOW, no GPU, bring-up quality. Needs ~8 GB free for the IPSW
#     plus ~32 GB for the root disk image (sparse-capable).
#
# Run INSIDE the Debian chroot, after Inferno is built (needs qemu-img) and
# preferably after build deps (python3, pip, git, openssl, build-essential).
# Env:
#   DATA       work dir (default /root/InfernoData)
#   QEMU_IMG   path to qemu-img (default /root/Inferno/build/qemu-img)
#   SKIP_IPSW_DOWNLOAD=1   reuse an already-downloaded IPSW in $DATA
#   SKIP_SEP=1             skip SEP firmware decrypt/rewrap (leave for later)
set -eu

DATA="${DATA:-/root/InfernoData}"
QEMU_IMG="${QEMU_IMG:-/root/Inferno/build/qemu-img}"

# Inferno reference target: iOS 14.0 beta 5 for iPhone12,1 (iPhone 11 / t8030).
# Same URL the ChefKiss guide and the NixOS iOS-emulation wiki point at.
IPSW_URL="${IPSW_URL:-https://updates.cdn-apple.com/2020SummerSeed/fullrestores/001-35886/5FE9BE2E-17F8-41C8-96BB-B76E2B225888/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw}"
IPSW_NAME="iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw"
IPSW_SIZE="${IPSW_SIZE:-5507405643}"   # Content-Length verified Oct 2026

CHEFKISS_EXTRAS="${CHEFKISS_EXTRAS:-https://chefkiss.dev/Extras/Inferno}"
SEPROM_URL="${SEPROM_URL:-https://securerom.fun/resources/SEPROM/AppleSEPROM-Cebu-B1}"
SEPROM_SIZE="${SEPROM_SIZE:-86016}"
KEYS_URL="${KEYS_URL:-https://theapplewiki.com/wiki/Keys:AzulSeed_18A5351d_(iPhone12,1)}"
IMG4LIB_REPO="${IMG4LIB_REPO:-https://github.com/xerub/img4lib.git}"

UA="Mozilla/5.0 (Linux; Android 14) ios-tools-download/1.1"
mkdir -p "$DATA"
cd "$DATA"

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "need '$1' in PATH (install build deps / enter the Debian chroot)"; }

need_cmd curl
need_cmd unzip
need_cmd python3

# ---------- space check ----------
avail_kb=$(df -Pk "$DATA" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 9000000 ]; then
  warn "Low free space (~$((avail_kb/1024)) MB). IPSW alone is ~5.1 GiB; recommend ≥10 GiB free."
fi

# ---------- download helper (resume) ----------
fetch() {
  # fetch URL DEST [expected_size]
  local url="$1" dest="$2" expect="${3:-}"
  if [ -f "$dest" ] && [ -n "$expect" ]; then
    local have
    have=$(wc -c < "$dest" | tr -d ' ')
    if [ "$have" = "$expect" ]; then
      log "already have $dest ($have bytes)"
      return 0
    fi
    log "incomplete $dest ($have / $expect) — resuming"
  fi
  log "downloading $url"
  log "         -> $dest"
  # curl: resume, follow redirects, show a progress bar that the app log can stream
  curl -L --fail --retry 5 --retry-delay 3 -C - \
    -A "$UA" \
    --progress-bar \
    -o "$dest" \
    "$url" || die "download failed: $url"
  if [ -n "$expect" ]; then
    local have
    have=$(wc -c < "$dest" | tr -d ' ')
    [ "$have" = "$expect" ] || die "size mismatch for $dest: got $have, expected $expect"
    log "verified size $have"
  fi
}

# ---------- 1. IPSW from Apple ----------
IPSW="$DATA/$IPSW_NAME"
if [ "${SKIP_IPSW_DOWNLOAD:-0}" != "1" ]; then
  fetch "$IPSW_URL" "$IPSW" "$IPSW_SIZE"
else
  [ -f "$IPSW" ] || die "SKIP_IPSW_DOWNLOAD set but $IPSW missing"
fi

# ---------- 2. backing disks + extract (via prepare-ios-files.sh if present) ----------
PREPARE="$(dirname "$0")/prepare-ios-files.sh"
if [ ! -x "$QEMU_IMG" ]; then
  warn "qemu-img not at $QEMU_IMG — skipping disk creation. Build Inferno first (step 3), then re-run."
else
  if [ ! -f "$DATA/root" ]; then
    log "creating raw backing disks"
    DATA="$DATA" QEMU_IMG="$QEMU_IMG" bash "$PREPARE" "$IPSW" || {
      # prepare script also extracts; if it failed mid-way, continue carefully
      warn "prepare-ios-files.sh returned non-zero; continuing with best-effort extract"
    }
  else
    log "backing disks already present — leaving them alone"
  fi
fi

if [ ! -f "$DATA/Restore/BuildManifest.plist" ]; then
  log "extracting IPSW into $DATA/Restore (this takes a few minutes)"
  mkdir -p "$DATA/Restore"
  # unzip is loud; keep names so the app log shows progress
  ( cd "$DATA/Restore" && unzip -o "$IPSW" ) || die "IPSW extract failed"
fi

# Drop the largest .dmg (main OS image) — only needed by the companion restore VM.
if [ -d "$DATA/Restore" ]; then
  big=$(find "$DATA/Restore" -maxdepth 1 -type f -name '*.dmg' -printf '%s %p\n' 2>/dev/null | sort -nr | head -1 | awk '{print $2}')
  if [ -n "${big:-}" ]; then
    bsz=$(wc -c < "$big" | tr -d ' ')
    if [ "$bsz" -gt 2000000000 ]; then
      log "removing large OS dmg to save space: $big ($bsz bytes)"
      rm -f "$big"
    fi
  fi
fi

# ---------- 3. ChefKiss tooling (scripts + ticket template) ----------
log "fetching ChefKiss apticket / septicket tooling"
fetch "$CHEFKISS_EXTRAS/create_apticket.py"  "$DATA/create_apticket.py"
fetch "$CHEFKISS_EXTRAS/create_septicket.py" "$DATA/create_septicket.py"
fetch "$CHEFKISS_EXTRAS/ticket.shsh2"        "$DATA/ticket.shsh2"
chmod +x "$DATA/create_apticket.py" "$DATA/create_septicket.py"

# ---------- 4. SEP ROM dump (Cebu B1 for t8030 / iPhone 11) ----------
fetch "$SEPROM_URL" "$DATA/AppleSEPROM-Cebu-B1" "$SEPROM_SIZE"

# ---------- 5. python deps + forge AP ticket ----------
log "ensuring pyasn1 is available"
python3 -m pip install --user -q pyasn1 pyasn1-modules 2>/dev/null \
  || pip3 install --user -q pyasn1 pyasn1-modules 2>/dev/null \
  || apt-get install -y python3-pyasn1 python3-pyasn1-modules >/dev/null 2>&1 \
  || warn "could not install pyasn1 — apticket step may fail"

if [ ! -f "$DATA/root_ticket.der" ]; then
  log "forging AP ticket (root_ticket.der)"
  python3 "$DATA/create_apticket.py" n104ap \
    "$DATA/Restore/BuildManifest.plist" \
    "$DATA/ticket.shsh2" \
    "$DATA/root_ticket.der" \
    || die "create_apticket.py failed"
else
  log "root_ticket.der already present"
fi

if [ ! -f "$DATA/sep_root_ticket.der" ]; then
  log "forging SEP ticket (sep_root_ticket.der)"
  python3 "$DATA/create_septicket.py" n104ap \
    "$DATA/Restore/BuildManifest.plist" \
    "$DATA/ticket.shsh2" \
    "$DATA/sep_root_ticket.der" \
    || warn "create_septicket.py failed — SEP firmware rewrap will be skipped"
fi

# ---------- 6. auto-detect firmware component filenames ----------
RESTORE="$DATA/Restore"
KERNEL=$(ls "$RESTORE"/kernelcache.research.* 2>/dev/null | head -1 || true)
DTB=$(ls "$RESTORE"/Firmware/all_flash/DeviceTree.n104ap.im4p 2>/dev/null | head -1 || true)
# trustcache sits next to the ramdisk .dmg; pick the one matching *.dmg.trustcache
TRUSTCACHE=$(ls "$RESTORE"/Firmware/*.dmg.trustcache 2>/dev/null | head -1 || true)
# Erase/Upgrade ramdisk (used for restore)
RAMDISK=$(ls "$RESTORE"/038-*.dmg 2>/dev/null | head -1 || true)
SEPFW_IM4P=$(ls "$RESTORE"/Firmware/all_flash/sep-firmware.n104.RELEASE.im4p 2>/dev/null | head -1 || true)

[ -n "$KERNEL" ]     || warn "kernelcache.research.* not found under Restore/"
[ -n "$DTB" ]        || warn "DeviceTree.n104ap.im4p not found"
[ -n "$TRUSTCACHE" ] || warn "no *.dmg.trustcache found"
[ -n "$SEPFW_IM4P" ] || warn "sep-firmware.n104.RELEASE.im4p not found"

# ---------- 7. SEP firmware decrypt + rewrap (img4lib) ----------
SEPFW_OUT="$DATA/sep-firmware.n104.RELEASE.new.img4"
if [ "${SKIP_SEP:-0}" = "1" ]; then
  warn "SKIP_SEP=1 — not preparing $SEPFW_OUT"
elif [ -f "$SEPFW_OUT" ]; then
  log "SEP firmware already prepared: $SEPFW_OUT"
elif [ -z "${SEPFW_IM4P:-}" ] || [ ! -f "$DATA/sep_root_ticket.der" ]; then
  warn "missing SEP im4p or sep_root_ticket.der — skipping SEP prep"
else
  log "building img4lib (xerub) for SEP firmware rewrap"
  if [ ! -x "$DATA/img4lib/img4" ]; then
    need_cmd git
    need_cmd make
    rm -rf "$DATA/img4lib"
    git clone --depth 1 "$IMG4LIB_REPO" "$DATA/img4lib"
    # Debian/openssl paths
    make -C "$DATA/img4lib" \
      LDFLAGS="-L/usr/lib/aarch64-linux-gnu -L/usr/local/lib" \
      CFLAGS='-I/usr/include/openssl -I/usr/local/include -Wall -W -pedantic -Wno-variadic-macros -Wno-multichar -Wno-four-char-constants -Wno-unused-parameter -O2 -I. -g -DiOS10 -DDER_MULTIBYTE_TAGS=1 -DDER_TAG_SIZE=8 -D__unused="__attribute__((unused))"' \
      || warn "img4lib build failed"
  fi
  if [ -x "$DATA/img4lib/img4" ]; then
    log "fetching SEP IV+Key for 18A5351d / iPhone12,1 from The Apple Wiki (not stored in the repo)"
    KEYS_HTML="$DATA/.keys-18A5351d.html"
    curl -fsSL -A "$UA" -o "$KEYS_HTML" "$KEYS_URL" || warn "could not fetch keys page"
    SEP_IV=$(python3 - "$KEYS_HTML" <<'PY'
import re,sys
h=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'id="keypage-sepfirmware-iv">([a-f0-9]{32})</code>', h)
print(m.group(1) if m else '')
PY
)
    SEP_KEY=$(python3 - "$KEYS_HTML" <<'PY'
import re,sys
h=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'id="keypage-sepfirmware-key">([a-f0-9]{64})</code>', h)
print(m.group(1) if m else '')
PY
)
    rm -f "$KEYS_HTML"
    if [ -n "$SEP_IV" ] && [ -n "$SEP_KEY" ]; then
      log "decrypting SEP firmware (IV/Key from wiki, used in-memory only)"
      "$DATA/img4lib/img4" -v \
        -i "$SEPFW_IM4P" \
        -o "$DATA/sep-firmware.n104.RELEASE" \
        -k "${SEP_IV}${SEP_KEY}" \
        || warn "img4 decrypt failed"
      # Grab the build version string the rewrap needs (-V). Upstream guide uses
      # the output of the decrypt step; fall back to a known-good value for this build.
      SEP_VER=$("$DATA/img4lib/img4" -v -i "$SEPFW_IM4P" -k "${SEP_IV}${SEP_KEY}" 2>/dev/null | awk '/version:/{print $2; exit}' || true)
      # If img4 -v doesn't print a usable version, leave -V empty and let img4 decide.
      log "rewrapping SEP firmware -> $SEPFW_OUT"
      if [ -n "${SEP_VER:-}" ]; then
        "$DATA/img4lib/img4" -A -F \
          -o "$SEPFW_OUT" \
          -i "$DATA/sep-firmware.n104.RELEASE" \
          -M "$DATA/sep_root_ticket.der" \
          -T rsep -V "$SEP_VER" \
          || warn "img4 rewrap failed"
      else
        "$DATA/img4lib/img4" -A -F \
          -o "$SEPFW_OUT" \
          -i "$DATA/sep-firmware.n104.RELEASE" \
          -M "$DATA/sep_root_ticket.der" \
          -T rsep \
          || warn "img4 rewrap failed (no -V)"
      fi
    else
      warn "could not parse SEP IV/Key from $KEYS_URL — prepare SEP manually (see README)"
    fi
  else
    warn "img4 binary missing — SEP firmware not prepared"
  fi
fi

# ---------- 8. write run.env + READY marker ----------
ENVFILE="$DATA/run.env"
log "writing $ENVFILE"
cat > "$ENVFILE" <<EOF
# Auto-generated by download-and-configure.sh — sourced by run-t8030.sh
DATA=$DATA
RESTORE=$RESTORE
KERNEL=${KERNEL:-}
DTB=${DTB:-}
TRUSTCACHE=${TRUSTCACHE:-}
TICKET=$DATA/root_ticket.der
SEPFW=${SEPFW_OUT}
SEPROM=$DATA/AppleSEPROM-Cebu-B1
RAMDISK=${RAMDISK:-}
IPSW=$IPSW
IPSW_URL=$IPSW_URL
EOF

READY="$DATA/READY"
{
  echo "configured=$(date -Iseconds 2>/dev/null || date)"
  echo "ipsw=$IPSW_NAME"
  echo "ipsw_size=$IPSW_SIZE"
  echo "ipsw_url=$IPSW_URL"
  echo "kernel=${KERNEL:-MISSING}"
  echo "dtb=${DTB:-MISSING}"
  echo "trustcache=${TRUSTCACHE:-MISSING}"
  echo "ticket=$DATA/root_ticket.der"
  echo "seprom=$DATA/AppleSEPROM-Cebu-B1"
  if [ -f "$SEPFW_OUT" ]; then echo "sepfw=$SEPFW_OUT"; else echo "sepfw=MISSING — see NEXT_STEPS.txt"; fi
} > "$READY"

cat > "$DATA/NEXT_STEPS.txt" <<EOF
Inferno data dir: $DATA

Boot with the app's "Boot iOS (t8030)" button, or inside the chroot:
  cd $DATA && bash /root/run-t8030.sh

Display is a VNC server on 127.0.0.1:5900 — connect with a VNC viewer on the phone.

If sep-firmware…new.img4 is MISSING:
  1. Build img4lib (https://github.com/xerub/img4lib)
  2. Look up IV+Key for sep-firmware.n104.RELEASE.im4p on
     $KEYS_URL
  3. Follow https://chefkiss.dev/guides/inferno/file-setup/

A full restore still needs the companion VM + idevicerestore (upstream guide).
First boot without a prior restore may not reach SpringBoard; that is expected.
EOF

# ---------- 9. jailbreak bootstrap (stage + apply when possible) ----------
JBPREP="$(dirname "$0")/jailbreak-prep.sh"
if [ "${SKIP_JAILBREAK:-0}" = "1" ]; then
  warn "SKIP_JAILBREAK=1 - not staging the jailbreak bootstrap"
elif [ -f "$JBPREP" ]; then
  log "staging jailbreak bootstrap (checkra1n strap + launchd patch) - see jailbreak-prep.sh"
  DATA="$DATA" bash "$JBPREP" stage || warn "jailbreak staging hit an error (non-fatal); re-run: bash /root/jailbreak-prep.sh"
  if [ -f "$DATA/JAILBREAK_APPLIED" ]; then
    echo "jailbreak=applied $(cat "$DATA/JAILBREAK_APPLIED")" >> "$READY"
  else
    echo "jailbreak=staged (needs restored root disk + APFS write; see NEXT_STEPS.txt)" >> "$READY"
  fi
fi
cat >> "$DATA/NEXT_STEPS.txt" <<EOF

Jailbreak:
  Inferno already patches AMFI / code signing in the kernel on every boot.
  The userland bootstrap (bash, apt, ...) + root shell on the serial console is
  staged in $DATA/jailbreak. It is written onto the iOS System volume AFTER the
  guest has been restored (companion VM + idevicerestore):
    - phone kernel with an APFS rw driver: re-run  bash /root/jailbreak-prep.sh
    - otherwise on a Mac: sudo $DATA/jailbreak/apply-on-mac.sh /path/to/root
      then copy root back and  touch $DATA/JAILBREAK_APPLIED
  run-t8030.sh then adds launchd_unsecure_cache=1 automatically.
  palera1n/checkra1n themselves cannot run in the emulator (no SecureROM/iBoot).
EOF

log "DONE. Status:"
cat "$READY"
echo
if [ -f "$SEPFW_OUT" ] && [ -f "$DATA/root_ticket.der" ] && [ -n "${KERNEL:-}" ]; then
  log "Ready to boot. Use the Boot button (or ./run-t8030.sh)."
  exit 0
else
  warn "Configured with gaps — read $DATA/NEXT_STEPS.txt"
  exit 0
fi
