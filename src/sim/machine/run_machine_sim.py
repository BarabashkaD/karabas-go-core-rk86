#!/usr/bin/env python3
"""Builds and runs the iverilog testbench of the clock enable (ce) and the CPU memory ready
(cpu_ready) of rk86_machine and rk86_video (src/sim/machine/tb_rk86_machine.v; docs/contract.md,
sections rk86_machine and rk86_video) and compares the traces of the runs.

Usage, from any directory:
    python -B src/sim/machine/run_machine_sim.py [--iverilog PATH] [--frames N] [--jobs N]
        [--seed N] [--ref-rev REV] [--negative] [--self-test]
--iverilog   the iverilog program (default: iverilog on PATH); vvp is taken from its directory
--frames     native frames per run (default 12: with ce = 1 the BIOS reaches its keyboard loop
             in frame 6, with the stalls later; the last two frames are compared after stalls)
--jobs       runs in parallel (default 6)
--seed       the seed of the pseudo-random clock enable and of the stalls (default 1)
--ref-rev    also run "ref": the machine with ce = 1 and cpu_ready = 1 against rk86_machine.v and
             rk86_video.v of the git revision REV (before the clock enable), every clk
--negative   also run the broken variants of the gating (NEGATIVE below); each must fail
--self-test  check the trace comparison on made-up traces and exit
Runs: g (ce = 1, synchronous memory), frac (ce on 160 of 297 clk), random (pseudo-random ce),
stall (ce = 1, random stalls of the memory), stall_frac (ce 160 of 297 and stalls),
stall_realign (ce = 1, stalls, and a pending step held to the realign edge after hlda, so that a
step comes 1 ce cycle after a waited one) [, ref].
frac and random must write the traces of g line by line; the stall runs must give the bus
transactions of g apart from the status poll of the BIOS (normalize) and the dots and DMA cycles
of g in the last two frames; ref must write the traces of g.
The build goes to build/sim/machine/ (ignored by git).
Exit code 0 when every run and comparison passes and every negative run fails, 1 otherwise,
2 when a tool is missing or a build fails.
"""
import argparse
import concurrent.futures
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
TOP = 'tb_rk86_machine'
TB = 'src/sim/machine/tb_rk86_machine.v'
RTL = ['src/rtl/rk86_machine.v', 'src/rtl/rk86_video.v', 'src/rtl/rk86_video_stream.v',
       'src/rtl/k580wm80a.v', 'src/rtl/k580wt57.v', 'src/rtl/k580wg75.v', 'src/rtl/k580ww55.v']
BIOS = 'src/roms/BIOS.BIN'
FONT = 'src/roms/FONT.BIN'
OUT = os.path.join('build', 'sim', 'machine')
RUNS = {
    'g': {'CE_MODE': 0},
    'frac': {'CE_MODE': 1},
    'random': {'CE_MODE': 2},
    'stall': {'CE_MODE': 0, 'STALL': 1},
    'stall_frac': {'CE_MODE': 1, 'STALL': 1},
    'stall_realign': {'CE_MODE': 0, 'STALL': 2},
}
REF = {'CE_MODE': 0, 'SYNC_MEM': 0}
NEGATIVE_FRAMES = 2
NEGATIVE = [  # (name, file, old, new, run, the ERROR it must give): the gating broken on purpose
    ('video_without_ce', 'src/rtl/rk86_video.v',
     'always @(posedge clk)\nif (ce)\nbegin', 'always @(posedge clk)\nbegin', 'frac',
     'a state changed on a clk edge with ce = 0'),
    ('cpu_cnt_without_ce', 'src/rtl/rk86_machine.v',
     '\telse if(ce) begin\n', '\telse begin\n', 'frac',
     'a state changed on a clk edge with ce = 0'),
    ('crt_write_without_hold', 'src/rtl/rk86_machine.v',
     'wire crt_we_ce = ce ? crt_we_n : crt_we_q;', 'wire crt_we_ce = crt_we_n;', 'frac',
     'CRT write edge on a clk with ce = 0'),
    ('ppi_write_without_ce', 'src/rtl/rk86_machine.v',
     'wire ppa1_we_ce = ppa1_we_n | ~ce;', 'wire ppa1_we_ce = ppa1_we_n;', 'frac',
     'PPI write on a clk with ce = 0'),
    ('cpu_step_without_ready', 'src/rtl/rk86_machine.v',
     'wire cpu_ce = cpu_ce2 & ce & cpu_ready;', 'wire cpu_ce = cpu_ce2 & ce;', 'stall',
     'CPU step without cpu_ready'),
    ('hold_removed', 'src/rtl/rk86_machine.v',
     '\t\tif(cpu_ce2 & ~cpu_ready) begin\n\t\t\t// the pending CPU step waits for cpu_ready\n\t\tend else\n', '', 'stall',
     'a wait ended without a CPU step'),
    ('dma_write_without_hold', 'src/rtl/rk86_machine.v',
     'wire dma_we_ce = ce ? dma_we_n : dma_we_q;', 'wire dma_we_ce = dma_we_n;', 'frac',
     'DMA write edge on a clk with ce = 0'),
    ('crt_read_without_hold', 'src/rtl/rk86_machine.v',
     'wire crt_rd_ce = ce ? crt_rd_n : crt_rd_q;', 'wire crt_rd_ce = crt_rd_n;', 'frac',
     'CRT read edge on a clk with ce = 0'),
    ('cce_without_ce', 'src/rtl/rk86_video.v',
     'assign cce = ce && d_cnt==3\'b000 && state == 2\'b01;', 'assign cce = d_cnt==3\'b000 && state == 2\'b01;', 'frac',
     'cce of rk86_video on a clk with ce = 0'),
    ('hldareg_without_ce', 'src/rtl/rk86_machine.v',
     '\tif(ce) hldareg <= {hldareg[9:0],hlda};', '\thldareg <= {hldareg[9:0],hlda};', 'frac',
     'a state changed on a clk edge with ce = 0'),
    ('startup_without_ce', 'src/rtl/rk86_machine.v',
     '\tif(reset|ce) startup <= reset|(startup&~addrbus[15]);', '\tstartup <= reset|(startup&~addrbus[15]);', 'frac',
     'a state changed on a clk edge with ce = 0'),
]
NEGATIVE_REF = ('cpu_period_27', 'src/rtl/rk86_machine.v', 'if(cpu_cnt < 27)', 'if(cpu_cnt < 26)', 'ref',
                'differs from the code before the clock enable')
