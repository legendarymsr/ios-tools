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
KEYS_TITLE="${KEYS_TITLE:-Keys:AzulSeed_18A5351d_(iPhone12,1)}"
KEYS_URL="${KEYS_URL:-https://theapplewiki.com/wiki/$KEYS_TITLE}"
# SEP IV/Key override: SEP_IVKEY=<iv><key> or $DATA/sep_ivkey.txt (never committed)
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

# ---------- download helper (resume, size-aware) ----------
remote_size() {
  # Content-Length of the final (post-redirect) response, empty if unknown
  curl -sIL -A "$UA" "$1" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1)=="content-length:"{n=$2} END{print n}'
}
remote_ranges() {
  curl -sIL -A "$UA" "$1" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1)=="accept-ranges:"{r=tolower($2)} END{print r}'
}
fsize() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

fetch() {
  # fetch URL DEST [expected_size]
  local url="$1" dest="$2" expect="${3:-}" rsize ranges have attempt
  rsize=$(remote_size "$url")
  if [ -n "$rsize" ] && [ "$rsize" != "0" ]; then
    if [ -n "$expect" ] && [ "$rsize" != "$expect" ]; then
      warn "server size $rsize differs from expected $expect; trusting server"
    fi
    expect="$rsize"
  fi
  ranges=$(remote_ranges "$url")
  for attempt in 1 2; do
    have=$(fsize "$dest")
    if [ -n "$expect" ] && [ "$have" = "$expect" ]; then
      log "already have $dest ($have bytes), skipping download"
      return 0
    fi
    if [ -n "$expect" ] && [ "$have" -gt "$expect" ]; then
      warn "$dest is larger than the server file ($have > $expect), deleting"
      rm -f "$dest"; have=0
    fi
    if [ "$have" -gt 0 ] && [ "$ranges" != "bytes" ]; then
      warn "server does not advertise byte ranges, restarting from zero"
      rm -f "$dest"; have=0
    fi
    log "downloading $url"
    log "         -> $dest ($have / ${expect:-?} bytes present)"
    local resume=()
    [ "$have" -gt 0 ] && resume=(-C -)
    # no --retry here: curl's retry with -C - can re-request past EOF (416)
    if curl -L --fail -A "$UA" --progress-bar "${resume[@]}" -o "$dest" "$url"; then
      have=$(fsize "$dest")
      if [ -z "$expect" ] || [ "$have" = "$expect" ]; then
        log "verified size $have"
        return 0
      fi
      warn "size mismatch: got $have, expected $expect"
    else
      local rc=$?
      have=$(fsize "$dest")
      if [ -n "$expect" ] && [ "$have" = "$expect" ]; then
        log "curl exited $rc but file is complete ($have bytes)"
        return 0
      fi
      warn "curl exited $rc with $have bytes"
      # 22 = HTTP error (e.g. 416): partial file is unusable for resume
      [ "$rc" = "22" ] && rm -f "$dest"
    fi
    [ "$attempt" = 1 ] && { [ -n "$expect" ] && [ "$(fsize "$dest")" -gt "$expect" ] && rm -f "$dest"; log "retrying once"; }
  done
  die "download failed: $url"
}

ipsw_ok() {
  # IPSW is a zip: check the central directory and that BuildManifest.plist is listed
  unzip -l "$1" 2>/dev/null | grep -q 'BuildManifest.plist'
}

# ---------- 1. IPSW from Apple ----------
IPSW="$DATA/$IPSW_NAME"
if [ "${SKIP_IPSW_DOWNLOAD:-0}" != "1" ]; then
  fetch "$IPSW_URL" "$IPSW" "$IPSW_SIZE"
  if ! ipsw_ok "$IPSW"; then
    warn "IPSW zip directory is unreadable (corrupt download), redownloading once"
    rm -f "$IPSW"
    fetch "$IPSW_URL" "$IPSW" "$IPSW_SIZE"
    ipsw_ok "$IPSW" || die "IPSW still corrupt after redownload: $IPSW"
  fi
  log "IPSW zip structure OK"
else
  [ -f "$IPSW" ] || die "SKIP_IPSW_DOWNLOAD set but $IPSW missing"
  ipsw_ok "$IPSW" || die "IPSW at $IPSW is not a valid zip"
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

