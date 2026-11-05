"""Reference rendering of the RK86 screen and the compare with the snapped VGA frames (plan Task 4 CP2-CP4).

Usage: python -B render.py <result dir> [--font FONT.BIN] [--vg75 4D,1D,99,93] [--sb 76D0] [--color 0]
       [--snap name ...] [--ppm]
<result dir>: the simout/ of a run (snaps.txt, ram_<name>.hex). Writes render.txt there (the last line
"RENDER PASS" or "RENDER FAIL"); exit status 1 on FAIL. --ppm also writes <name>_capture.ppm,
<name>_render.ppm and <name>_diff.ppm.

The model, in the terms of the CRT k580wg75.v and of rk_video.v (the same formulas, so it cannot find
an error of the formulas themselves; it checks the data path: DMA, CRT buffers, font, framebuffer,
the doubling and the overlay):
- Rows: the CRT reads 78 buffer entries per row (ipos 0..maxx); a field attribute code 80h-BFh
  (transparent mode, fillattr = 0) reads the next byte into the fifo, an end-of-row code (Fxh with bit 0
  set) stops the row (k580wg75.v:158-180). The rows follow each other in memory from the screen base;
  their bytes must add up to the DMA count (2340 = 78 x 30), else the picture drifts (DMA autoload).
- Columns (k580wg75.v:134-157): entry < 80h -> the character; 80h-BFh -> the fifo byte, the attribute
  takes effect on this column; C0h-FFh -> code 0, and F0h-F3h hold the column counter (the rest of the row
  is code 0). F2h/F3h (end of screen) are not supported. The attribute at the start of a row is the one
  at the end of the previous row (exattr), 0 at the start of the frame.
- Lines: text row k (ypos k + 1) on v_cnt 20k..20k+19 (the vrtc fall resets ypos at v_cnt 600, ypos 0 is
  the retrace row), scan row s = (v_cnt mod 20) / 2 (chline[4:1]; chline advances on every hrtc fall at
  h_cnt 468, so a scan row covers two lines). Glyph line (linemode 1) s == 0 ? 9 : s - 1, font address
  {code[6:0], line[2:0]} (rk_video.v:72). vsp = attr[1] & frame[4] | s == 0 | s == 9 (underline[3] = 1);
  lten = (attr[5] | cursor & frame[3]) & s == underline; rvv = attr[4] (underline cursor);
  dots = lten ? 3Fh : vsp ? 0 : glyph ^ rvv (rk_video.v:87), bit 5 first.
- H0: the hrtc fall (h_cnt 468, a cce) restarts opos at maxx[6:1] + D0h; opos reaches 0 on the
  (256 - restart + 1)-th cce after it; ochar is taken on that cce, the font answers one clock later and
  the dots are loaded at d_cnt = 5, so column c is on h_cnt H0 + 6c .. H0 + 6c + 5 with
  H0 = (468 + 6 (256 - restart + 1)) mod 516 + 6 (24 for maxx 77). V0: ypos 1 starts 2 (charheight + 1)
  lines after v_cnt 600, i.e. at v_cnt 0.
- Framebuffer 408 x 300 (rk_video.v:92-95): fb[y][x] = dot(h_cnt = x + 60, v_cnt = 2y or 2y + 1, the
  same scan row).
- VGA read path (rk_video.v:155-189, the rambuffer port B with a read latency of 1 clock, no output
  register): simulated clock by clock over CounterX 0..1056, CounterY 0..628 (pixel_state, line_state,
  pixel_cnt, line_cnt, address_out); pixel = data_out & (CounterX < 800 & CounterY < 600); colour 80h on
  R, G, B (Text color 0) or 20h/80h/20h (1); the overlay passes RGB through while the OSD is closed.
- Pin coordinates: frames.py.
Alignment: the bounding boxes of the lit dots of the capture and of the rendering must coincide (else
"render offset", FAIL); then every visible dot is compared. The cursor cell (column [7602h], row [7603h],
the monitor's cursor variables, written to the CRT with command 80h, BIOS FD85-FD96) and the blinking
fields depend on the frame counter of the CRT: each of their lines must equal the rendering with the
phase on or off (recorded). Field checks (CP3): reverse video fields have more than half of the dots of
their glyph rows (scan rows 1..8) lit; underlined fields have all 6 dots of every cell lit on scan row 9.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import frames  # noqa: E402

H_LINE, V_FRAME = 516, 620       # rk_video.v: h_cnt 0..515, v_cnt 0..619
HRTC_FALL, VRTC_FALL = 468, 600
FB_X0, FB_W, FB_H = 60, 408, 300


class Unsupported(Exception):
    pass


def read_ram(path):
    data = bytearray()
    with open(path) as f:
        for ln in f:
            s = ln.strip()
            if not s:
                continue
            if any(c not in '0123456789abcdefABCDEF' for c in s):
                raise ValueError('%s: not a byte: %r (X in the RAM?)' % (path, s))
            data.append(int(s, 16))
    return data


class Vg75(object):
    def __init__(self, b):
        self.maxx = b[0] & 0x7F
        self.maxy = b[1] & 0x3F
        self.underline = b[2] >> 4
        self.charheight = b[2] & 0x0F
        self.linemode = b[3] >> 7
        self.fillattr = (b[3] >> 6) & 1
        self.curblink = (b[3] >> 5) & 1
        self.curtype = (b[3] >> 4) & 1
        if not (self.linemode == 1 and self.fillattr == 0 and self.curtype == 1 and self.underline >= 8):
            raise Unsupported('VG75 setup %s: only linemode 1, transparent attributes, underline cursor, underline >= 8'
                              % ','.join('%02X' % x for x in b))
        restart = (self.maxx >> 1) + 0xD0
        self.h0 = (HRTC_FALL + 6 * (256 - restart + 1)) % H_LINE + 6
        self.row_lines = 2 * (self.charheight + 1)
        self.v0 = (VRTC_FALL + self.row_lines) % V_FRAME


def parse_rows(ram, sb, vg):
    """[(row start address, bytes taken, [(code, attr)] per column, attributes in the row)]"""
    ncol = vg.maxx + 1
    rows = []
    a = sb
    attr = 0
    for k in range(vg.maxy + 1):
        start = a
        entries, fifo = [], []
        while len(entries) < ncol:
            b = ram[a]
            a += 1
            entries.append(b)
            if 0x80 <= b <= 0xBF:
                fifo.append(ram[a] & 0x7F)
                a += 1
            elif b >> 4 == 0xF and b & 1:
                if b & 2:
                    raise Unsupported('row %d: end-of-screen code %02X' % (k, b))
                break
        taken = a - start
        cols, codes = [], []
        hold = False
        fi = 0
        for c in range(ncol):
            if hold:
                cols.append((0, attr))
                continue
            if c >= len(entries):
                raise Unsupported('row %d: column %d after an end-of-row code that is not F0h-F3h' % (k, c))
            e = entries[c]
            if e < 0x80:
                cols.append((e & 0x7F, attr))
            elif e <= 0xBF:
                attr = e & 0x3F
                codes.append((c, e))
                cols.append((fifo[fi], attr))
                fi += 1
            else:
                cols.append((0, attr))
                if 0xF0 <= e <= 0xF3:
                    if e & 2:
                        raise Unsupported('row %d: end-of-screen code %02X' % (k, e))
                    hold = True
                elif e >> 4 == 0xF and e & 1:
                    raise Unsupported('row %d: end-of-row code %02X (stale buffer after it)' % (k, e))
        rows.append((start, taken, cols, codes))
    return rows


def native_dot_rows(rows, vg, font, cursor, frame3, frame4):
    """fb[y][x] (0/1) for x 0..407, y 0..299."""
    fb = []
    for y in range(FB_H):
        v = 2 * y
        k = (v - vg.v0) // vg.row_lines
        s = ((v - vg.v0) % vg.row_lines) // 2
        row = bytearray(FB_W)
        if 0 <= k <= vg.maxy:
            cols = rows[k][2]
            for x in range(FB_W):
                h = x + FB_X0
                if h < vg.h0:
                    continue          # code 0 field before column 0 (its glyph rows are blank)
                c = (h - vg.h0) // 6
                bit = 5 - (h - vg.h0) % 6
                if c > vg.maxx:
                    continue
                code, attr = cols[c]
                vcur = cursor is not None and (c, k) == cursor and (frame3 or vg.curblink)
                lten = ((attr >> 5) & 1 or (vg.curtype and vcur)) and s == vg.underline
                vsp = ((attr >> 1) & 1 and frame4) or s == 0 or s == vg.charheight
                rvv = (attr >> 4) & 1
                line = vg.charheight if s == 0 else s - 1
                g = font[(code & 0x7F) * 8 + (line & 7)] & 0x3F
                data = 0x3F if lten else (0 if vsp else (g ^ (0x3F if rvv else 0)))
                row[x] = (data >> bit) & 1
        fb.append(row)
    return fb


def read_path():
    """The VGA read path of rk_video.v over two frames: for the second frame, src[cy][cx] = the fb
    address shown at CounterX cx, CounterY cy of the visible area (data_out of the rambuffer)."""
    pixel_state = line_state = 0
    pixel_cnt = line_cnt = 0
    address_out = 0
    data_addr = 0
    src = [[0] * frames.VIS_W for _ in range(frames.VIS_H)]
    for fr in range(2):
        for cy in range(frames.V_TOTAL):
            for cx in range(frames.H_TOTAL):
                # the values during this clock
                if fr == 1 and cx < frames.VIS_W and cy < frames.VIS_H:
                    src[cy][cx] = data_addr
                # the clock edge at its end
                n_data_addr = address_out
                if cx < 816 and cy < 600:
                    n_ps, n_ls, n_pc, n_lc = pixel_state, line_state, pixel_cnt, line_cnt
                    n_ps = 1 if pixel_state == 0 else 0
                    n_ao = pixel_cnt + line_cnt * 408
                    if pixel_state == 1:
                        n_pc = pixel_cnt + 1
                    if cx + 1 == 816:
                        n_pc = 0
                        n_ls = 1 if line_state == 0 else 0
                        if line_state == 1:
                            n_lc = line_cnt + 1
                    if cy + 1 == 600:
                        n_lc = 0
                        n_pc = 0
                        n_ls = 0
                    pixel_state, line_state, pixel_cnt, line_cnt, address_out = n_ps, n_ls, n_pc, n_lc, n_ao
                data_addr = n_data_addr
    return src


def vga_from_fb(fb, src):
    flat = bytearray()
    for row in fb:
        flat += row
    n = len(flat)
    return [bytearray(flat[a] if a < n else 0 for a in row) for row in src]


def bbox(img):
    xs, ys = [], []
    for y, row in enumerate(img):
        for x, v in enumerate(row):
            if v:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))


def render_snap(name, snap, ram, font, vg, sb, dma_count, colour, ppm_dir, src, log):
    ok = True
    rows = parse_rows(ram, sb, vg)
    total = sum(r[1] for r in rows)
    if total != dma_count:
        log('RENDER %s: FAIL the rows take %d bytes, the DMA count is %d: the picture drifts' % (name, total, dma_count))
        return False
    cx, cy = ram[0x7602], ram[0x7603]
    cursor = (cx, cy)
    var = {}
    for f3 in (0, 1):
        for f4 in (0, 1):
            var[(f3, f4)] = vga_from_fb(native_dot_rows(rows, vg, font, cursor, f3, f4), src)
    cap = snap.visible()
    lit_rgb = {0: '808080', 1: '208020'}[colour]
    capb = []
    nbad_colour = 0
    for row in cap:
        r = bytearray()
        for v in row:
            if v == '000000':
                r.append(0)
            elif v == lit_rgb:
                r.append(1)
            else:
                r.append(2)
                nbad_colour += 1
        capb.append(r)
    if nbad_colour:
        log('RENDER %s: %d dots with a colour other than 000000 / %s (or X)' % (name, nbad_colour, lit_rgb))
        ok = False
    # alignment
    base = var[(0, 0)]
    bc, br = bbox(capb), bbox(base)
    if bc is None or br is None:
        log('RENDER %s: FAIL empty picture (capture bbox %s, render bbox %s)' % (name, bc, br))
        return False
    dx, dy = bc[0] - br[0], bc[1] - br[1]
    if (dx, dy) != (0, 0) or bc[2] - br[2] != dx or bc[3] - br[3] != dy:
        # the cursor / blink variants can change the box: accept if any variant matches
        boxes = dict((k, bbox(v)) for k, v in var.items())
        if bc not in boxes.values():
            log('RENDER %s: FAIL render offset: capture bbox %s, render bbox %s (dx %d, dy %d; H0 %d, V0 %d analytic)'
                % (name, bc, br, dx, dy, vg.h0, vg.v0))
            return False
    # per line: the dots that depend on the phases must equal one variant; all others equal
    ndiff = 0
    phases = {'cursor': set(), 'blink': set()}
    first = []
    for y in range(frames.VIS_H):
        c = capb[y]
        dep = [x for x in range(frames.VIS_W) if len(set(var[k][y][x] for k in var)) > 1]
        depset = set(dep)
        for x in range(frames.VIS_W):
            if x not in depset and c[x] != base[y][x]:
                ndiff += 1
                if len(first) < 10:
                    first.append((x, y, c[x], base[y][x]))
        if dep:
            match = [k for k in var if all(c[x] == var[k][y][x] for x in dep)]
            if not match:
                ndiff += sum(1 for x in dep if c[x] != base[y][x])
                if len(first) < 10:
                    first.append(('line', y, 'no phase matches', len(dep)))
            else:
                f3s = set(k[0] for k in match)
                f4s = set(k[1] for k in match)
                if len(f3s) == 1:
                    phases['cursor'].add(f3s.pop())
                if len(f4s) == 1:
                    phases['blink'].add(f4s.pop())
    lit_c = sum(sum(r) for r in capb)
    lit_r = sum(sum(r) for r in base)
    log('RENDER %s: frame %d (start cycle %d): %d dots differ; lit dots capture %d, render %d (phases 0); bbox %s; '
        'H0 %d V0 %d; cursor column %d row %d, phase frame[3] %s; blink phase frame[4] %s'
        % (name, snap.frame, snap.start, ndiff, lit_c, lit_r, bc, vg.h0, vg.v0, cx, cy,
           sorted(phases['cursor']) or 'n/a', sorted(phases['blink']) or 'n/a'))
    for f in first:
        log('  first differences: %s' % (f,))
    if ndiff:
        ok = False
    # field checks (CP3): on the capture, in fb coordinates through the read path
    inv = {}
    for y in range(frames.VIS_H):
        for x in range(frames.VIS_W):
            inv.setdefault(src[y][x], (x, y))
    for k, (start, taken, cols, codes) in enumerate(rows):
        for i, (c0, code) in enumerate(codes):
            c1 = codes[i + 1][0] if i + 1 < len(codes) else vg.maxx + 1
            attr = code & 0x3F
            vis = [c for c in range(c0, c1) if FB_X0 <= vg.h0 + 6 * c and vg.h0 + 6 * c + 5 < FB_X0 + FB_W]
            if not vis or not attr & 0x30:
                continue
            fy0 = (vg.v0 + k * vg.row_lines) // 2

            def capdot(fx, fy):
                a = fy * FB_W + fx
                p = inv.get(a)
                return capb[p[1]][p[0]] if p else None
            if attr & 0x10:
                dots = [capdot(vg.h0 + 6 * c + d - FB_X0, fy0 + s) for c in vis for d in range(6)
                        for s in range(1, vg.charheight)]
                frac = float(sum(1 for d in dots if d == 1)) / len(dots)
                good = frac > 0.5
                log('  CP3 row %d columns %d-%d attribute %02X reverse video: lit fraction %.3f of the glyph rows %s'
                    % (k, vis[0], vis[-1], code, frac, 'ok' if good else 'FAIL'))
                ok = ok and good
            if attr & 0x20:
                dots = [capdot(vg.h0 + 6 * c + d - FB_X0, fy0 + vg.underline) for c in vis for d in range(6)]
                good = all(d == 1 for d in dots)
                log('  CP3 row %d columns %d-%d attribute %02X underline: %d of %d dots lit on scan row %d %s'
                    % (k, vis[0], vis[-1], code, sum(1 for d in dots if d == 1), len(dots), vg.underline,
                       'ok' if good else 'FAIL'))
                ok = ok and good
    if ppm_dir:
        pal = {0: (0, 0, 0), 1: (255, 255, 255), 2: (255, 0, 255)}
        frames.write_ppm(os.path.join(ppm_dir, name + '_capture.ppm'), capb, lambda v: pal[v])
        frames.write_ppm(os.path.join(ppm_dir, name + '_render.ppm'), base, lambda v: pal[v])
        diff = [bytearray(2 if capb[y][x] != base[y][x] else base[y][x] for x in range(frames.VIS_W))
                for y in range(frames.VIS_H)]
        frames.write_ppm(os.path.join(ppm_dir, name + '_diff.ppm'), diff, lambda v: pal[v])
    return ok


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description='Reference rendering of the RK86 screen against the snapped frames')
    ap.add_argument('simout')
    ap.add_argument('--font', default=os.path.join(here, '..', '..', '..', 'roms', 'FONT.BIN'))
    ap.add_argument('--vg75', default='4D,1D,99,93', help='the CRT parameters of the BIOS (FAD5-FADB)')
    ap.add_argument('--sb', default='76D0', help='screen base (DMA channel 2 address, BIOS FAEE-FAF0)')
    ap.add_argument('--dma-count', type=int, default=2340, help='DMA bytes per frame (BIOS FAF3-FAF5: 4923h)')
    ap.add_argument('--color', type=int, default=0, choices=(0, 1), help='OSD Text color')
    ap.add_argument('--snap', action='append', help='snap names (default: all in snaps.txt)')
    ap.add_argument('--ppm', action='store_true')
    a = ap.parse_args()
    lines = []

    def log(s):
        print(s)
        lines.append(s)
    with open(a.font, 'rb') as f:
        font = f.read()
    if len(font) != 1024:
        log('RENDER: font %s has %d bytes, expected 1024' % (a.font, len(font)))
        return 2
    vg = Vg75([int(x, 16) for x in a.vg75.split(',')])
    snaps, order = frames.read_snaps(os.path.join(a.simout, 'snaps.txt'))
    names = a.snap or order
    ok = bool(names)
    if not names:
        log('RENDER: no snaps in %s' % os.path.join(a.simout, 'snaps.txt'))
    src = read_path() if names else None
    for n in names:
        if n not in snaps:
            log('RENDER %s: FAIL no such snap' % n)
            ok = False
            continue
        s = snaps[n]
        if s.end is None:
            log('RENDER %s: FAIL the frame is incomplete (no END)' % n)
            ok = False
            continue
        try:
            ram = read_ram(os.path.join(a.simout, 'ram_%s.hex' % n))
            ok = render_snap(n, s, ram, font, vg, int(a.sb, 16), a.dma_count, a.color,
                             a.simout if a.ppm else None, src, log) and ok
        except (Unsupported, ValueError, IOError) as e:
            log('RENDER %s: FAIL %s' % (n, e))
            ok = False
    log('RENDER %s' % ('PASS' if ok else 'FAIL'))
    with open(os.path.join(a.simout, 'render.txt'), 'w') as f:
        f.write('\n'.join(lines) + '\n')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
