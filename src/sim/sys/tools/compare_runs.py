"""L0 / L1 comparison of two system-simulation runs (plan Task 5, amendments A1, A2).

Usage: python -B compare_runs.py <result A> <result B> --out <dir> [--font FONT.BIN] [--board-vh board_go.vh]
       [--self-compare] [--expect identical|differ] [--detail-a <result> --detail-b <result>]
<result A/B>: build/sim/sys/out/<run-id>/<board>-<sha7>[-<tag>] of the two revisions, the same board and TB
revision, each generated in compare mode (gen_sim --compare: the .syr of the revision, no POWER-UP DIFFERS /
UNCOMPARED). Writes <dir>/compare.txt (also printed).

Stand checks first (a failure is exit status 2, no verdict): both summary.txt in compare mode, the same board
and TB revision, the hashes of trace.txt hex (A1), and the RTL files of the two revisions not byte-identical
(A2) unless --self-compare (a calibration with a seeded change on one side, gen_sim --seed).

L0: trace.txt window by window (the hash of every change of the observed pins, the change count, the counted
pins). On the first differing window it prints the plusargs of a detail run of both revisions
(+TRACE_FROM / +TRACE_TO / +STOP_AT); with --detail-a / --detail-b (the results of those runs,
simout/trace_detail.txt) it finds the first differing cycle and the differing pins (named after GO_OBS of
board_go.vh).
L1 (event-aligned): the sequence of event names (simout/events.txt; the echo lines without their time); the
RAM 0000-7FFF at every event (simout/ev_<n>_<name>.hex) and at every picture (ram_<snap>.hex); the
value-changing SRAM writes (address, value; no time) between consecutive events (simout/sram_wr.txt); the
snapped frames (visible 800 x 600, the cursor cell masked: the dots that depend on frame[3] in the reference
rendering of either side, tools/render.py, needs --font). Frame numbers and cycles are not compared; the
cycle shift at each event is informative.
Verdict lines: "L0 IDENTICAL|DIFFERS", "L1 EQUAL|DIFFERS", and "COMPARE PASS|FAIL" for --expect (identical:
L0 identical; differ: L0 and L1 both differ, the seeded calibration). Exit status 0 = PASS, 1 = FAIL.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import frames  # noqa: E402

WIN = 4096


class StandError(Exception):
    pass


def read_lines(path):
    if not os.path.isfile(path):
        raise StandError('%s missing' % path)
    with open(path) as f:
        return [ln.rstrip('\n') for ln in f]


def summary_info(res):
    sm = read_lines(os.path.join(res, 'summary.txt'))
    info = {'compare': False, 'rtl': [], 'board': None, 'tb': None, 'rev': None, 'verdicts': [], 'seeds': [],
            'fsm_bad': [], 'run': None}
    sec = None
    for ln in sm:
        if not ln.startswith(' ') and ln.strip():
            sec = ln.split(' (')[0].strip()
        m = re.match(r'^sim work tree: board (\w+)', ln)
        if m:
            info['board'] = m.group(1)
        m = re.match(r'^revision (\S+); TB revision (\S+);', ln)
        if m:
            info['rev'], info['tb'] = m.group(1), m.group(2)
        if ln.startswith('COMPARE MODE: yes'):
            info['compare'] = True
        if sec == 'RTL FILES OF THE REVISION' and ln.startswith('  '):
            info['rtl'].append(ln.strip())
        if sec and sec.startswith('SEEDED CHANGES') and ln.startswith('  #'):
            info['seeds'].append(ln.strip())
        if sec == 'FSM ENCODINGS' and ('UNCOMPARED' in ln or 'DIFFERS' in ln):
            info['fsm_bad'].append(ln.strip())
        if 'RUN VERDICT' in ln:
            info['run'] = ln.split()[-1]
    return info


def read_trace(res):
    rows = []
    for ln in read_lines(os.path.join(res, 'simout', 'trace.txt')):
        f = ln.split()
        if not f:
            continue
        if f[0] != 'W' or len(f) < 5:
            raise StandError('%s: not a window line: %r' % (res, ln))
        if not re.match(r'^[0-9a-f]{16}$', f[3]):
            raise StandError('%s/simout/trace.txt window %s: hash %r is not 16 hex digits (A1)' % (res, f[1], f[3]))
        rows.append((int(f[1]), int(f[2]), f[3], int(f[4]), tuple(int(x) for x in f[5:])))
    return rows


def obs_fields(board_vh):
    """[(name, width)] of the observed vector, MSB first, from `define GO_OBS of board_go.vh."""
    text = open(board_vh).read()
    widths = {}
    for m in re.finditer(r'(?m)^\s*wire\s*(\[(\d+):(\d+)\])?\s*([^;=]+);', text):
        w = abs(int(m.group(2)) - int(m.group(3))) + 1 if m.group(1) else 1
        for nm in m.group(4).split(','):
            widths[nm.strip()] = w
    m = re.search(r'`define GO_OBS \{(.*?)\n\}', text, re.S)
    if not m:
        raise StandError('%s: no `define GO_OBS' % board_vh)
    body = re.sub(r'/\*.*?\*/', '', m.group(1)).replace('\\', ' ')
    fields = []
    depth, tok = 0, ''
    for ch in body + ',':
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            t = tok.strip()
            tok = ''
            if not t:
                continue
            if t.startswith('('):
                nm = re.findall(r'\w+', t)[-1]
                fields.append((nm + ' (while MCU_CS_N = 0)', 1))
            else:
                if t not in widths:
                    raise StandError('%s: width of %s unknown' % (board_vh, t))
                fields.append((t, widths[t]))
        else:
            tok += ch
    return fields


