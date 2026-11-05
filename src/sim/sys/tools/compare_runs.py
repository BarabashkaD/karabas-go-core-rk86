"""L0 / L1 comparison of two system-simulation runs (plan Task 5, amendments A1, A2).

Usage: python -B compare_runs.py <result A> <result B> --out <dir> [--font FONT.BIN] [--board-vh board_go.vh]
       [--self-compare] [--expect identical|differ|differ-l0] [--expect-window <first>..<last>]
       [--allow-fail A|B ...] [--tb-equiv-repo <repo>] [--detail-a <result> --detail-b <result>]
<result A/B>: build/sim/sys/out/<run-id>/<board>-<sha7>[-<tag>] of the two revisions, the same board and TB
revision, each generated in compare mode (gen_sim --compare: the .syr of the revision, no POWER-UP DIFFERS /
UNCOMPARED). Writes <dir>/compare.txt (also printed).

Stand checks first; a failure anywhere is "STAND ERROR", exit status 2, no verdict:
- per side: summary.txt has every section (FSM ENCODINGS, COMPARE MODE, SEEDED CHANGES, RTL FILES OF THE
  REVISION, SIM COPIES AND ROM IMAGES OF THE WORK TREE, PERF, HOST CHECKS), compare mode, no FSM UNCOMPARED /
  DIFFERS, RUN VERDICT PASS (HOST CHECKS); --allow-fail A|B accepts another verdict only on a seeded side or a
  STOP_AT run (tb RESULT ... STOPPED); sim.log has TB_CYCLES, trace.txt has exactly ceil(TB_CYCLES / 4096)
  windows numbered 0.. (A1: 16 hex digit hashes), events.txt ends with basic_end at TB_CYCLES (a STOP_AT run:
  stopped at STOP_AT = TB_CYCLES on both sides instead); the L1 inputs exist (events.txt, sram_wr.txt, snaps.txt,
  ev_<n>_<name>.hex of every numbered event, ram_<snap>.hex of every snap).
- the pair: two different directories, the same board and TB revision, RTL not byte-identical (A2) unless
  --self-compare; a seeded side only with --self-compare. --self-compare: the same revision, byte-identical RTL,
  seeded changes on exactly one side, and the SIM COPIES AND ROM IMAGES hashes differ in exactly the files of
  the seeded changes. A stored peer list (RTL FILES OF THE PEER REVISION of a run generated for another
  comparison and reused here) is not used: the RTL of the two sides is compared from their own summaries, a
  stored peer that is not the other side is flagged. --tb-equiv-repo: different TB revisions are accepted only
  in a self-compare and only when `git diff` of the two TB revisions changes nothing under src/sim/sys except
  gen/, tools/, maps/ and *.md (the generator changes are covered by the sim-copy check).
- detail runs (--detail-a / --detail-b): their summary.txt / sim.log must match their side (revision, TB
  revision, seeded changes) and the first differing window (tb RESULT STOPPED at STOP_AT = last cycle + 1,
  TRACE_FROM / TRACE_TO cover the window).

L0: trace.txt window by window (the hash of every change of the observed pins, the change count, the counted
pins). On the first differing window it prints the plusargs of a detail run of both revisions
(+TRACE_FROM / +TRACE_TO / +STOP_AT); with --detail-a / --detail-b (simout/trace_detail.txt) it finds the first
differing cycle and the differing pins (named after GO_OBS of board_go.vh), and the first cycle where a DUT
output pin differs (the TB-driven pins of the vector, "L0 TB-DRIVEN" in board_go.vh, excluded).
L1 (event-aligned): the sequence of event names (simout/events.txt; the echo lines without their time); the
RAM 0000-7FFF at every event (simout/ev_<n>_<name>.hex) and at every picture (ram_<snap>.hex); the
value-changing SRAM writes (address, value; no time) between consecutive events (simout/sram_wr.txt); the
snapped frames (visible 800 x 600, the cursor cell masked: the dots that depend on frame[3] in the reference
rendering of either side, tools/render.py, needs --font). Frame numbers and cycles are not compared; the
cycle shift at each event is informative. L1 differing while L0 is identical is a stand error (every L1 input
derives from observed pins or TB stimulus that is itself in the vector).

Sensitivity: L0 resolves one 40 MHz cycle (the reference clock V_CLK) on the observed pins, sampled at its
falling edge. A change inside the design that never reaches an observed pin (or changes a pin only between
two samples) is invisible to L0. L1 ignores timing by design: a pure timing change is seen by L0 only.

Verdict lines: "L0 IDENTICAL|DIFFERS", "L1 EQUAL|DIFFERS", and "COMPARE PASS|FAIL" for --expect (identical:
L0 identical and L1 equal; differ: L0 and L1 both differ, a data seed; differ-l0: L0 differs, L1 informative,
a timing seed). --expect-window <first>..<last> (window numbers or event names of side A, inclusive): the
first differing L0 window must fall in it; mandatory for a differ expectation in a self-compare (A2: the seed
is caught where it is expected, not by an unrelated difference). Exit status 0 = PASS, 1 = FAIL, 2 = stand.
"""
import argparse
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import frames  # noqa: E402