# The status poll of the BIOS (FACE, after the CRT start): FAE0 MOV A,M reads the CRT status
# (C001) once, then FAE1-FAE6 (MOV A,M / ANI 20 / JZ FAE1) read it until bit 5 (irq: the end of
# the screen) is set. How many times depends on when the CPU gets there in the frame, so a stall
# changes the count; the transactions of one iteration:
POLL = ['fae1', 'c001', 'fae2', 'fae3', 'fae4', 'fae5', 'fae6']


def substitute(text, old, new, what):
    n = text.count(old)
    if n != 1:
        raise ValueError('%s: %r found %d times, expected once' % (what, old, n))
    return text.replace(old, new)


def prepare(out, mutant=None, ref_rev=None):
    """Writes the sources of one build into out/src: the RTL (with the
    mutant), the testbench, and for ref_rev the reference machine and video of that revision."""
    src = os.path.join(out, 'src')
    os.makedirs(src, exist_ok=True)
    paths = []
    for rel in [TB] + RTL:
        with open(os.path.join(ROOT, rel), encoding='utf-8', newline='') as f:
            text = f.read()
        if mutant and mutant[1] == rel:
            text = substitute(text, mutant[2], mutant[3], 'negative ' + mutant[0])
        path = os.path.join(src, os.path.basename(rel))
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(text)
        paths.append(path)
    if ref_rev:
        for rel, mod in (('src/rtl/rk86_machine.v', 'rk86_machine'), ('src/rtl/rk86_video.v', 'rk86_video')):
            res = subprocess.run(['git', '-C', ROOT, 'show', '%s:%s' % (ref_rev, rel)],
                                 capture_output=True, text=True, encoding='utf-8')
            if res.returncode:
                raise ValueError('git show %s:%s: %s' % (ref_rev, rel, res.stderr.strip()))
            text = substitute(res.stdout, 'module %s(' % mod, 'module %s_ref(' % mod, 'ref ' + rel)
            path = os.path.join(src, mod + '_ref.v')
            with open(path, 'w', encoding='utf-8', newline='') as f:
                f.write(text)
            paths.append(path)
    return paths