def bits_to_fields(diff, fields):
    """Names (with bit ranges) of the set bits of diff (bit 0 = LSB of the vector)."""
    out = []
    pos = sum(w for _, w in fields)
    for nm, w in fields:
        pos -= w
        sub = (diff >> pos) & ((1 << w) - 1)
        if sub:
            bits = [i for i in range(w) if sub >> i & 1]
            out.append('%s[%s]' % (nm, ','.join(str(b) for b in reversed(bits))) if w > 1 else nm)
    return out


def read_detail(res):
    out = []
    for ln in read_lines(os.path.join(res, 'simout', 'trace_detail.txt')):
        f = ln.split()
        if len(f) == 4:
            out.append((int(f[0]), int(f[1], 16), int(f[2], 16), int(f[3], 16)))
    return out


def detail_diff(da, db, lo, hi):
    """First cycle in [lo, hi] where the two detail traces differ: (cycle, value A, value B) or None."""
    ia = [x for x in da if lo <= x[0] <= hi]
    ib = [x for x in db if lo <= x[0] <= hi]
    ma = dict((x[0], x[1:]) for x in ia)
    mb = dict((x[0], x[1:]) for x in ib)
    pa = pb = None
    for c in sorted(set(ma) | set(mb)):
        va = ma.get(c, pa)
        vb = mb.get(c, pb)
        if va != vb or (c in ma) != (c in mb):
            if va is None or vb is None:
                va = va if va is not None else vb
                vb = vb if vb is not None else va
            return c, va, vb
        pa, pb = va, vb
    return None


def read_events(res):
    ev = []
    for ln in read_lines(os.path.join(res, 'simout', 'events.txt')):
        f = ln.split(None, 1)
        if len(f) == 2:
            ev.append((int(f[0]), re.sub(r' after \d+ cycles$', '', f[1].strip())))
    return ev


def read_hex(path):
    if not os.path.isfile(path):
        return None
    return [ln.strip().lower() for ln in open(path) if ln.strip()]


def read_writes(res):
    w = []
    for ln in read_lines(os.path.join(res, 'simout', 'sram_wr.txt')):
        f = ln.split()
        if len(f) == 4 and f[3] == '1':
            w.append((int(f[0]), f[1], f[2]))
    return w


def ram_diff(a, b):
    if a is None or b is None:
        return 'missing on %s' % ('both sides' if a is None and b is None else ('A' if a is None else 'B'))
    if len(a) != len(b):
        return '%d vs %d bytes' % (len(a), len(b))
    d = [i for i in range(len(a)) if a[i] != b[i]]
    if not d:
        return None
    return '%d bytes differ, first %s' % (len(d), ', '.join('%04X: %s / %s' % (i, a[i], b[i]) for i in d[:6]))


