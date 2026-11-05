"""Text of the RK86 screen buffer from a RAM dump of the system TB (plan Task 4 Step 5).

Usage: python -B screen.py <ram.hex> [--bios BIOS.BIN] [--ascii] [--rows a-b] [--golden <snap>]
The screen base and width come from the BIOS bytes and are checked against the stock values: the CRT
setup (FACF: LXI H,C001 / MVI M,00 / DCX H / MVI M,<p0..p3>) gives 78 characters (p0 & 7Fh + 1) and
30 rows (p1 & 3Fh + 1); the DMA channel 2 setup (MVI L,04 / MVI M,<lo> / MVI M,<hi> / INR L /
MVI M,<count lo> / MVI M,<count hi>) gives the base 76D0h and 2340 bytes (count & 3FFFh + 1) = 78 x 30.
A mismatch is an error (exit status 1). The screen is printed in KOI-7 (60h-7Fh Cyrillic; --ascii keeps
the Latin letters; 00h-1Fh '.', 80h-FFh '^', a byte with X 'X'), one line per row, with the cursor of the
monitor ([7602h] column, [7603h] row) and the address of the cursor ([7600h]). Any X in the screen buffer
or the cursor variables is an error.
--golden <snap>: the expected screen of the basic chain at that picture (prompt, attr, keys, keys2), cell by
cell: row 3 the banner "radio-86rk" from column 8; row 4 the prompt "-->" (after the keys "-->D!") from
column 8; rows 28-29 empty before CP3, afterwards the bytes chain.vh pokes (20h padding, F1h at column 77);
every other cell 00h (the clear-screen code of the BIOS, FDA3: LXI H,7FF4 / LXI D,0925 / XRA A / MOV M,A,
fills the buffer with 00h); the cursor variables column / row / address. Every differing cell is listed;
"GOLDEN <snap> PASS|FAIL" is the last line (exit status 1 on FAIL).
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


BANNER = b'radio-86rk'
# CP3 rows of chain.vh (cp3_poke): the bytes, then 20h up to column 76 and the end-of-row code F1h at column 77
CP3_ROWS = {
    28: b'  NORMAL \x90INVERSE FIELD\x80 \xa0UNDERLINE\x80 \x82BLINK FIELD\x80 END',
    29: b'  ' + bytes(range(0x20)) + b' \x90' + bytes(range(1, 9)) + b'\x80 \xb0REV+UND\xa2UND+BLINK\x80 END',
}
# snap -> (prompt row text, CP3 rows poked, cursor column, cursor row)
GOLDEN = {
    'prompt': (b'-->', False, 11, 4),
    'attr': (b'-->', True, 11, 4),
    'keys': (b'-->D!', True, 13, 4),
    'keys2': (b'-->D!', True, 13, 4),
}
BLANK = 0x00
X = -1          # a byte of the dump with X / Z digits


def golden_screen(name, cols, rows):
    """{(row, column): byte} of the whole screen buffer for the snap <name>."""
    prompt, cp3, _, _ = GOLDEN[name]
    exp = dict(((r, c), BLANK) for r in range(rows) for c in range(cols))
    for i, b in enumerate(BANNER):
        exp[(3, 8 + i)] = b
    for i, b in enumerate(prompt):
        exp[(4, 8 + i)] = b
    if cp3:
        for r, data in CP3_ROWS.items():
            for c in range(cols):
                exp[(r, c)] = data[c] if c < len(data) else (0xF1 if c == cols - 1 else 0x20)
    return exp


def check_golden(name, ram, base, cols, rows):
    """List of error lines (empty: the screen equals the golden text)."""
    errs = []
    exp = golden_screen(name, cols, rows)
    for (r, c), want in sorted(exp.items()):
        got = ram[base + r * cols + c]
        if got != want:
            errs.append('cell row %d column %d (%04X): %s, expected %02X' % (r, c, base + r * cols + c,
                                                                           'X' if got == X else '%02X' % got, want))
    _, _, ccol, crow = GOLDEN[name]
    caddr = base + crow * cols + ccol
    got = [ram[0x7602], ram[0x7603], ram[0x7600], ram[0x7601]]
    want = [ccol, crow, caddr & 0xFF, caddr >> 8]
    for nm, g, w in zip(('cursor column [7602]', 'cursor row [7603]', 'cursor address low [7600]',
                         'cursor address high [7601]'), got, want):
        if g != w:
            errs.append('%s: %s, expected %02X' % (nm, 'X' if g == X else '%02X' % g, w))
    return errs


def char(c, ascii_only):
    if c == X:
        return 'X'
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
    ap.add_argument('--golden', choices=sorted(GOLDEN), help='check the expected screen of this picture')
    a = ap.parse_args()
    with open(a.bios, 'rb') as f:
        bios = bytearray(f.read())
    ram = []
    with open(a.ram) as f:
        for ln in f:
            s = ln.strip()
            if s:
                ram.append(int(s, 16) if all(c in '0123456789abcdefABCDEF' for c in s) else X)
    cols, rows, base, count = bios_screen(bios)
    ok = (cols, rows, base, count) == (78, 30, 0x76D0, 78 * 30) and count == cols * rows
    print('screen buffer: base %04X, %d columns x %d rows, DMA %d bytes per frame (%s)'
          % (base, cols, rows, count, 'stock values' if ok else 'ERROR: expected 76D0, 78 x 30, 2340'))
    nx = sum(1 for i in list(range(base, base + count)) + list(range(0x7600, 0x7604)) if ram[i] == X)
    if nx:
        print('ERROR: %d bytes with X in the screen buffer and the cursor variables (shown as X)' % nx)
        ok = False
    cv = ['X' if ram[i] == X else ram[i] for i in (0x7602, 0x7603)]
    ca = 'X' if X in (ram[0x7600], ram[0x7601]) else '%04X' % (ram[0x7600] | (ram[0x7601] << 8))
    print('cursor: column %s row %s, address %s' % (cv[0], cv[1], ca))
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
    if out is not None:
        out.flush()
    if a.golden:
        errs = check_golden(a.golden, ram, base, cols, rows) if (cols, rows) == (78, 30) else \
            ['the golden text is for 78 x 30']
        for e in errs[:40]:
            print('GOLDEN %s: %s' % (a.golden, e))
        if len(errs) > 40:
            print('GOLDEN %s: ... %d differences in all' % (a.golden, len(errs)))
        print('GOLDEN %s %s (%d differences)' % (a.golden, 'PASS' if not errs and ok else 'FAIL', len(errs)))
        ok = ok and not errs
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