WIN = 4096
REQUIRED = ('FSM ENCODINGS', 'COMPARE MODE', 'SEEDED CHANGES', 'RTL FILES OF THE REVISION',
            'SIM COPIES AND ROM IMAGES OF THE WORK TREE', 'PERF', 'HOST CHECKS')
TB_NOT_HDL = re.compile(r'^src/sim/sys/(gen/|tools/|maps/|[^/]*\.md$)')


class StandError(Exception):
    pass


def shown(path):
    """A path for the report without the host part: from the run id under out/, else its last 3 components."""
    p = os.path.abspath(path).replace(os.sep, '/')
    return p.split('/out/')[-1] if '/out/' in p else '/'.join(p.split('/')[-3:])


def read_lines(path):
    if not os.path.isfile(path):
        raise StandError('%s missing' % shown(path))
    with open(path) as f:
        return [ln.rstrip('\n') for ln in f]


def summary_info(res):
    sm = read_lines(os.path.join(res, 'summary.txt'))
    info = {'compare': False, 'rtl': [], 'board': None, 'tb': None, 'rev': None, 'seeds': [], 'seed_files': [],
            'fsm_bad': [], 'run': None, 'sections': set(), 'sim': {}, 'peer': None, 'syr': None, 'result': None,
            'stop_at': None}
    sec = None
    for ln in sm:
        if ln.strip() and not ln.startswith(' '):
            sec = re.split(r' \(|:', ln, maxsplit=1)[0].strip()
            info['sections'].add(sec)
            m = re.match(r'^RTL FILES OF THE PEER REVISION \(sha256; --peer-rev (\S+)\)', ln)
            if m:
                info['peer'] = m.group(1)
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
        if sec == 'SEEDED CHANGES' and ln.startswith('  #'):
            info['seeds'].append(ln.strip())
            m = re.match(r'^\s+#\w+ (\S+): SEEDED CHANGE (\w+)', ln)
            if not m:
                raise StandError('%s: seeded change line not understood: %r' % (res, ln.strip()))
            f = m.group(1)
            info['seed_files'].append(f if f.startswith('roms/') else 'sim/' + f)
        if sec == 'FSM ENCODINGS':
            if ln.startswith('  --syr sha256'):
                info['syr'] = ln.strip()
            elif 'UNCOMPARED' in ln or 'DIFFERS' in ln:
                info['fsm_bad'].append(ln.strip())
        if sec == 'SIM COPIES AND ROM IMAGES OF THE WORK TREE' and ln.startswith('  '):
            f = ln.split()
            if len(f) == 2:
                info['sim'][f[1]] = f[0]
        if sec == 'PERF':
            m = re.match(r'^\s+tb RESULT \w+ (\w+)(?: at \+STOP_AT=(\d+))?', ln)
            if m:
                info['result'] = m.group(1)
                if m.group(1) == 'STOPPED':
                    info['stop_at'] = int(m.group(2))
        if sec == 'HOST CHECKS':
            m = re.match(r'^\s+RUN VERDICT (\w+)\s*$', ln)
            if m:
                info['run'] = m.group(1)
    return info


def sim_log_info(res):
    """TB_CYCLES and the plusargs of the run (sim.log)."""
    cyc, plus = None, {}
    for ln in read_lines(os.path.join(res, 'sim.log')):
        m = re.match(r'^TB_CYCLES (\d+)\s*$', ln)
        if m:
            cyc = int(m.group(1))
        if ln.startswith('Running:'):
            plus = dict(re.findall(r'-testplusarg (\w+)=(\S+)', ln))
    return cyc, plus


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