def frame_diff(sa, sb, ram_a, ram_b, font):
    """Differing dots of two snaps (visible area), the cursor dots of either side masked."""
    va, vb = sa.visible(), sb.visible()
    mask = set()
    note = 'no cursor mask (no --font)'
    if font is not None and ram_a and ram_b:
        import render
        vg = render.Vg75([0x4D, 0x1D, 0x99, 0x93])
        src = frame_diff.src
        for ram in (ram_a, ram_b):
            r = bytearray(int(x, 16) if re.match(r'^[0-9a-f]{2}$', x) else 0 for x in ram)
            rows = render.parse_rows(r, 0x76D0, vg)
            cur = (r[0x7602], r[0x7603])
            img = {}
            for f3 in (0, 1):
                img[f3] = render.vga_from_fb(render.native_dot_rows(rows, vg, font, cur, f3, 0), src)
            for y in range(frames.VIS_H):
                for x in range(frames.VIS_W):
                    if img[0][y][x] != img[1][y][x]:
                        mask.add((x, y))
        note = 'cursor mask %d dots' % len(mask)
    diff = [(x, y) for y in range(frames.VIS_H) for x in range(frames.VIS_W)
            if va[y][x] != vb[y][x] and (x, y) not in mask]
    return diff, note


frame_diff.src = None


