#!/usr/bin/env python3
"""Builds and runs the iverilog testbench of rk86_video and rk86_video_stream
(src/sim/video/tb_rk86_video_stream.v; docs/contract.md, section rk86_video_stream).

Usage, from any directory:
    python -B src/sim/video/run_video_sim.py [--iverilog PATH] [--font-latency N] [--ce MODE] [--seed N] [--stream FILE] [--negative]
--iverilog      the iverilog program (default: iverilog on PATH); vvp is taken from its directory
--font-latency  clk from font_addr to font_data in the font ROM model (default 1, as the font
                core; 0 is a combinational ROM)
--ce            the clock enable of rk86_video: full (always 1, the Karabas boards; default),
                frac (160 of 297 clk), random (pseudo-random, about 1 of 2, from --seed)
--seed          the seed of --ce random (default 1)
--stream        another rk86_video_stream source, for a negative check (default: the one of the tree)
--negative      run rk86_video with pix_ce not qualified by ce (NEGATIVE below; --ce frac unless
                another pattern is given): the testbench must fail with its check; exit 0 when it does
The build goes to build/sim/video/ (ignored by git). Exit code 0 when the testbench prints
RESULT: PASS and no ERROR line, 1 otherwise, 2 when a tool is missing or the build fails.
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
TOP = 'tb_rk86_video_stream'
STREAM = 'src/rtl/rk86_video_stream.v'
SOURCES = ['src/rtl/k580wg75.v', 'src/rtl/k580wt57.v', 'src/rtl/rk86_video.v', STREAM,
           'src/sim/video/tb_rk86_video_stream.v']
FONT = 'src/roms/FONT.BIN'
CE_MODES = {'full': 0, 'frac': 1, 'random': 2}
OUT = os.path.join('build', 'sim', 'video')
VIDEO = 'src/rtl/rk86_video.v'
NEGATIVE = ('pix_ce_without_ce', 'assign pix_ce = ce && state == 2\'b00;', 'assign pix_ce = state == 2\'b00;',
            'pix_ce on a clk with ce = 0')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default='iverilog')
    ap.add_argument('--font-latency', type=int, default=1)
    ap.add_argument('--ce', choices=sorted(CE_MODES), default='full')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--stream')
    ap.add_argument('--negative', action='store_true')
    a = ap.parse_args()
    iverilog = shutil.which(a.iverilog)
    if not iverilog:
        print('ERROR: iverilog not found: %s' % a.iverilog)
        return 2
    bindir = os.path.dirname(os.path.abspath(iverilog))
    vvp = shutil.which('vvp', path=bindir)
    if not vvp:
        print('ERROR: vvp not found next to %s' % iverilog)
        return 2
    if a.font_latency < 0:
        print('ERROR: --font-latency must be 0 or more')
        return 2
    env = dict(os.environ)
    env['PATH'] = bindir + os.pathsep + env.get('PATH', '')
    out = os.path.join(ROOT, OUT)
    os.makedirs(out, exist_ok=True)
    if a.negative and a.ce == 'full':
        a.ce = 'frac'
    exe = os.path.join(out, '%s_%s_%d%s.vvp' % (TOP, a.ce, a.font_latency, '_negative' if a.negative else ''))
    srcs = [os.path.join(ROOT, s) for s in SOURCES]
    if a.stream:
        srcs[SOURCES.index(STREAM)] = os.path.abspath(a.stream)
    if a.negative:
        with open(os.path.join(ROOT, VIDEO), encoding='utf-8', newline='') as f:
            text = f.read()
        if text.count(NEGATIVE[1]) != 1:
            print('ERROR: negative %s: the text to break is not found once' % NEGATIVE[0])
            return 2
        neg = os.path.join(out, 'negative_' + os.path.basename(VIDEO))
        with open(neg, 'w', encoding='utf-8', newline='') as f:
            f.write(text.replace(NEGATIVE[1], NEGATIVE[2]))
        srcs[SOURCES.index(VIDEO)] = neg
    cmd = [iverilog, '-g2005', '-o', exe, '-s', TOP,
           '-P%s.FONT_LATENCY=%d' % (TOP, a.font_latency), '-P%s.CE_MODE=%d' % (TOP, CE_MODES[a.ce]),
           '-P%s.SEED=%d' % (TOP, a.seed)] + srcs
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    build_out = (res.stdout + res.stderr).strip()
    if build_out:
        print(build_out)
    if res.returncode:
        print('ERROR: iverilog exit %d' % res.returncode)
        return 2
    font = os.path.join(ROOT, FONT).replace(os.sep, '/')
    res = subprocess.run([vvp, '-n', exe, '+font=' + font], capture_output=True, text=True,
                         env=env, cwd=ROOT)
    text = res.stdout + res.stderr
    print(text.rstrip())
    lines = [l.strip() for l in text.splitlines()]
    ok = (res.returncode == 0 and 'RESULT: PASS' in lines
          and not any(l.startswith('ERROR') for l in lines))
    if a.negative:
        caught = not ok and any(l.startswith('ERROR') and NEGATIVE[3] in l for l in lines)
        print('run_video_sim: negative %s %s (ce %s)' % (NEGATIVE[0], 'FAILED as expected' if caught else
              'NOT CAUGHT (expected: %s)' % NEGATIVE[3], a.ce))
        return 0 if caught else 1
    print('run_video_sim: %s (font latency %d, ce %s%s)' % ('PASS' if ok else 'FAIL', a.font_latency, a.ce,
          ', stream ' + os.path.basename(a.stream) if a.stream else ''))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
