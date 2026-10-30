#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sanity checks for the SEP inputs of an Inferno t8030 boot.
#   check-sep.py rom  AppleSEPROM-Cebu-B1
#   check-sep.py dec  sep-firmware.n104.RELEASE            (decrypted payload)
#   check-sep.py fw   sep-firmware.n104.RELEASE.new.img4 [original .im4p]
#   check-sep.py wrap ORIG.im4p DECRYPTED sep_root_ticket.der OUT.img4
#     builds the IMG4 the ChefKiss guide makes with "img4 -A -F ... -T rsep -V
#     <img4 -v output>", but in Python: xerub's img4lib only byte-swaps the
#     fourcc when __LITTLE_ENDIAN__/__x86_64__ is defined, so a GCC build on
#     arm64 Linux writes the type as 'pesr' instead of 'rsep'.
# Exit 0 = looks right, 1 = bad (reason on stderr). A bad SEP ROM or SEP
# firmware makes the restore ramdisk panic in the SEP DART (ChefKiss FAQ:
# "dart-sep ... DART(DART) error" = "User error; bad SEP ROM or SEP Firmware";
# with a slow SEP boot it shows up as "t8020dart invalid lock state" after
# "Id(dart-sep) AppleT8020DART::_interruptHandler: DART interrupt while disabled").
import hashlib, os, sys

SEPROM_SIZE = 86016
SEPROM_SHA256 = os.environ.get('SEPROM_SHA256',
    'e3b11f624e3382a203c1f781b889b407554668936c86b0e2d41d229976317a1b')
SEPOS_MARKERS = (b'Built by legion', b'AppleSEPOS-', b'SEPOS/')


def bad(msg):
    print('[ERROR] ' + msg, file=sys.stderr)
    sys.exit(1)


def tlv(b, p):
    """DER: return (tag, start_of_value, end_of_value)."""
    if p + 2 > len(b):
        raise ValueError('truncated DER')
    t = b[p]; l = b[p + 1]; p += 2
    if l & 0x80:
        n = l & 0x7f
        l = int.from_bytes(b[p:p + n], 'big'); p += n
    if p + l > len(b):
        raise ValueError('truncated DER')
    return t, p, p + l


def children(b, s, e):
    out = []
    while s < e:
        t, vs, ve = tlv(b, s)
        out.append((t, s, vs, ve))
        s = ve
    return out


def is_sepos(data):
    return sum(m in data for m in SEPOS_MARKERS) >= 2


def check_rom(path):
    d = open(path, 'rb').read()
    if len(d) != SEPROM_SIZE:
        bad('%s is %d bytes, expected %d (Cebu B1 SEP ROM)' % (path, len(d), SEPROM_SIZE))
    h = hashlib.sha256(d).hexdigest()
    if SEPROM_SHA256 and h != SEPROM_SHA256.lower():
        bad('%s sha256 %s is not the Cebu B1 SEP ROM (%s)' % (path, h, SEPROM_SHA256))
    print('[*] SEP ROM ok (Cebu B1, sha256 %s...)' % h[:16])


def parse_im4p(b, s, e):
    # IM4P ::= SEQ { "IM4P", type, version, payload [, kbag] }
    kids = children(b, s, e)
    if len(kids) < 4 or b[kids[0][2]:kids[0][3]] != b'IM4P':
        raise ValueError('not an IM4P')
    f = lambda i: b[kids[i][2]:kids[i][3]]
    return {'type': f(1), 'version': f(2), 'payload': f(3), 'kbag': len(kids) > 4}