def main():
    ap = argparse.ArgumentParser(description='L0 / L1 comparison of two system-simulation runs')
    ap.add_argument('a')
    ap.add_argument('b')
    ap.add_argument('--out', required=True)
    ap.add_argument('--font', help='FONT.BIN for the cursor mask of the frames')
    ap.add_argument('--board-vh', default=os.path.join(HERE, '..', 'board_go.vh'))
    ap.add_argument('--self-compare', action='store_true')
    ap.add_argument('--expect', choices=('identical', 'differ'), default='identical')
    ap.add_argument('--detail-a')
    ap.add_argument('--detail-b')
    a = ap.parse_args()
    lines = []

    def log(s=''):
        print(s)
        lines.append(s)

    def finish(code):
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, 'compare.txt'), 'w', newline='\n') as f:
            f.write('\n'.join(lines) + '\n')
        return code

    A, B = os.path.abspath(a.a), os.path.abspath(a.b)
    log('COMPARE A %s' % A.replace(os.sep, '/').split('/out/')[-1])
    log('COMPARE B %s' % B.replace(os.sep, '/').split('/out/')[-1])
    try:
        ia, ib = summary_info(A), summary_info(B)
        for nm, i in (('A', ia), ('B', ib)):
            log('%s: revision %s, board %s, TB %s, compare mode %s, seeded %s, run verdict %s'
                % (nm, i['rev'], i['board'], i['tb'], 'yes' if i['compare'] else 'NO', i['seeds'] or 'none',
                   i['run'] or '?'))
            if not i['compare']:
                raise StandError('%s was not generated in compare mode (gen_sim --compare with --syr)' % nm)
            if i['fsm_bad']:
                raise StandError('%s: FSM encodings not equal to the table: %s' % (nm, i['fsm_bad']))
        if ia['board'] != ib['board'] or ia['tb'] != ib['tb']:
            raise StandError('different board or TB revision: %s / %s, %s / %s' % (ia['board'], ib['board'],
                                                                               ia['tb'], ib['tb']))
        same_rtl = sorted(ia['rtl']) == sorted(ib['rtl'])
        if same_rtl and not a.self_compare:
            raise StandError('the two revisions have byte-identical RTL (%d files): refused (A2); --self-compare '
                             'for an explicit self-compare' % len(ia['rtl']))
        ha = dict(x.split('  ')[::-1] for x in ia['rtl'])
        hb = dict(x.split('  ')[::-1] for x in ib['rtl'])
        dk = sorted(k for k in set(ha) | set(hb) if ha.get(k) != hb.get(k))
        log('RTL: %s' % ('byte-identical (%d files), explicit self-compare' % len(ha) if same_rtl else
                         '%d files differ or exist on one side only: %s' % (len(dk), ', '.join(dk))))
        ta, tb = read_trace(A), read_trace(B)
    except StandError as e:
        log('STAND ERROR: %s' % e)
        log('COMPARE FAIL (stand)')
        return finish(2)

    # ---- L0
    log('')
    first = None
    ndiff = 0
    for i in range(min(len(ta), len(tb))):
        if ta[i] != tb[i]:
            ndiff += 1
            if first is None:
                first = i
    if len(ta) != len(tb) and first is None:
        first = min(len(ta), len(tb))
    l0_same = first is None and len(ta) == len(tb)
    log('L0: %d / %d windows of %d cycles; %d differing windows in the common part' % (len(ta), len(tb), WIN, ndiff))
    if l0_same:
        log('L0 IDENTICAL (trace hashes, change counts and counted pins of every window)')
    else:
        if first < min(len(ta), len(tb)):
            wa, wb = ta[first], tb[first]
            parts = [nm for nm, x, y in (('hash', wa[2], wb[2]), ('changes', wa[3], wb[3]), ('counters', wa[4], wb[4]))
                     if x != y]
            log('L0 DIFFERS: first differing window %d (cycles %d..%d): %s; A %s %d %s, B %s %d %s'
                % (wa[0], wa[1], wa[1] + WIN - 1, ', '.join(parts), wa[2], wa[3], wa[4], wb[2], wb[3], wb[4]))
            lo, hi = wa[1], wa[1] + WIN - 1
        else:
            log('L0 DIFFERS: the runs have %d and %d windows (equal up to the shorter one)' % (len(ta), len(tb)))
            lo = hi = None
        if lo is not None:
            log('L0 detail run of both revisions: plusargs TRACE_FROM=%d TRACE_TO=%d STOP_AT=%d' % (lo, hi, hi + 1))
            if a.detail_a and a.detail_b:
                try:
                    dd = detail_diff(read_detail(a.detail_a), read_detail(a.detail_b), lo, hi)
                    fields = obs_fields(a.board_vh)
                except StandError as e:
                    log('L0 detail: STAND ERROR %s' % e)
                    dd, fields = None, []
                if dd is None:
                    log('L0 detail: no difference in cycles %d..%d of the detail traces' % (lo, hi))
                else:
                    c, va, vb = dd
                    names = bits_to_fields((va[0] ^ vb[0]) | (va[1] ^ vb[1]) | (va[2] ^ vb[2]), fields)
                    log('L0 detail: first differing cycle %d (window offset %d); differing pins: %s'
                        % (c, c - lo, ', '.join(names)))
                    log('L0 detail: values A %x / B %x (X mask A %x / B %x)' % (va[0], vb[0], va[1], vb[1]))

    # ---- L1
    log('')
    ea, eb = read_events(A), read_events(B)
    na, nb = [e[1] for e in ea], [e[1] for e in eb]
    l1_bad = []
    if na != nb:
        k = next((i for i in range(min(len(na), len(nb))) if na[i] != nb[i]), min(len(na), len(nb)))
        l1_bad.append('event sequence differs at event %d: A %s, B %s' % (k, na[k:k + 2], nb[k:k + 2]))
    common = min(len(ea), len(eb))
    k_ok = next((i for i in range(common) if na[i] != nb[i]), common)
    log('L1 events: A %d, B %d; equal names up to event %d' % (len(ea), len(eb), k_ok))
    # RAM at the events (the TB numbers every mark_event; the echo lines are not mark_events)
    dumps_a = sorted(f for f in os.listdir(os.path.join(A, 'simout')) if re.match(r'^ev_\d+_.*\.hex$', f))
    dumps_b = set(f for f in os.listdir(os.path.join(B, 'simout')) if re.match(r'^ev_\d+_.*\.hex$', f))
    for f in sorted(dumps_a, key=lambda x: int(x.split('_')[1])):
        r = ram_diff(read_hex(os.path.join(A, 'simout', f)), read_hex(os.path.join(B, 'simout', f))
                     if f in dumps_b else None)
        if r:
            l1_bad.append('RAM at %s: %s' % (f[:-4], r))
    for f in sorted(dumps_b - set(dumps_a)):
        l1_bad.append('RAM at %s: missing on A' % f[:-4])
    log('L1 RAM dumps at events: %d on A, %d on B' % (len(dumps_a), len(dumps_b)))
    # value-changing SRAM writes between consecutive events
    wa, wb = read_writes(A), read_writes(B)
    cyc_a = [e[0] for e in ea[:k_ok]] + [float('inf')]
    cyc_b = [e[0] for e in eb[:k_ok]] + [float('inf')]

    def split(ws, cycs):
        parts = [[] for _ in cycs]
        k = 0
        for c, ad, d in ws:
            while c >= cycs[k]:
                k += 1
            parts[k].append((ad, d))
        return parts
    pa, pb = split(wa, cyc_a), split(wb, cyc_b)
    nint_bad = 0
    for i in range(len(pa)):
        if pa[i] != pb[i]:
            nint_bad += 1
            j = next((t for t in range(min(len(pa[i]), len(pb[i]))) if pa[i][t] != pb[i][t]),
                     min(len(pa[i]), len(pb[i])))
            before = 'start' if i == 0 else na[i - 1]
            after = na[i] if i < k_ok else 'end'
            l1_bad.append('SRAM writes between %s and %s: %d / %d changing writes, first difference at write %d: '
                          'A %s, B %s' % (before, after, len(pa[i]), len(pb[i]), j, pa[i][j:j + 2], pb[i][j:j + 2]))
    log('L1 value-changing SRAM writes: A %d, B %d, %d of %d intervals differ' % (len(wa), len(wb), nint_bad,
                                                                                  len(pa)))
    # pictures: RAM and frames
    font = open(a.font, 'rb').read() if a.font else None
    sa = sb = {}
    try:
        sa, oa = frames.read_snaps(os.path.join(A, 'simout', 'snaps.txt'))
        sb, ob = frames.read_snaps(os.path.join(B, 'simout', 'snaps.txt'))
    except (IOError, ValueError) as e:
        l1_bad.append('snaps: %s' % e)
        oa = ob = []
    if oa != ob:
        l1_bad.append('snap names differ: A %s, B %s' % (oa, ob))
    if font is not None and oa:
        import render
        frame_diff.src = render.read_path()
    for n in [x for x in oa if x in sb]:
        ra = read_hex(os.path.join(A, 'simout', 'ram_%s.hex' % n))
        rb = read_hex(os.path.join(B, 'simout', 'ram_%s.hex' % n))
        r = ram_diff(ra, rb)
        if r:
            l1_bad.append('RAM at picture %s: %s' % (n, r))
        d, note = frame_diff(sa[n], sb[n], ra, rb, font)
        log('L1 frame %s: A frame %d (cycle %d), B frame %d (cycle %d); %d dots differ (%s)'
            % (n, sa[n].frame, sa[n].start, sb[n].frame, sb[n].start, len(d), note))
        if d:
            ys = sorted(set(y for _, y in d))
            l1_bad.append('frame %s: %d dots differ on %d lines (first %s)' % (n, len(d), len(ys), d[:4]))
    # cycle shift (informative)
    shifts = ['%s %+d' % (na[i], eb[i][0] - ea[i][0]) for i in range(k_ok)]
    log('L1 cycle shift B - A at the events (informative): %s' % ', '.join(shifts))
    for x in l1_bad:
        log('L1 difference: %s' % x)
    l1_same = not l1_bad
    log('L1 %s' % ('EQUAL' if l1_same else 'DIFFERS (%d findings)' % len(l1_bad)))
    log('')
    if a.expect == 'identical':
        ok = l0_same
        log('COMPARE %s (expected L0 identical)' % ('PASS' if ok else 'FAIL'))
    else:
        ok = (not l0_same) and (not l1_same)
        log('COMPARE %s (expected L0 and L1 to differ: the seeded calibration)' % ('PASS' if ok else 'FAIL'))
    return finish(0 if ok else 1)


if __name__ == '__main__':
    sys.exit(main())