# Drop the extracted copy of the largest .dmg (main OS image): the restore step
# (restore-ios.sh) streams it straight from the .ipsw, which is kept.
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
CHECK_SEP="$(dirname "$0")/check-sep.py"
if [ -f "$CHECK_SEP" ] && ! python3 "$CHECK_SEP" rom "$DATA/AppleSEPROM-Cebu-B1"; then
  warn "the SEP ROM is not the Cebu B1 dump - downloading it again"
  rm -f "$DATA/AppleSEPROM-Cebu-B1"
  fetch "$SEPROM_URL" "$DATA/AppleSEPROM-Cebu-B1" "$SEPROM_SIZE"
  python3 "$CHECK_SEP" rom "$DATA/AppleSEPROM-Cebu-B1" \
    || die "the SEP ROM from $SEPROM_URL is not the Cebu B1 dump; put the right AppleSEPROM-Cebu-B1 in $DATA (or set SEPROM_SHA256=) and re-run step 4"
fi

# ---------- 5. python deps + forge AP ticket ----------
log "ensuring pyasn1 is available"
# bookworm's pip refuses --user installs (PEP 668), so prefer apt.
python3 -c 'import pyasn1, pyasn1_modules' 2>/dev/null \
  || apt-get install -y python3-pyasn1 python3-pyasn1-modules >/dev/null 2>&1 \
  || pip3 install --break-system-packages -q pyasn1 pyasn1-modules 2>/dev/null \
  || warn "could not install pyasn1 - apticket step may fail"
python3 -c 'import pyasn1, pyasn1_modules' 2>/dev/null || die "python3 pyasn1/pyasn1-modules missing (apt-get install python3-pyasn1 python3-pyasn1-modules)"

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
# Paths come from BuildManifest.plist (n104ap, Erase identity) instead of
# filename guessing. The guide boots with the Erase restore ramdisk and its
# matching trustcache (038-44135-124.dmg[.trustcache] on 18A5351d).
RESTORE="$DATA/Restore"
KERNEL=""; DTB=""; TRUSTCACHE=""; RAMDISK=""; SEPFW_IM4P=""
eval "$(python3 - "$RESTORE" <<'PY'
import plistlib, os, sys, shlex
r = sys.argv[1]
out = {}
try:
    bm = plistlib.load(open(os.path.join(r, 'BuildManifest.plist'), 'rb'))
    ids = [b for b in bm.get('BuildIdentities', [])
           if b.get('Info', {}).get('DeviceClass', '').lower() == 'n104ap']
    erase = [b for b in ids if b['Info'].get('RestoreBehavior') == 'Erase'] or ids
    m = erase[0]['Manifest'] if erase else {}
    def p(k):
        v = m.get(k, {}).get('Info', {}).get('Path', '')
        return os.path.join(r, v) if v else ''
    out['RAMDISK'] = p('RestoreRamDisk')
    out['TRUSTCACHE'] = p('RestoreTrustCache')
    out['DTB'] = p('DeviceTree')
    out['SEPFW_IM4P'] = p('SEP')
    kc = p('KernelCache')
    rk = kc.replace('kernelcache.release.', 'kernelcache.research.') if kc else ''
    out['KERNEL'] = rk
except Exception as e:
    print('echo "[!] BuildManifest parse failed: %s" >&2' % str(e).replace('"', '').replace('$', ''))
for k, v in out.items():
    if v and os.path.exists(v):
        print('%s=%s' % (k, shlex.quote(v)))
PY
)" || true
# Fallbacks (guide filenames / globbing)
[ -n "$KERNEL" ]     || KERNEL=$(ls "$RESTORE"/kernelcache.research.* 2>/dev/null | head -1 || true)
[ -n "$DTB" ]        || DTB=$(ls "$RESTORE"/Firmware/all_flash/DeviceTree.n104ap.im4p 2>/dev/null | head -1 || true)
if [ -z "$RAMDISK" ]; then
  # Erase ramdisk = the smallest .dmg (ChefKiss guide: smaller of the two smallest)
  RAMDISK=$(find "$RESTORE" -maxdepth 1 -type f -name '*.dmg' -printf '%s %p\n' 2>/dev/null | sort -n | head -1 | awk '{print $2}')
