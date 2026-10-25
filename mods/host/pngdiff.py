#!/usr/bin/env python3
"""Compare two PNGs pixel by pixel (stdlib only). Exit 0 if at most
--max-diff pixels differ by more than --tol in any channel.
  pngdiff.py A.png B.png [--max-diff 0] [--tol 0]"""
import argparse, struct, sys, zlib


def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', f'{path}: not a PNG'
    pos, idat, ihdr = 8, b'', None
    while pos < len(data):
        n, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b'IHDR':
            ihdr = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
        pos += 12 + n
    w, h, depth, ctype, _, _, interlace = ihdr
    assert depth == 8 and interlace == 0, f'{path}: only 8-bit non-interlaced PNGs'
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    gray = ctype in (0, 4)
    px = lambda r, x: (r[x * bpp],) * 3 if gray else tuple(r[x * bpp:x * bpp + 3])
    return w, h, [[px(r, x) for x in range(w)] for r in rows]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a'); ap.add_argument('b')
    ap.add_argument('--max-diff', type=int, default=0)
    ap.add_argument('--tol', type=int, default=0)
    o = ap.parse_args()
    wa, ha, pa = read_png(o.a); wb, hb, pb = read_png(o.b)
    if (wa, ha) != (wb, hb):
        print(f'pngdiff: size {wa}x{ha} vs {wb}x{hb}'); return 1
    diff = sum(1 for y in range(ha) for x in range(wa)
               if max(abs(p - q) for p, q in zip(pa[y][x], pb[y][x])) > o.tol)
    print(f'pngdiff: {diff} of {wa * ha} pixels differ (allowed {o.max_diff})')
    return 0 if diff <= o.max_diff else 1


sys.exit(main())
