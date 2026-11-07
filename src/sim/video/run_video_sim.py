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
--negative      after the normal run, run rk86_video with pix_ce not qualified by ce (NEGATIVE below,
                the patch negative/<name>.patch; --ce frac unless another pattern is given): the
                testbench must fail with its check
The build goes to build/sim/video/ (ignored by git). Exit code 0 when the testbench prints
RESULT: PASS and no ERROR line (with --negative also: the fault is caught), 1 otherwise, 2 when a
tool is missing, the build fails or the patch does not apply.
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
NEGATIVE = ('pix_ce_without_ce', 'pix_ce on a clk with ce = 0')


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
    tools = (iverilog, vvp, env)
    rc, ok = run(a, tools, a.ce, False)
    if not a.negative:
        return rc
    if rc == 2:
        return 2
    nrc, caught = run(a, tools, 'frac' if a.ce == 'full' else a.ce, True)
    if nrc == 2:
        return 2
    return 0 if ok and caught else 1


def run(a, tools, ce, negative):
    """One build and run. Returns (rc, ok): rc 2 for a failed build or patch, else 0 when ok (a
    normal run passes, a negative run fails by its check) and 1 when not."""
    iverilog, vvp, env = tools
    out = os.path.join(ROOT, OUT)
    os.makedirs(out, exist_ok=True)
    exe = os.path.join(out, '%s_%s_%d%s.vvp' % (TOP, ce, a.font_latency, '_negative' if negative else ''))
    srcs = [os.path.join(ROOT, s) for s in SOURCES]
    if a.stream:
        srcs[SOURCES.index(STREAM)] = os.path.abspath(a.stream)
    if negative:
        sys.path.insert(0, os.path.join(ROOT, 'src', 'sim'))
        from negative import apply_patch
        patch = os.path.join(ROOT, 'src', 'sim', 'video', 'negative', NEGATIVE[0] + '.patch')
        copy_root = os.path.join(out, 'copy')
        dst = os.path.join(copy_root, VIDEO)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(os.path.join(ROOT, VIDEO), dst)
        try:
            apply_patch(ROOT, copy_root, patch)
        except ValueError as e:
            print('ERROR: negative %s: %s' % (NEGATIVE[0], e))
            return 2, False
        srcs[SOURCES.index(VIDEO)] = dst
    cmd = [iverilog, '-g2005', '-o', exe, '-s', TOP,
           '-P%s.FONT_LATENCY=%d' % (TOP, a.font_latency), '-P%s.CE_MODE=%d' % (TOP, CE_MODES[ce]),
           '-P%s.SEED=%d' % (TOP, a.seed)] + srcs
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    build_out = (res.stdout + res.stderr).strip()
    if build_out:
        print(build_out)
    if res.returncode:
        print('ERROR: iverilog exit %d' % res.returncode)
        return 2, False
    font = os.path.join(ROOT, FONT).replace(os.sep, '/')
    res = subprocess.run([vvp, '-n', exe, '+font=' + font], capture_output=True, text=True,
                         env=env, cwd=ROOT)
    text = res.stdout + res.stderr
    print(text.rstrip())
    lines = [l.strip() for l in text.splitlines()]
    ok = (res.returncode == 0 and 'RESULT: PASS' in lines
          and not any(l.startswith('ERROR') for l in lines))
    if negative:
        caught = not ok and any(l.startswith('ERROR') and NEGATIVE[1] in l for l in lines)
        print('run_video_sim: negative %s %s (ce %s)' % (NEGATIVE[0], 'FAILED as expected' if caught else
              'NOT CAUGHT (expected: %s)' % NEGATIVE[1], ce))
        return (0 if caught else 1), caught
    print('run_video_sim: %s (font latency %d, ce %s%s)' % ('PASS' if ok else 'FAIL', a.font_latency, ce,
          ', stream ' + os.path.basename(a.stream) if a.stream else ''))
    return (0 if ok else 1), ok


if __name__ == '__main__':
    sys.exit(main())