def build_and_run(tools, name, params, frames, seed, mutant=None, ref_rev=None):
    iverilog, vvp, env = tools
    out = os.path.join(ROOT, OUT, name)
    os.makedirs(out, exist_ok=True)
    for f in ('bus.txt', 'video.txt'):
        if os.path.exists(os.path.join(out, f)):
            os.remove(os.path.join(out, f))
    srcs = prepare(out, mutant, ref_rev)
    exe = os.path.join(out, TOP + '.vvp')
    p = dict(params, FRAMES=frames, SEED=seed)
    cmd = [iverilog, '-g2005', '-o', exe, '-s', TOP] + ['-P%s.%s=%d' % (TOP, k, v) for k, v in sorted(p.items())]
    if ref_rev:
        cmd.append('-DREF')
    res = subprocess.run(cmd + srcs, capture_output=True, text=True, env=env)
    text = (res.stdout + res.stderr).strip()
    if res.returncode:
        return name, None, 'iverilog exit %d\n%s' % (res.returncode, text)
    res = subprocess.run([vvp, '-n', exe, '+bios=' + os.path.join(ROOT, BIOS).replace(os.sep, '/'),
                          '+font=' + os.path.join(ROOT, FONT).replace(os.sep, '/'),
                          '+out=' + out.replace(os.sep, '/')], capture_output=True, text=True, env=env)
    text = (text + '\n' + res.stdout + res.stderr).strip()
    lines = [l.strip() for l in text.splitlines()]
    ok = res.returncode == 0 and 'RESULT: PASS' in lines and not any(l.startswith('ERROR') for l in lines)
    return name, ok, text


def load(path):
    with open(path) as f:
        return [l.split() for l in f if l.strip()]


def is_fetch(t, addr):
    # t: ce, status, address, data, R/W; status bit 5 = M1 (the opcode fetch)
    return t[2] == addr and int(t[1], 16) & 0x20 != 0 and t[4] == 'R'


def normalize(tr):
    """The bus transactions without the ce column, without the iterations of the status poll
    whose status has bit 5 clear, and with bit 5 (irq) of the status read at FAE0 masked (the
    other bits stay compared). A dropped iteration must read the status of the iteration that
    ends the poll apart from bit 5; each one that does not is listed in bad.
    Returns (list, dropped, bad)."""
    out, dropped, bad, pending, i = [], 0, [], [], 0
    while i < len(tr):
        t = tr[i]
        if is_fetch(t, 'fae1') and i + len(POLL) <= len(tr):
            it = tr[i:i + len(POLL)]
            if [x[2] for x in it] != POLL:
                raise ValueError('unexpected status poll at transaction %d: %s' % (i, [x[2] for x in it]))
            status = int(it[1][3], 16)
            if status & 0x20 == 0:
                dropped += 1
                pending.append((i, status))
                i += len(POLL)
                continue
            for k, s in pending:
                if s & ~0x20 != status & ~0x20:
                    bad.append('the dropped status poll iteration at transaction %d reads %02x, the read that ends the poll %02x'
                               % (k, s, status))
            pending = []
        if is_fetch(t, 'fae0') and i + 1 < len(tr) and tr[i + 1][2] == 'c001':
            out += [tuple(t[1:]), (tr[i + 1][1], 'c001', '%02x' % (int(tr[i + 1][3], 16) & ~0x20 & 0xFF), tr[i + 1][4])]
            i += 2
            continue
        out.append(tuple(t[1:]))
        i += 1
    for k, s in pending:
        bad.append('the dropped status poll iteration at transaction %d (status %02x) has no read that ends the poll' % (k, s))
    return out, dropped, bad


def same(name, a, b):
    """Equal files, line by line."""
    with open(a) as fa, open(b) as fb:
        la, lb = fa.read().splitlines(), fb.read().splitlines()
    d = next((k for k in range(min(len(la), len(lb))) if la[k] != lb[k]), None)
    if d is None and len(la) == len(lb):
        print('  %s: %d lines, equal' % (name, len(la)))
        return True
    print('ERROR: %s differs at line %s (%d / %d lines)' % (name, d, len(la), len(lb)))
    if d is not None:
        print('    %s\n    %s' % (la[d], lb[d]))
    return False


def compare_exact(g, r):
    ok = same('%s bus.txt' % r, os.path.join(ROOT, OUT, 'g', 'bus.txt'), os.path.join(ROOT, OUT, r, 'bus.txt'))
    return same('%s video.txt' % r, os.path.join(ROOT, OUT, 'g', 'video.txt'), os.path.join(ROOT, OUT, r, 'video.txt')) and ok


