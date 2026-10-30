#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
import sys, struct, subprocess, os
def main():
    data = open(sys.argv[1],'rb').read() if len(sys.argv)>1 else sys.stdin.buffer.read()
    if data[:4] != b'\xed\xab\xee\xdb':
        sys.stderr.write('not rpm\n'); return 1
    o = 96
    # signature header + pad
    nindex = struct.unpack('>I', data[o+8:o+12])[0]
    hsize = struct.unpack('>I', data[o+12:o+16])[0]
    o = o + 16 + nindex*16 + hsize
    if o % 8: o += 8 - (o % 8)
    # main header, NO pad before payload
    nindex = struct.unpack('>I', data[o+8:o+12])[0]
    hsize = struct.unpack('>I', data[o+12:o+16])[0]
    o = o + 16 + nindex*16 + hsize
    payload = data[o:]
    for cmd in (['zstd','-dc'],['gzip','-dc'],['xz','-dc']):
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = p.communicate(payload)
        if p.returncode == 0 and out.startswith(b'070701'):
            sys.stdout.buffer.write(out); return 0
    sys.stderr.write('decompress failed\n'); return 1
if __name__ == '__main__':
    sys.exit(main() or 0)
