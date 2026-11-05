#!/usr/bin/env python3
"""Builds and runs the iverilog testbench of rk86_video and rk86_video_stream
(src/sim/video/tb_rk86_video_stream.v; docs/contract.md, section rk86_video_stream).

Usage, from any directory:
    python -B src/sim/video/run_video_sim.py [--iverilog PATH] [--font-latency N] [--stream FILE]
--iverilog      the iverilog program (default: iverilog on PATH); vvp is taken from its directory
--font-latency  clk from font_addr to font_data in the font ROM model (default 1, as the font
                core; 0 is a combinational ROM)
--stream        another rk86_video_stream source, for a negative check (default: the one of the tree)
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
OUT = os.path.join('build', 'sim', 'video')


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default='iverilog')
    ap.add_argument('--font-latency', type=int, default=1)
    ap.add_argument('--stream')
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
    exe = os.path.join(out, TOP + '.vvp')
    srcs = [os.path.join(ROOT, s) for s in SOURCES]
    if a.stream:
        srcs[SOURCES.index(STREAM)] = os.path.abspath(a.stream)
    cmd = [iverilog, '-g2005', '-o', exe, '-s', TOP,
           '-P%s.FONT_LATENCY=%d' % (TOP, a.font_latency)] + srcs
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
    print('run_video_sim: %s (font latency %d%s)' % ('PASS' if ok else 'FAIL', a.font_latency,
          ', stream ' + os.path.basename(a.stream) if a.stream else ''))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
