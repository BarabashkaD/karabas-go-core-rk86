"""Text of the RK86 screen buffer from a RAM dump of the system TB (plan Task 4 Step 5).

Usage: python -B screen.py <ram.hex> [--bios BIOS.BIN] [--ascii] [--rows a-b]
The screen base and width come from the BIOS bytes and are checked against the stock values: the CRT
setup (FACF: LXI H,C001 / MVI M,00 / DCX H / MVI M,<p0..p3>) gives 78 characters (p0 & 7Fh + 1) and
30 rows (p1 & 3Fh + 1); the DMA channel 2 setup (MVI L,04 / MVI M,<lo> / MVI M,<hi> / INR L /
MVI M,<count lo> / MVI M,<count hi>) gives the base 76D0h and 2340 bytes (count & 3FFFh + 1) = 78 x 30.
A mismatch is an error (exit status 1). The screen is printed in KOI-7 (60h-7Fh Cyrillic; --ascii keeps
the Latin letters; 00h-1Fh '.', 80h-FFh '^'), one line per row, with the cursor of the monitor ([7602h]
column, [7603h] row) and the address of the cursor ([7600h]).
"""
import argparse
import os
import sys

KOI7_CYR = (u'\u044e\u0430\u0431\u0446\u0434\u0435\u0444\u0433\u0445\u0438\u0439\u043a\u043b\u043c\u043d\u043e'
            u'\u043f\u044f\u0440\u0441\u0442\u0443\u0436\u0432\u044c\u044b\u0437\u0448\u044d\u0449\u0447\u25a0')


def find(b, pat):
    """Offset of the byte pattern pat (None = any byte) in b, or -1."""
    for i in range(len(b) - len(pat) + 1):
        if all(p is None or b[i + j] == p for j, p in enumerate(pat)):
            return i
    return -1


def bios_screen(bios):
    """(columns, rows, base, dma bytes) from the BIOS setup code."""
    i = find(bios, [0x21, 0x01, 0xC0, 0x36, 0x00, 0x2B, 0x36, None, 0x36, None, 0x36, None, 0x36, None])
    if i < 0:
        raise ValueError('the CRT setup (LXI H,C001 / MVI M,00 / DCX H / MVI M,..) is not in the BIOS')
    cols, rows = (bios[i + 7] & 0x7F) + 1, (bios[i + 9] & 0x3F) + 1
    j = find(bios, [0x2E, 0x04, 0x36, None, 0x36, None, 0x2C, 0x36, None, 0x36, None])
    if j < 0:
        raise ValueError('the DMA channel 2 setup (MVI L,04 / MVI M,.. x2 / INR L / MVI M,.. x2) is not in the BIOS')
    base = bios[j + 3] | (bios[j + 5] << 8)
    count = ((bios[j + 8] | (bios[j + 10] << 8)) & 0x3FFF) + 1
    return cols, rows, base, count


def char(c, ascii_only):
    if c >= 0x80:
        return '^'          # attribute and special codes
    if c < 0x20:
        return '.'
    if c >= 0x60 and not ascii_only:
        return KOI7_CYR[c - 0x60]
    return chr(c)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description='Text of the RK86 screen buffer')
    ap.add_argument('ram')
    ap.add_argument('--bios', default=os.path.join(here, '..', '..', '..', 'roms', 'BIOS.BIN'))
    ap.add_argument('--ascii', action='store_true')
    ap.add_argument('--rows', help='a-b: only these rows')
    a = ap.parse_args()
    with open(a.bios, 'rb') as f:
        bios = bytearray(f.read())
    ram = bytearray()
    with open(a.ram) as f:
        for ln in f:
            s = ln.strip()
            if s:
                ram.append(int(s, 16) if all(c in '0123456789abcdefABCDEF' for c in s) else 0x3F)
    cols, rows, base, count = bios_screen(bios)
    ok = (cols, rows, base, count) == (78, 30, 0x76D0, 78 * 30) and count == cols * rows
    print('screen buffer: base %04X, %d columns x %d rows, DMA %d bytes per frame (%s)'
          % (base, cols, rows, count, 'stock values' if ok else 'ERROR: expected 76D0, 78 x 30, 2340'))
    print('cursor: column %d row %d, address %04X' % (ram[0x7602], ram[0x7603], ram[0x7600] | (ram[0x7601] << 8)))
    r0, r1 = 0, rows - 1
    if a.rows:
        r0, r1 = [int(x) for x in a.rows.split('-')]
    sys.stdout.flush()
    out = getattr(sys.stdout, 'buffer', None)
    for r in range(r0, r1 + 1):
        line = '%2d %04X |%s|' % (r, base + r * cols,
                                  ''.join(char(ram[base + r * cols + c], a.ascii) for c in range(cols)))
        if out is not None:
            out.write((line + '\n').encode('utf-8'))
        else:
            print(line)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