def tb_driven_mask(board_vh, fields):
    """Bit mask of the TB-driven pins of the observed vector (comment "L0 TB-DRIVEN: ..." of board_go.vh)."""
    m = re.search(r'L0 TB-DRIVEN:\s*([^\n]*)', open(board_vh).read())
    if not m:
        raise StandError('%s: no "L0 TB-DRIVEN:" line (the TB stimulus pins of the observed vector)' % board_vh)
    pos, where = sum(w for _, w in fields), {}
    for nm, w in fields:
        pos -= w
        where[nm] = (pos, w)
    mask = 0
    for t in [x.strip() for x in m.group(1).split(',') if x.strip()]:
        mm = re.match(r'^(\w+)(?:\[(\d+)\])?$', t)
        if not mm or mm.group(1) not in where:
            raise StandError('%s: L0 TB-DRIVEN pin %r is not a field of GO_OBS' % (board_vh, t))
        p, w = where[mm.group(1)]
        mask |= (1 << (p + int(mm.group(2)))) if mm.group(2) is not None else (((1 << w) - 1) << p)
    return mask


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


def detail_diff(da, db, lo, hi, mask=None):
    """First cycle in [lo, hi] where the two detail traces differ: (cycle, value A, value B) or None.
    mask: only these bits of the vector (value, X mask, Z mask) count; None: every bit and every change."""
    ma = dict((x[0], x[1:]) for x in da if lo <= x[0] <= hi)
    mb = dict((x[0], x[1:]) for x in db if lo <= x[0] <= hi)
    pa = pb = None
    for c in sorted(set(ma) | set(mb)):
        va = ma.get(c, pa)
        vb = mb.get(c, pb)
        if mask is None:
            if va != vb or (c in ma) != (c in mb):
                if va is None or vb is None:
                    va = va if va is not None else vb
                    vb = vb if vb is not None else va
                return c, va, vb
        elif va is not None and vb is not None and any((x ^ y) & mask for x, y in zip(va, vb)):
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