def check_fw(path, orig=None):
    b = open(path, 'rb').read()
    try:
        t, vs, ve = tlv(b, 0)
        kids = children(b, vs, ve)
        if b[kids[0][2]:kids[0][3]] != b'IMG4':
            bad('%s is not an IMG4 (re-run step 4)' % path)
        _, ps, pvs, pve = kids[1]
        p = parse_im4p(b, pvs, pve)
        manifest = [k for k in kids[2:] if b[k[1]] == 0xa0]
    except (ValueError, IndexError) as ex:
        bad('%s: cannot parse (%s) - re-run step 4' % (path, ex))
    if p['type'] != b'rsep':
        bad('%s: IM4P type %r, expected rsep' % (path, p['type']))
    if p['kbag']:
        bad('%s: payload is still encrypted (keybag present)' % path)
    if not is_sepos(p['payload']):
        bad('%s: payload is not a decrypted SEPOS - wrong SEP IV/Key for this build '
            '(delete it and sep_ivkey.txt, re-run step 4)' % path)
    if not manifest:
        bad('%s: no IM4M (SEP ticket) inside - re-run step 4' % path)
    if orig and os.path.exists(orig):
        ob = open(orig, 'rb').read()
        _, ovs, ove = tlv(ob, 0)
        o = parse_im4p(ob, ovs, ove)
        if o['version'] != p['version']:
            bad('%s: IM4P version string differs from %s (the -V value must be the '
                'exact "img4 -v" output) - re-run step 4' % (path, os.path.basename(orig)))
    print('[*] SEP firmware ok (decrypted SEPOS, rsep, %d KiB, ticket attached)' %
          (len(p['payload']) // 1024))


def der(tag, value):
    n = len(value)
    if n < 0x80:
        head = bytes([n])
    else:
        nb = n.to_bytes((n.bit_length() + 7) // 8, 'big')
        head = bytes([0x80 | len(nb)]) + nb
    return bytes([tag]) + head + value


def wrap(orig, dec, ticket, out):
    ob = open(orig, 'rb').read()
    try:
        _, ovs, ove = tlv(ob, 0)
        o = parse_im4p(ob, ovs, ove)
    except (ValueError, IndexError) as ex:
        bad('%s: cannot parse the original IM4P (%s)' % (orig, ex))
    payload = open(dec, 'rb').read()
    if not is_sepos(payload):
        bad('%s is not a decrypted SEPOS - the SEP IV/Key is wrong for this build' % dec)
    m = open(ticket, 'rb').read()
    try:
        t, _, mve = tlv(m, 0)
        mk = children(m, *tlv(m, 0)[1:])
        if t != 0x30 or mve != len(m) or m[mk[0][2]:mk[0][3]] != b'IM4M':
            raise ValueError('not an IM4M')
    except (ValueError, IndexError) as ex:
        bad('%s: not a SEP ticket (%s) - delete it and re-run step 4' % (ticket, ex))
    # IMG4 ::= SEQ { "IMG4", IM4P, [0] IM4M }   IM4P ::= SEQ { "IM4P", type, version, payload }
    im4p = der(0x30, der(0x16, b'IM4P') + der(0x16, b'rsep') +
               der(0x16, o['version']) + der(0x04, payload))
    img4 = der(0x30, der(0x16, b'IMG4') + im4p + der(0xa0, m))
    tmp = out + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(img4)
    os.replace(tmp, out)
    print('[*] wrote %s (rsep, %d KiB payload, version string %d chars)' %
          (out, len(payload) // 1024, len(o['version'])))


def check_dec(path):
    d = open(path, 'rb').read()
    if not is_sepos(d):
        bad('%s is not a decrypted SEPOS - the SEP IV/Key is wrong for this build' % path)
    print('[*] decrypted SEP firmware looks right')


if __name__ == '__main__':
    if len(sys.argv) < 3 or sys.argv[1] not in ('rom', 'fw', 'dec', 'wrap'):
        print('usage: check-sep.py rom|fw|dec FILE [ORIG_IM4P] | wrap ORIG DEC TICKET OUT',
              file=sys.stderr)
        sys.exit(2)
    if sys.argv[1] == 'wrap':
        if len(sys.argv) != 6:
            bad('usage: check-sep.py wrap ORIG.im4p DECRYPTED TICKET OUT.img4')
        for f in sys.argv[2:5]:
            if not os.path.isfile(f):
                bad('missing: ' + f)
        wrap(*sys.argv[2:6])
        sys.exit(0)
    if not os.path.isfile(sys.argv[2]):
        bad('missing: ' + sys.argv[2])
    {'rom': lambda: check_rom(sys.argv[2]),
     'dec': lambda: check_dec(sys.argv[2]),
     'fw': lambda: check_fw(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)}[sys.argv[1]]()
