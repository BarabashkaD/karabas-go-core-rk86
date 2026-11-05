"""Self-test of the reference renderer: mutated copies of a passing run must fail (plan Task 4, review).

Usage: python -B render_selftest.py <simout> --font FONT.BIN --out <dir>
<simout>: the simout/ of a basic-chain run whose rendering passes (snaps.txt, ram_<snap>.hex with the
snaps prompt and attr). Each case gets a copy under <dir>/<case>/ (snaps.txt, ram_*.hex, the font) with
one change, then tools/render.py runs on it:
  control  no change                                                   -> RENDER PASS
  ram      ram_prompt.hex: the byte at 7811h (the second '-' of the prompt) -> 58h 'X'   -> FAIL
  attr     ram_attr.hex: the first attribute 90h of screen row 28 -> 80h (no reverse video)  -> FAIL
  dy       snaps.txt: every line number of the snap prompt + 1 (the picture one line lower)  -> FAIL
  font     FONT.BIN: glyph 72h ('r' of the banner), glyph line 3 inverted (6 dots)   -> FAIL
  cursor   ram_prompt.hex: the cursor column [7602h] + 1                   -> FAIL
<dir>/selftest.txt lists the cases and the last lines of their render.txt; the last line is
"RENDER SELFTEST PASS|FAIL" (exit status 0 / 1).
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SB, COLS = 0x76D0, 78


def edit_hex(path, addr, fn):
    lines = open(path).read().split('\n')
    old = int(lines[addr], 16)
    lines[addr] = '%02x' % fn(old)
    with open(path, 'w', newline='\n') as f:
        f.write('\n'.join(lines))
    return old


def main():
    ap = argparse.ArgumentParser(description='Self-test of tools/render.py with mutated copies')
    ap.add_argument('simout')
    ap.add_argument('--font', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    cases = ['control', 'ram', 'attr', 'dy', 'font', 'cursor']
    report = []
    ok_all = True
    for c in cases:
        d = os.path.join(a.out, c)
        if os.path.isdir(d):
            shutil.rmtree(d)
        os.makedirs(d)
        for f in ['snaps.txt'] + [os.path.basename(x) for x in glob.glob(os.path.join(a.simout, 'ram_*.hex'))]:
            shutil.copyfile(os.path.join(a.simout, f), os.path.join(d, f))
        font = os.path.join(d, 'FONT.BIN')
        shutil.copyfile(a.font, font)
        what = 'no change'
        if c == 'ram':
            old = edit_hex(os.path.join(d, 'ram_prompt.hex'), 0x7811, lambda v: 0x58)
            what = 'ram_prompt.hex [7811] %02X -> 58' % old
        elif c == 'attr':
            p = os.path.join(d, 'ram_attr.hex')
            lines = open(p).read().split('\n')
            row = SB + 28 * COLS
            k = next(i for i in range(row, row + COLS) if lines[i].strip().lower() == '90')
            edit_hex(p, k, lambda v: 0x80)
            what = 'ram_attr.hex [%04X] (row 28 column %d) 90 -> 80' % (k, k - row)
        elif c == 'dy':
            p = os.path.join(d, 'snaps.txt')
            out, cur = [], None
            for ln in open(p):
                f = ln.split()
                if f and f[0] == 'SNAP':
                    cur = f[1]
                elif f and f[0] not in ('END',) and cur == 'prompt':
                    ln = '%d %s %s\n' % (int(f[0]) + 1, f[1], f[2])
                elif f and f[0] == 'END':
                    cur = None
                out.append(ln)
            with open(p, 'w', newline='\n') as fo:
                fo.writelines(out)
            what = 'snaps.txt: snap prompt one line lower'
        elif c == 'font':
            b = bytearray(open(font, 'rb').read())
            b[0x72 * 8 + 3] ^= 0x3F
            open(font, 'wb').write(bytes(b))
            what = 'FONT.BIN glyph 72h line 3 ^ 3Fh'
        elif c == 'cursor':
            old = edit_hex(os.path.join(d, 'ram_prompt.hex'), 0x7602, lambda v: v + 1)
            what = 'ram_prompt.hex [7602] %02X -> %02X' % (old, old + 1)
        p = subprocess.run([sys.executable, '-B', os.path.join(HERE, 'render.py'), d, '--font', font],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = p.stdout.decode('utf-8', 'replace').strip().splitlines()
        want = 0 if c == 'control' else 1
        good = p.returncode == want
        ok_all = ok_all and good
        key = [ln for ln in text if ('dots differ' in ln or 'FAIL' in ln) and not ln.startswith('READ PATH')][:3]
        report.append('%-8s %-50s render exit %d (expected %d) %s' % (c, what, p.returncode, want,
                                                                     'ok' if good else 'WRONG'))
        report += ['           %s' % ln for ln in key]
    report.append('RENDER SELFTEST %s' % ('PASS' if ok_all else 'FAIL'))
    for ln in report:
        print(ln)
    with open(os.path.join(a.out, 'selftest.txt'), 'w', newline='\n') as f:
        f.write('\n'.join(report) + '\n')
    return 0 if ok_all else 1


if __name__ == '__main__':
    sys.exit(main())