def compare_bus_stalled(g, s, name):
    gn, gd, gb = normalize(g)
    sn, sd, sb = normalize(s)
    ok = True
    print('  %s bus: %d / %d transactions (g / %s), status poll iterations dropped %d / %d, then %d / %d'
          % (name, len(g), len(s), name, gd, sd, len(gn), len(sn)))
    for who, b in (('g', gb), (name, sb)):
        if b:
            print('ERROR: %s: %s: %d dropped status poll iterations differ from the read that ends the poll; first: %s'
                  % (name, who, len(b), b[0]))
            ok = False
    n = min(len(gn), len(sn))
    d = next((k for k in range(n) if gn[k] != sn[k]), None)
    if d is not None:
        print('ERROR: %s: bus transaction %d after normalization differs: %s / %s' % (name, d, gn[d], sn[d]))
        ok = False
    raw = next((k for k in range(min(len(g), len(s))) if g[k][1:] != s[k][1:]), None)
    print('  %s bus without normalization: first difference at transaction %s' % (name, raw))
    kg = next((k for k, t in enumerate(gn) if t[1] == 'fe63' and int(t[0], 16) & 0x20 and t[3] == 'R'), -1)
    ks = next((k for k, t in enumerate(sn) if t[1] == 'fe63' and int(t[0], 16) & 0x20 and t[3] == 'R'), -1)
    print('  %s keyboard loop (fetch FE63) at normalized transaction %d / %d; %d transactions after it'
          % (name, kg, ks, len(sn) - ks))
    if kg < 0 or ks < 0 or len(sn) - ks < 1000:
        print('ERROR: %s: the keyboard loop is not reached, or fewer than 1000 transactions after it' % name)
        ok = False
    return ok


def compare_stall(name, frames):
    g = load(os.path.join(ROOT, OUT, 'g', 'bus.txt'))
    s = load(os.path.join(ROOT, OUT, name, 'bus.txt'))
    ok = compare_bus_stalled(g, s, name)
    gv = load(os.path.join(ROOT, OUT, 'g', 'video.txt'))
    sv = load(os.path.join(ROOT, OUT, name, 'video.txt'))
    if len(gv) != frames * 620 or len(sv) != frames * 620:
        print('ERROR: %s: video lines %d / %d, expected %d' % (name, len(gv), len(sv), frames * 620))
        return False
    # line: frame, line, ce cycle at its end, timebase hash, dot hash, DMA hash, lit dots, DMA reads
    tb = [k for k in range(len(gv)) if gv[k][:4] != sv[k][:4]]
    if tb:
        print('ERROR: %s: the timebase differs on %d lines, first %s' % (name, len(tb), gv[tb[0]][:2]))
        ok = False
    end = int([l for l in gv if int(l[0]) == frames - 4][-1][2])
    ceg = next(int(t[0]) for t in g if is_fetch(t, 'fe63'))
    ces = next((int(t[0]) for t in s if is_fetch(t, 'fe63')), None)
    print('  %s keyboard loop at ce cycle %s / %s; the end of frame %d at %d'
          % (name, ceg, ces, frames - 4, end))
    if ces is None or max(ceg, ces) > end:
        print('ERROR: %s: the keyboard loop starts after frame %d: run more frames' % (name, frames - 4))
        ok = False
    last = [k for k in range(len(gv)) if int(gv[k][0]) >= frames - 2]
    bad = [k for k in last if gv[k][4:] != sv[k][4:]]
    early = sum(1 for k in range(len(gv)) if int(gv[k][0]) < frames - 2 and gv[k][4:] != sv[k][4:])
    print('  %s video: last two frames %d lines, %d differ; earlier frames: %d lines differ (the CPU writes the screen at other times)'
          % (name, len(last), len(bad), early))
    if bad:
        print('ERROR: %s: the dots or the DMA cycles differ in the last two frames, first at %s' % (name, gv[bad[0]][:2]))
        ok = False
    return ok