fi
if [ -z "$TRUSTCACHE" ] && [ -n "$RAMDISK" ] && [ -f "$RESTORE/Firmware/$(basename "$RAMDISK").trustcache" ]; then
  TRUSTCACHE="$RESTORE/Firmware/$(basename "$RAMDISK").trustcache"
fi
[ -n "$SEPFW_IM4P" ] || SEPFW_IM4P=$(ls "$RESTORE"/Firmware/all_flash/sep-firmware.n104.RELEASE.im4p 2>/dev/null | head -1 || true)

log "kernel:     ${KERNEL:-MISSING}"
log "devicetree: ${DTB:-MISSING}"
log "ramdisk:    ${RAMDISK:-MISSING}"
log "trustcache: ${TRUSTCACHE:-MISSING}"
log "sep im4p:   ${SEPFW_IM4P:-MISSING}"

# ---------- 7. SEP firmware decrypt + rewrap (img4lib) ----------
SEPFW_OUT="$DATA/sep-firmware.n104.RELEASE.new.img4"
BUA="Mozilla/5.0 (Linux; Android 14; SM-F721B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Mobile Safari/537.36"

build_img4lib() {
  [ -x "$DATA/img4lib/img4" ] && return 0
  need_cmd git; need_cmd make; need_cmd gcc
  rm -rf "$DATA/img4lib"
  local i
  for i in 1 2 3; do
    git -c http.version=HTTP/1.1 clone --depth 1 "$IMG4LIB_REPO" "$DATA/img4lib" && break
    rm -rf "$DATA/img4lib"; sleep $((i*3))
  done
  if [ ! -d "$DATA/img4lib" ]; then
    warn "git clone of img4lib failed, trying the GitHub tarball"
    mkdir -p "$DATA/img4lib"
    curl -fL --retry 3 "https://codeload.github.com/xerub/img4lib/tar.gz/refs/heads/master" \
      | tar -xz -C "$DATA/img4lib" --strip-components=1 || { rm -rf "$DATA/img4lib"; return 1; }
  fi
  # lzfse from step 2 (/usr/local), OpenSSL from libssl-dev
  make -C "$DATA/img4lib" \
    LDFLAGS="-L/usr/local/lib -Wl,-rpath,/usr/local/lib" \
    CFLAGS='-I/usr/local/include -Wall -W -pedantic -Wno-variadic-macros -Wno-multichar -Wno-four-char-constants -Wno-unused-parameter -O2 -I. -g -D__LITTLE_ENDIAN__=1 -DiOS10 -DDER_MULTIBYTE_TAGS=1 -DDER_TAG_SIZE=8 -D__unused="__attribute__((unused))"' \
    || return 1
  [ -x "$DATA/img4lib/img4" ]
}

