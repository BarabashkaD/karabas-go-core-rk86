"""Snapped VGA frames of the system TB (simout/snaps.txt of frame_capture.v).

snaps.txt: "SNAP <name> <frame> <start cycle>", then "<line> <x> <rgb hex>" on the first sample of the
frame and on every change (line: rising edges of HS since the rising edge of VS; x: samples since the
last rising edge of HS), then "END <frame> <cycles> <lines> <hash>".

Pin coordinates (line, x) -> the counters of hvsync_generator.v (Go, plan F21, corrected: a line is
1057 clocks, a frame 629 lines): VGA_HS and VGA_VS are registered one clock after the counters, so HS
rises at CounterX = 841 (800 + 40 + 1) and VS at CounterY = 601, CounterX = 1. A sample at x >= 216 of
line y has CounterX = x - 216 and CounterY = (601 + y) mod 629; the visible area (CounterX < 800,
CounterY < 600) is x = 216..1015 of the lines y = 28..627.

Usage: python -B frames.py <snaps.txt> [--ppm <dir>]  (lists the snaps; --ppm writes <name>.ppm of the
visible area)
"""
import argparse
import os
import sys

H_TOTAL, V_TOTAL = 1057, 629
VIS_W, VIS_H = 800, 600
HS_X, VS_Y = 841, 601          # CounterX at the HS rise; CounterY of the VS rise
X0 = H_TOTAL - HS_X             # 216: x of CounterX = 0
Y0 = V_TOTAL - VS_Y             # 28: line of CounterY = 0


class Snap(object):
    def __init__(self, name, frame, start):
        self.name, self.frame, self.start = name, frame, start
        self.recs = []          # (line, x, rgb text)
        self.end = None         # (frame, cycles, lines, hash)

    def pin_lines(self):
        """{line: [rgb text or None] * H_TOTAL}: the value of every sample of the frame."""
        out = {}
        recs = self.recs
        if not recs:
            return out
        cur = None
        k = 0
        last_line = self.end[2] if self.end else recs[-1][0]
        for y in range(recs[0][0], last_line + 1):
            row = [None] * H_TOTAL
            for x in range(H_TOTAL):
                while k < len(recs) and (recs[k][0], recs[k][1]) <= (y, x):
                    cur = recs[k][2]
                    k += 1
                if (y, x) >= (recs[0][0], recs[0][1]):
                    row[x] = cur
            out[y] = row
        return out

    def visible(self):
        """[CounterY][CounterX] rgb text of the visible area 800 x 600."""
        pl = self.pin_lines()
        img = []
        for cy in range(VIS_H):
            y = cy + Y0
            row = pl.get(y)
            if row is None:
                raise ValueError('snap %s: line %d (CounterY %d) not captured' % (self.name, y, cy))
            img.append(row[X0:X0 + VIS_W])
        return img


def read_snaps(path):
    snaps = {}
    order = []
    cur = None
    with open(path) as f:
        for ln in f:
            p = ln.split()
            if not p:
                continue
            if p[0] == 'SNAP':
                cur = Snap(p[1], int(p[2]), int(p[3]))
                snaps[cur.name] = cur
                order.append(cur.name)
            elif p[0] == 'END':
                if cur is None:
                    raise ValueError('%s: END without SNAP' % path)
                cur.end = (int(p[1]), int(p[2]), int(p[3]), p[4])
                cur = None
            else:
                if cur is None:
                    raise ValueError('%s: pixel line outside a snap: %s' % (path, ln.strip()))
                cur.recs.append((int(p[0]), int(p[1]), p[2].lower()))
    return snaps, order


def write_ppm(path, img, colour=None):
    """img: rows of rgb text (6 hex digits) or None; X/Z digits and None are written magenta."""
    h, w = len(img), len(img[0])
    with open(path, 'wb') as f:
        f.write(b'P6\n%d %d\n255\n' % (w, h))
        for row in img:
            b = bytearray()
            for v in row:
                if colour is not None:
                    b += bytes(colour(v))
                elif v is None or any(c not in '0123456789abcdef' for c in v):
                    b += b'\xff\x00\xff'
                else:
                    b += bytes((int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16)))
            f.write(bytes(b))


def main():
    ap = argparse.ArgumentParser(description='List / convert the snapped frames of snaps.txt')
    ap.add_argument('snaps')
    ap.add_argument('--ppm', help='directory for <name>.ppm of the visible area')
    a = ap.parse_args()
    snaps, order = read_snaps(a.snaps)
    for n in order:
        s = snaps[n]
        print('SNAP %s frame %d start %d: %d changes, end %s' % (n, s.frame, s.start, len(s.recs), s.end))
        if a.ppm:
            os.makedirs(a.ppm, exist_ok=True)
            write_ppm(os.path.join(a.ppm, n + '.ppm'), s.visible())
    return 0


if __name__ == '__main__':
    sys.exit(main())