def side_checks(nm, res, i, allow_fail, log):
    """Stand checks of one side; returns its loaded L0 / L1 inputs."""
    miss = [s for s in REQUIRED if s not in i['sections']]
    if miss:
        raise StandError('%s: summary.txt has no section %s' % (nm, ', '.join(miss)))
    if None in (i['board'], i['rev'], i['tb']):
        raise StandError('%s: summary.txt has no board / revision line' % nm)
    if not i['compare']:
        raise StandError('%s was not generated in compare mode (gen_sim --compare with --syr)' % nm)
    if i['fsm_bad']:
        raise StandError('%s: FSM encodings not equal to the table: %s' % (nm, i['fsm_bad']))
    if i['run'] is None:
        raise StandError('%s: no RUN VERDICT in the section HOST CHECKS (host checks not run)' % nm)
    if i['run'] != 'PASS':
        if not allow_fail:
            raise StandError('%s: RUN VERDICT %s: a comparison needs RUN VERDICT PASS on both sides (--allow-fail %s '
                             'only for a seeded side or a STOP_AT detail run)' % (nm, i['run'], nm))
        if not i['seeds'] and i['stop_at'] is None:
            raise StandError('%s: --allow-fail %s refused: RUN VERDICT %s and the side is neither seeded nor a STOP_AT '
                             'run' % (nm, nm, i['run']))
        log('%s: RUN VERDICT %s accepted by --allow-fail %s (%s)' % (nm, i['run'], nm, 'seeded side' if i['seeds']
                                                                      else 'STOP_AT %d run' % i['stop_at']))
    cyc, plus = sim_log_info(res)
    if not cyc:
        raise StandError('%s: sim.log has no TB_CYCLES line (the run did not reach its end)' % nm)
    trace = read_trace(res)
    want = -(-cyc // WIN)
    if len(trace) != want:
        raise StandError('%s: trace.txt has %d windows, TB_CYCLES %d needs ceil(%d / %d) = %d' % (nm, len(trace), cyc,
                                                                                               cyc, WIN, want))
    for k, w in enumerate(trace):
        if w[0] != k or w[1] != k * WIN:
            raise StandError('%s: trace.txt line %d is window %d at cycle %d, expected window %d at cycle %d'
                             % (nm, k + 1, w[0], w[1], k, k * WIN))
    events = read_events(res)
    names = [e[1] for e in events]
    if i['stop_at'] is not None:
        if i['stop_at'] != cyc:
            raise StandError('%s: stopped at STOP_AT %d, TB_CYCLES %d' % (nm, i['stop_at'], cyc))
    elif not names or names[-1] != 'basic_end':
        raise StandError('%s: events.txt does not end with basic_end (the chain did not end; last event %s)'
                         % (nm, names[-1] if names else 'none'))
    elif events[-1][0] != cyc:
        raise StandError('%s: basic_end at cycle %d, TB_CYCLES %d' % (nm, events[-1][0], cyc))
    writes = read_writes(res)
    dumps, k = [], 0
    for _, n in events:
        if n.startswith('echo '):
            continue
        f = 'ev_%d_%s.hex' % (k, n)
        if not os.path.isfile(os.path.join(res, 'simout', f)):
            raise StandError('%s: simout/%s missing (the RAM dump of event %d)' % (nm, f, k))
        dumps.append(f)
        k += 1
    extra = sorted(set(f for f in os.listdir(os.path.join(res, 'simout')) if re.match(r'^ev_\d+_.*\.hex$', f))
                   - set(dumps))
    if extra:
        raise StandError('%s: RAM dumps without an event in events.txt: %s' % (nm, ', '.join(extra)))
    p = os.path.join(res, 'simout', 'snaps.txt')
    if not os.path.isfile(p):
        raise StandError('%s: simout/snaps.txt missing' % nm)
    try:
        snaps, order = frames.read_snaps(p)
    except (IOError, ValueError) as e:
        raise StandError('%s: snaps: %s' % (nm, str(e).replace(p, shown(p))))
    for n in order:
        if not os.path.isfile(os.path.join(res, 'simout', 'ram_%s.hex' % n)):
            raise StandError('%s: simout/ram_%s.hex missing (the RAM of picture %s)' % (nm, n, n))
    log('%s: TB_CYCLES %d, %d windows, %d events (%s), %d RAM dumps, snaps %s'
        % (nm, cyc, len(trace), len(events), 'stopped at STOP_AT' if i['stop_at'] is not None else 'basic_end',
           len(dumps), ', '.join(order) or 'none'))
    return {'cyc': cyc, 'trace': trace, 'events': events, 'writes': writes, 'dumps': dumps, 'snaps': snaps,
            'order': order}


def tb_equiv(repo, ta, tb):
    """Files of the TB (src/sim/sys without gen/, tools/, maps/, *.md) changed between two TB revisions."""
    p = subprocess.run(['git', '-C', repo, 'diff', '--name-only', ta, tb, '--', 'src/sim/sys'],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode:
        raise StandError('--tb-equiv-repo: git diff %s %s failed: %s' % (ta[:7], tb[:7],
                                                                      p.stdout.decode('utf-8', 'replace').strip()))
    files = [x for x in p.stdout.decode('utf-8', 'replace').split('\n') if x.strip()]
    return [x for x in files if not TB_NOT_HDL.match(x)], [x for x in files if TB_NOT_HDL.match(x)]


def detail_check(nm, res, side, lo, hi):
    """A detail run must belong to its side and to the first differing window."""
    d = summary_info(res)
    cyc, plus = sim_log_info(res)
    bad = []
    for key, what in (('rev', 'revision'), ('tb', 'TB revision'), ('board', 'board')):
        if d[key] != side[key]:
            bad.append('%s %s, side %s' % (what, d[key], side[key]))
    if d['seeds'] != side['seeds']:
        bad.append('seeded changes %s, side %s' % (d['seeds'] or 'none', side['seeds'] or 'none'))
    if d['result'] != 'STOPPED' or d['stop_at'] != hi + 1:
        bad.append('tb RESULT %s STOP_AT %s, expected STOPPED at STOP_AT %d' % (d['result'], d['stop_at'], hi + 1))
    if cyc != hi + 1:
        bad.append('TB_CYCLES %s, expected %d' % (cyc, hi + 1))
    try:
        tf, tt = int(plus.get('TRACE_FROM', -1)), int(plus.get('TRACE_TO', -1))
    except ValueError:
        tf = tt = -1
    if not (0 <= tf <= lo and tt >= hi):
        bad.append('TRACE_FROM %s / TRACE_TO %s do not cover the window %d..%d' % (plus.get('TRACE_FROM'),
                                                                                plus.get('TRACE_TO'), lo, hi))
    if bad:
        raise StandError('detail run %s (%s) does not match side %s and the window: %s'
                         % (nm, shown(res), nm[-1], '; '.join(bad)))


def parse_window(spec, events):
    """<first>..<last>: window numbers or event names (of side A) -> (first window, last window)."""
    m = re.match(r'^([^.]+)\.\.([^.]+)$', spec or '')
    if not m:
        raise StandError('--expect-window %r: expected <first>..<last>' % spec)
    out = []
    for t in m.groups():
        if re.match(r'^\d+$', t):
            out.append(int(t))
        else:
            c = next((e[0] for e in events if e[1] == t), None)
            if c is None:
                raise StandError('--expect-window: no event %s on side A' % t)
            out.append(c // WIN)
    if out[0] > out[1]:
        raise StandError('--expect-window %s: windows %d..%d are empty' % (spec, out[0], out[1]))
    return out[0], out[1]


def compare(a, log):
    A, B = os.path.abspath(a.a), os.path.abspath(a.b)
    log('COMPARE A %s' % shown(A))
    log('COMPARE B %s' % shown(B))
    if os.path.normcase(os.path.realpath(A)) == os.path.normcase(os.path.realpath(B)):
        raise StandError('A and B are the same directory')
    allow = set(x.upper() for x in (a.allow_fail or []))
    ia, ib = summary_info(A), summary_info(B)
    for nm, i in (('A', ia), ('B', ib)):
        log('%s: revision %s, board %s, TB %s, compare mode %s, seeded %s, run verdict %s'
            % (nm, i['rev'], i['board'], i['tb'], 'yes' if i['compare'] else 'NO', i['seeds'] or 'none',
               i['run'] or '?'))
        log('%s: %s' % (nm, i['syr'] or '--syr sha256 / bin check not recorded (summary of an older gen_sim)'))
    sa = side_checks('A', A, ia, 'A' in allow, log)
    sb = side_checks('B', B, ib, 'B' in allow, log)
    if ia['board'] != ib['board']:
        raise StandError('different boards: %s / %s' % (ia['board'], ib['board']))
    if ia['tb'] != ib['tb']:
        if not a.tb_equiv_repo:
            raise StandError('different TB revisions: %s / %s' % (ia['tb'], ib['tb']))
        if not a.self_compare:
            raise StandError('different TB revisions %s / %s: --tb-equiv-repo is accepted only in a self-compare'
                             % (ia['tb'][:7], ib['tb'][:7]))
        hdl, other = tb_equiv(a.tb_equiv_repo, ia['tb'], ib['tb'])
        if hdl:
            raise StandError('TB revisions %s / %s differ in TB files: %s' % (ia['tb'][:7], ib['tb'][:7],
                                                                           ', '.join(hdl)))
        log('TB revisions %s / %s: no TB file changed (git diff; changed outside the TB: %s); the sim copies are '
            'checked below' % (ia['tb'][:7], ib['tb'][:7], ', '.join(other) or 'none'))
    if (ia['stop_at'] is None) != (ib['stop_at'] is None) or ia['stop_at'] != ib['stop_at']:
        raise StandError('STOP_AT %s / %s: both sides must run to the same end' % (ia['stop_at'], ib['stop_at']))
    for nm, i, other in (('A', ia, ib), ('B', ib, ia)):
        if i['peer']:
            same = other['rev'] and i['peer'].endswith(other['rev'][:7])
            log('%s: stored peer list (--peer-rev %s) not used%s' % (
                nm, i['peer'], '' if same else '; FLAG: the stored peer is not side %s (%s): this run was generated '
                'for another comparison' % ('B' if nm == 'A' else 'A', (other['rev'] or '?')[:7])))
    same_rtl = sorted(ia['rtl']) == sorted(ib['rtl'])
    if (ia['seeds'] or ib['seeds']) and not a.self_compare:
        raise StandError('a seeded side (%s) needs --self-compare' % ('A' if ia['seeds'] else 'B'))
    if same_rtl and not a.self_compare:
        raise StandError('the two revisions have byte-identical RTL (%d files): refused (A2); --self-compare '
                         'for an explicit self-compare' % len(ia['rtl']))
    ha = dict(x.split('  ')[::-1] for x in ia['rtl'])
    hb = dict(x.split('  ')[::-1] for x in ib['rtl'])
    dk = sorted(k for k in set(ha) | set(hb) if ha.get(k) != hb.get(k))
    if a.self_compare:
        if not same_rtl or ia['rev'] != ib['rev']:
            raise StandError('--self-compare needs one revision with byte-identical RTL on both sides (%s / %s, %d '
                             'RTL files differ)' % (ia['rev'][:7], ib['rev'][:7], len(dk)))
        if bool(ia['seeds']) == bool(ib['seeds']):
            raise StandError('--self-compare needs seeded changes on exactly one side (A %d, B %d)'
                             % (len(ia['seeds']), len(ib['seeds'])))
        seeded = ia if ia['seeds'] else ib
        sd = sorted(k for k in set(ia['sim']) | set(ib['sim']) if ia['sim'].get(k) != ib['sim'].get(k))
        if not sd:
            raise StandError('--self-compare: the SIM COPIES AND ROM IMAGES hashes of A and B are equal: the seeded '
                             'change is not in the work tree')
        if sd != sorted(set(seeded['seed_files'])):
            raise StandError('--self-compare: the sim copies differ in %s, the seeded changes are in %s'
                             % (', '.join(sd), ', '.join(sorted(set(seeded['seed_files'])))))
        log('self-compare: seeded side %s; the sim copies differ exactly in the seeded files: %s'
            % ('A' if ia['seeds'] else 'B', ', '.join(sd)))
    log('RTL: %s' % ('byte-identical (%d files), explicit self-compare' % len(ha) if same_rtl else
                     '%d files differ or exist on one side only: %s' % (len(dk), ', '.join(dk))))
    differ_expect = a.expect in ('differ', 'differ-l0')
    if a.expect_window and not differ_expect:
        raise StandError('--expect-window needs --expect differ or differ-l0')
    if a.self_compare and differ_expect and not a.expect_window:
        raise StandError('--expect %s in a self-compare needs --expect-window (where the seed must be caught)'
                         % a.expect)
    win = parse_window(a.expect_window, sa['events']) if a.expect_window else None
    ta, tb = sa['trace'], sb['trace']

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
            if bool(a.detail_a) != bool(a.detail_b):
                raise StandError('--detail-a and --detail-b go together')
            if a.detail_a:
                detail_check('detail-A', os.path.abspath(a.detail_a), ia, lo, hi)
                detail_check('detail-B', os.path.abspath(a.detail_b), ib, lo, hi)
                log('L0 detail: the detail runs match their sides (revision, TB revision, seeds) and the window '
                    '(STOP_AT %d, TRACE_FROM..TRACE_TO cover %d..%d)' % (hi + 1, lo, hi))
                da, db = read_detail(a.detail_a), read_detail(a.detail_b)
                fields = obs_fields(a.board_vh)
                dut_mask = ((1 << sum(w for _, w in fields)) - 1) & ~tb_driven_mask(a.board_vh, fields)
                dd = detail_diff(da, db, lo, hi)
                if dd is None:
                    log('L0 detail: no difference in cycles %d..%d of the detail traces' % (lo, hi))
                else:
                    c, va, vb = dd
                    names = bits_to_fields((va[0] ^ vb[0]) | (va[1] ^ vb[1]) | (va[2] ^ vb[2]), fields)
                    log('L0 detail: first differing cycle %d (window offset %d); differing pins: %s'
                        % (c, c - lo, ', '.join(names)))
                    log('L0 detail: values A %x / B %x (X mask A %x / B %x)' % (va[0], vb[0], va[1], vb[1]))
                    do = detail_diff(da, db, lo, hi, dut_mask)
                    if do is None:
                        log('L0 detail: no DUT output pin differs in cycles %d..%d (only TB-driven pins)' % (lo, hi))
                    else:
                        c2, va2, vb2 = do
                        log('L0 detail: first differing DUT output pin at cycle %d (window offset %d): %s'
                            % (c2, c2 - lo, ', '.join(bits_to_fields(
                                ((va2[0] ^ vb2[0]) | (va2[1] ^ vb2[1]) | (va2[2] ^ vb2[2])) & dut_mask, fields))))

    # ---- L1
    log('')
    ea, eb = sa['events'], sb['events']
    na, nb = [e[1] for e in ea], [e[1] for e in eb]
    l1_bad = []
    if na != nb:
        k = next((i for i in range(min(len(na), len(nb))) if na[i] != nb[i]), min(len(na), len(nb)))
        l1_bad.append('event sequence differs at event %d: A %s, B %s' % (k, na[k:k + 2], nb[k:k + 2]))
    common = min(len(ea), len(eb))
    k_ok = next((i for i in range(common) if na[i] != nb[i]), common)
    log('L1 events: A %d, B %d; equal names up to event %d' % (len(ea), len(eb), k_ok))
    # RAM at the events (the TB numbers every mark_event; the echo lines are not mark_events)
    dumps_a, dumps_b = sa['dumps'], set(sb['dumps'])
    for f in dumps_a:
        r = ram_diff(read_hex(os.path.join(A, 'simout', f)), read_hex(os.path.join(B, 'simout', f))
                     if f in dumps_b else None)
        if r:
            l1_bad.append('RAM at %s: %s' % (f[:-4], r))
    for f in sorted(dumps_b - set(dumps_a)):
        l1_bad.append('RAM at %s: missing on A' % f[:-4])
    log('L1 RAM dumps at events: %d on A, %d on B' % (len(dumps_a), len(dumps_b)))
    # value-changing SRAM writes between consecutive events
    wa, wb = sa['writes'], sb['writes']
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
    sna, oa, snb, ob = sa['snaps'], sa['order'], sb['snaps'], sb['order']
    if oa != ob:
        l1_bad.append('snap names differ: A %s, B %s' % (oa, ob))
    if font is not None and oa:
        import render
        frame_diff.src = render.read_path()
    for n in [x for x in oa if x in snb]:
        ra = read_hex(os.path.join(A, 'simout', 'ram_%s.hex' % n))
        rb = read_hex(os.path.join(B, 'simout', 'ram_%s.hex' % n))
        r = ram_diff(ra, rb)
        if r:
            l1_bad.append('RAM at picture %s: %s' % (n, r))
        try:
            d, note = frame_diff(sna[n], snb[n], ra, rb, font)
        except ValueError as e:
            raise StandError('frame %s: %s' % (n, e))
        log('L1 frame %s: A frame %d (cycle %d), B frame %d (cycle %d); %d dots differ (%s)'
            % (n, sna[n].frame, sna[n].start, snb[n].frame, snb[n].start, len(d), note))
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
    if l0_same and not l1_same:
        raise StandError('L1 differs while L0 is identical: the L1 inputs do not belong to the traced runs (every '
                         'L1 input derives from observed pins or from TB stimulus in the vector)')
    if a.expect == 'identical':
        ok = l0_same and l1_same
        log('COMPARE %s (expected L0 identical and L1 equal)' % ('PASS' if ok else 'FAIL'))
        return 0 if ok else 1
    if a.expect == 'differ':
        ok = (not l0_same) and (not l1_same)
        what = 'expected L0 and L1 to differ: the seeded calibration'
    else:
        ok = not l0_same
        what = 'expected L0 to differ, L1 informative: a timing seed'
    if win is not None and not l0_same:
        inside = win[0] <= first <= win[1]
        log('L0 first differing window %d %s the expected windows %d..%d (--expect-window %s)'
            % (first, 'inside' if inside else 'OUTSIDE', win[0], win[1], a.expect_window))
        ok = ok and inside
    log('COMPARE %s (%s)' % ('PASS' if ok else 'FAIL', what))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description='L0 / L1 comparison of two system-simulation runs')
    ap.add_argument('a')
    ap.add_argument('b')
    ap.add_argument('--out', required=True)
    ap.add_argument('--font', help='FONT.BIN for the cursor mask of the frames')
    ap.add_argument('--board-vh', default=os.path.join(HERE, '..', 'board_go.vh'))
    ap.add_argument('--self-compare', action='store_true')
    ap.add_argument('--expect', choices=('identical', 'differ', 'differ-l0'), default='identical')
    ap.add_argument('--expect-window', help='<first>..<last>: window numbers or event names of side A')
    ap.add_argument('--allow-fail', action='append', choices=('A', 'B', 'a', 'b'),
                    help='accept a RUN VERDICT other than PASS on this side (a seeded side or a STOP_AT run only)')
    ap.add_argument('--tb-equiv-repo', help='repository for git diff of two different TB revisions (self-compare)')
    ap.add_argument('--detail-a')
    ap.add_argument('--detail-b')
    a = ap.parse_args()
    lines = []

    def log(s=''):
        print(s)
        lines.append(s)

    try:
        code = compare(a, log)
    except StandError as e:
        log('STAND ERROR: %s' % e)
        log('COMPARE FAIL (stand)')
        code = 2
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, 'compare.txt'), 'w', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    return code


if __name__ == '__main__':
    sys.exit(main())