# Print the SEP firmware IV+Key (hex) on stdout, or fail. Order: SEP_IVKEY
# env, $DATA/sep_ivkey.txt (pasted by you), then The Apple Wiki's raw
# wikitext, its API, and the rendered page, each via curl with browser headers
# and via Python urllib (different TLS stack), because some networks get a 403
# from the wiki for one client and not the other. Nothing is written to disk.
get_sep_ivkey() {
  if [ -n "${SEP_IVKEY:-}" ]; then echo "$SEP_IVKEY"; return 0; fi
  if [ -s "$DATA/sep_ivkey.txt" ]; then tr -dc '0-9a-fA-F' < "$DATA/sep_ivkey.txt"; echo; return 0; fi
  KEYS_TITLE="$KEYS_TITLE" BUA="$BUA" python3 - <<'PY'
import os, re, subprocess, sys, json, urllib.request, urllib.parse
t = os.environ['KEYS_TITLE']; ua = os.environ['BUA']
q = urllib.parse.quote(t, safe=':_(),')
urls = [
  'https://theapplewiki.com/index.php?title=%s&action=raw' % q,
  'https://theapplewiki.com/api.php?action=parse&page=%s&prop=wikitext&format=json&formatversion=2' % q,
  'https://theapplewiki.com/wiki/%s' % q,
  'https://www.theiphonewiki.com/wiki/%s?action=raw' % q,
]
hdr = {'User-Agent': ua,
       'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7',
       'Accept-Language': 'en-US,en;q=0.9'}
def parse(txt):
    if txt.lstrip().startswith('{'):
        try: txt = json.loads(txt)['parse']['wikitext']
        except Exception: pass
    iv = re.search(r'id="keypage-sepfirmware-iv"[^>]*>\s*([0-9a-fA-F]{32})\s*<', txt) \
      or re.search(r'\|\s*SEPFirmwareIV\s*=\s*([0-9a-fA-F]{32})\b', txt)
    key = re.search(r'id="keypage-sepfirmware-key"[^>]*>\s*([0-9a-fA-F]{64})\s*<', txt) \
      or re.search(r'\|\s*SEPFirmwareKey\s*=\s*([0-9a-fA-F]{64})\b', txt)
    return (iv.group(1) + key.group(1)).lower() if iv and key else None
def via_curl(u):
    a = ['curl', '-fsSL', '--compressed', '-m', '40', '--retry', '2']
    for k, v in hdr.items(): a += ['-H', '%s: %s' % (k, v)]
    r = subprocess.run(a + [u], capture_output=True, text=True, errors='replace')
    if r.returncode: raise RuntimeError('curl exit %d %s' % (r.returncode, r.stderr.strip()[:80]))
    return r.stdout
def via_urllib(u):
    with urllib.request.urlopen(urllib.request.Request(u, headers=hdr), timeout=40) as f:
        return f.read().decode('utf-8', 'replace')
for u in urls:
    for name, fn in (('curl', via_curl), ('python', via_urllib)):
        try:
            v = parse(fn(u))
            if v:
                print('[*] SEP IV/Key found via %s: %s' % (name, u.split('?')[0]), file=sys.stderr)
                print(v); sys.exit(0)
            print('[!] %s %s: fetched, but no SEP IV/Key in it' % (name, u[:80]), file=sys.stderr)
        except Exception as e:
            print('[!] %s %s: %s' % (name, u[:80], str(e)[:100]), file=sys.stderr)
sys.exit(1)
PY
}

if [ "${SKIP_SEP:-0}" = "1" ]; then
  warn "SKIP_SEP=1 - not preparing $SEPFW_OUT"
elif [ -s "$SEPFW_OUT" ] && { [ ! -f "$CHECK_SEP" ] || python3 "$CHECK_SEP" fw "$SEPFW_OUT" "$SEPFW_IM4P"; }; then
  log "SEP firmware already prepared and checked: $SEPFW_OUT"
elif [ ! -f "$CHECK_SEP" ]; then
  warn "check-sep.py is missing next to $0 - cannot prepare the SEP firmware (reinstall the module)"
elif [ -z "$SEPFW_IM4P" ] || [ ! -f "$DATA/sep_root_ticket.der" ]; then
  warn "missing SEP im4p or sep_root_ticket.der - skipping SEP prep"
