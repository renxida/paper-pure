#!/usr/bin/env python3
"""Look at pixels in a PNG (stdlib only), for screenshot checks.
  pixels.py PNG X,Y [X,Y ...] [--scale S] [--radius R]
Prints one gray level (0 black .. 255 white) per point: the darkest pixel
within R of (X*S, Y*S). Points are device coordinates; --scale is the
screenshot's scale (0.5 for `ppemu screenshot --scale 0.5`)."""
import argparse, struct, zlib


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
        if f:
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
    gray = (lambda r, x: r[x * bpp]) if ctype in (0, 4) else (lambda r, x: sum(r[x * bpp:x * bpp + 3]) // 3)
    return w, h, lambda x, y: gray(rows[y], x)


ap = argparse.ArgumentParser()
ap.add_argument('png'); ap.add_argument('points', nargs='+')
ap.add_argument('--scale', type=float, default=1.0)
ap.add_argument('--radius', type=int, default=0)
o = ap.parse_args()
w, h, px = read_png(o.png)
out = []
for p in o.points:
    x, y = (round(int(v) * o.scale) for v in p.split(','))
    r = o.radius
    out.append(str(min(px(i, j) for i in range(max(0, x - r), min(w, x + r + 1))
                       for j in range(max(0, y - r), min(h, y + r + 1)))))
print(' '.join(out))