def self_test():
    def t(ce, st, a, d):
        return [str(ce), st, a, d, 'R']

    def bus(polls, fae0=0x00, exit_status=0x64, after=None):
        tr = [t(1, 'a2', 'f800', 'c3'), t(2, '82', 'f801', '36'), t(3, 'a2', 'fae0', '7e'), t(4, '82', 'c001', '%02x' % fae0)]
        for k in range(polls + 1):
            s = exit_status if k == polls else 0x44
            tr += [t(5, 'a2', 'fae1', '7e'), t(6, '82', 'c001', '%02x' % s), t(7, 'a2', 'fae2', 'e6'),
                   t(8, '82', 'fae3', '20'), t(9, 'a2', 'fae4', 'ca'), t(10, '82', 'fae5', 'e1'), t(11, '82', 'fae6', 'fa')]
        tr += [t(12, 'a2', 'fae7', '21')]
        tr += [t(13 + k, 'a2', 'fe63', 'cd') if k == 0 else t(13 + k, '82', '7605', '%02x' % (k % 256)) for k in range(1200)]
        if after is not None:
            tr[after][3] = 'ff'
        return tr
    odd = bus(2)
    odd[5][3] = '4c'    # the first, dropped iteration: bit 3 differs from the read that ends the poll
    cases = [('poll counts and FAE0 status bit 5 differ', bus(5), bus(2, fae0=0x20), True),
             ('a dropped poll iteration differs in bit 3', bus(5), odd, False),
             ('the FAE0 status differs in bit 3', bus(5), bus(2, fae0=0x08), False),
             ('a data byte after the poll differs', bus(5), bus(2, after=-5), False),
             ('the exit status differs', bus(5), bus(2, exit_status=0x24), False),
             ('no keyboard loop', bus(5)[:-1199], bus(2)[:-1199], False)]
    ok = True
    for what, g, s, expect in cases:
        got = compare_bus_stalled(g, s, 'self-test')
        print('self-test: %s: %s (expected %s)' % (what, 'equal' if got else 'differs', 'equal' if expect else 'differs'))
        ok = ok and got == expect
    bad = bus(1)
    bad[6][2] = 'c002'
    try:
        normalize(bad)
        print('self-test: a broken poll pattern is not rejected')
        ok = False
    except ValueError as e:
        print('self-test: a broken poll pattern is rejected: %s' % e)
    print('self-test: %s' % ('PASS' if ok else 'FAIL'))
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default='iverilog')
    ap.add_argument('--frames', type=int, default=12)
    ap.add_argument('--jobs', type=int, default=6)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--ref-rev')
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()
    if a.self_test:
        return 0 if self_test() else 1
    if a.frames < 6:
        print('ERROR: --frames must be 6 or more')
        return 2
    iverilog = shutil.which(a.iverilog)
    if not iverilog:
        print('ERROR: iverilog not found: %s' % a.iverilog)
        return 2
    bindir = os.path.dirname(os.path.abspath(iverilog))
    vvp = shutil.which('vvp', path=bindir)
    if not vvp:
        print('ERROR: vvp not found next to %s' % iverilog)
        return 2
    env = dict(os.environ)
    env['PATH'] = bindir + os.pathsep + env.get('PATH', '')
    tools = (iverilog, vvp, env)
    jobs = [(n, p, a.frames, None, None) for n, p in RUNS.items()]
    if a.ref_rev:
        jobs.append(('ref', REF, a.frames, None, a.ref_rev))
    if a.negative:
        negs = list(NEGATIVE) + ([NEGATIVE_REF] if a.ref_rev else [])
        for m in negs:
            params = REF if m[4] == 'ref' else RUNS[m[4]]
            jobs.append(('negative_' + m[0], params, NEGATIVE_FRAMES, m, a.ref_rev if m[4] == 'ref' else None))
    results = {}
    expect = {'negative_' + m[0]: m[5] for m in NEGATIVE + [NEGATIVE_REF]}
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        futs = [ex.submit(build_and_run, tools, n, p, f, a.seed, m, r) for n, p, f, m, r in jobs]
        for fu in concurrent.futures.as_completed(futs):
            name, ok, text = fu.result()
            neg = name.startswith('negative_')
            if neg and ok is False and not any(l.startswith('ERROR') and expect[name] in l for l in text.splitlines()):
                ok = True   # failed, but not by the check that must catch it
            results[name] = ok
            print('=== %s: %s' % (name, 'BUILD FAILED' if ok is None else ('FAILED as expected (%s)' % expect[name] if neg and not ok else
                  ('NOT CAUGHT (expected: %s)' % expect[name] if neg else ('PASS' if ok else 'FAIL')))))
            show = [l for l in text.splitlines() if not neg or l.startswith('ERROR') or l.startswith('RESULT')]
            print('\n'.join(show[:12] if neg else show))
    if any(v is None for v in results.values()):
        print('run_machine_sim: BUILD FAILED')
        return 2
    ok = all(v for n, v in results.items() if not n.startswith('negative_'))
    ok = all(not v for n, v in results.items() if n.startswith('negative_')) and ok
    if all(results.get(n) for n in RUNS):
        print('=== comparisons')
        for r in ('frac', 'random'):
            ok = compare_exact('g', r) and ok
        if a.ref_rev and results.get('ref'):
            ok = compare_exact('g', 'ref') and ok
        for r in ('stall', 'stall_frac', 'stall_realign'):
            ok = compare_stall(r, a.frames) and ok
    else:
        print('ERROR: a run failed; no comparison')
        ok = False
    print('run_machine_sim: %s (frames %d, seed %d%s%s)' % ('PASS' if ok else 'FAIL', a.frames, a.seed,
          ', ref ' + a.ref_rev if a.ref_rev else '', ', negative runs' if a.negative else ''))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