else
  if [ -s "$SEPFW_OUT" ]; then
    warn "the existing $SEPFW_OUT is bad (reason above) - moving it to .bad and rebuilding it"
    mv -f "$SEPFW_OUT" "$SEPFW_OUT.bad"
  fi
  log "building img4lib (xerub) for SEP firmware rewrap"
  if ! build_img4lib; then
    warn "img4lib build failed - SEP firmware not prepared (see errors above, then re-run step 4)"
  else
    log "fetching SEP IV+Key for 18A5351d / iPhone12,1 from The Apple Wiki (kept in memory only)"
    IVKEY=$(get_sep_ivkey || true)
    if ! printf '%s' "${IVKEY:-}" | grep -qE '^[0-9a-fA-F]{96}$'; then
      warn "could not get the SEP IV+Key automatically."
      warn "Open $KEYS_URL in a browser, copy the SEPFirmware IV then Key"
      warn "(no spaces) into /data/local/debian/root/InfernoData/sep_ivkey.txt and re-run step 4."
      warn "Everything already done is skipped on the re-run."
    else
      rm -f "$DATA/sep-firmware.n104.RELEASE"
      # ChefKiss guide: stdout of the decrypt command IS the -V version string
      SEP_VER=$("$DATA/img4lib/img4" -v -i "$SEPFW_IM4P" -o "$DATA/sep-firmware.n104.RELEASE" -k "$IVKEY" 2>/dev/null | tail -n1 | tr -d '\r' || true)
      unset IVKEY
      if [ ! -s "$DATA/sep-firmware.n104.RELEASE" ]; then
        warn "img4 decrypt produced no output - wrong IV/Key? (fix or delete sep_ivkey.txt)"
      elif [ -f "$CHECK_SEP" ] && ! python3 "$CHECK_SEP" dec "$DATA/sep-firmware.n104.RELEASE"; then
        rm -f "$DATA/sep-firmware.n104.RELEASE"
        if [ -n "${SEP_IVKEY:-}" ]; then KSRC="SEP_IVKEY"; elif [ -s "$DATA/sep_ivkey.txt" ]; then KSRC="$DATA/sep_ivkey.txt"; else KSRC=""; fi
        if [ -n "$KSRC" ]; then
          die "the SEP IV/Key from $KSRC is wrong for 18A5351d / iPhone12,1 (the SEPFirmware IV then Key from $KEYS_URL); fix or delete it and re-run step 4"
        fi
        die "the SEP IV/Key from The Apple Wiki did not decrypt the SEP firmware; put the SEPFirmware IV then Key from $KEYS_URL into $DATA/sep_ivkey.txt and re-run step 4"
      else
        # Rewrap in Python, not with "img4 -A -T rsep": img4lib only byte-swaps
        # the fourcc when __LITTLE_ENDIAN__/__x86_64__ is defined, so its GCC
        # build on arm64 writes the type as 'pesr'. The version string is taken
        # straight from the IPSW's IM4P (same bytes the guide's -V passes).
        [ -n "$SEP_VER" ] || warn "img4 -v printed no version string (not needed: it is read from the im4p)"
        log "rewrapping SEP firmware -> $SEPFW_OUT"
        python3 "$CHECK_SEP" wrap "$SEPFW_IM4P" "$DATA/sep-firmware.n104.RELEASE" \
          "$DATA/sep_root_ticket.der" "$SEPFW_OUT" \
          || { rm -f "$SEPFW_OUT"; die "could not rewrap the SEP firmware (reason above)"; }
        if ! python3 "$CHECK_SEP" fw "$SEPFW_OUT" "$SEPFW_IM4P"; then
          mv -f "$SEPFW_OUT" "$SEPFW_OUT.bad"
          die "the rewrapped SEP firmware failed the check above (kept as $SEPFW_OUT.bad)"
        fi
      fi
    fi
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

Next: the app's "5. Restore iOS (automatic)" button restores the IPSW onto the
blank disk (inside the chroot: DATA=$DATA bash /root/restore-ios.sh). Then boot
with "6. Boot iOS (t8030)", or inside the chroot:
  cd $DATA && bash /root/run-t8030.sh

Display is a VNC server on 127.0.0.1:5900 — connect with a VNC viewer on the phone.

If sep-firmware…new.img4 is MISSING:
  1. Build img4lib (https://github.com/xerub/img4lib)
  2. Look up IV+Key for sep-firmware.n104.RELEASE.im4p on
     $KEYS_URL
  3. Follow https://chefkiss.dev/guides/inferno/file-setup/

Keep the downloaded .ipsw: the restore step streams the OS image from it.
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
  guest has been restored (step 5):
    - app step "8. Jailbreak bootstrap": writes it with linux-apfs-rw inside the
      small USB-host VM from step 5 (or the phone kernel's APFS driver, if any)
    - or on a Mac: sudo $DATA/jailbreak/apply-on-mac.sh /path/to/root
      then copy root back and  touch $DATA/JAILBREAK_APPLIED
  run-t8030.sh then adds launchd_unsecure_cache=1 automatically.
  palera1n/checkra1n themselves cannot run in the emulator (no SecureROM/iBoot).
EOF

log "DONE. Status:"
cat "$READY"
echo
if [ -f "$SEPFW_OUT" ] && [ -f "$DATA/root_ticket.der" ] && [ -n "${KERNEL:-}" ]; then
  log "Configured. Next: step 5 'Restore iOS (automatic)', then Boot."
  exit 0
else
  warn "Configured with gaps — read $DATA/NEXT_STEPS.txt"
  exit 0
fi
