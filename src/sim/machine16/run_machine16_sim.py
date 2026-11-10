#!/usr/bin/env python3
"""Runs the iverilog testbenches of the rk86_16 machine (src/rtl/rk86_16, the original 16 MHz timing).

Usage, from any directory:
    python -B src/sim/machine16/run_machine16_sim.py [--iverilog PATH] [--negative] [--mem FILE ...]
        [--frames N] [--list] [TEST ...]
TEST: names from TESTS (default: all). --list prints the names and exits.
--iverilog  the iverilog program (default: the IVERILOG environment variable, else iverilog on PATH);
            vvp is taken from its directory
--negative  also run every fault of the test: src/sim/machine16/negative/<name>.patch (made with git
            diff against the repository root) applied with git apply to copies of the files under
            build/sim/machine16/<test>/neg_<name>/; a fault passes when the run fails and its output
            contains the expected text
--mem       replace src/sim/machine16/tb_rk86_mem16.v in the file list of a test by these files
--frames    sets the parameter FRAMES of the top
A test entry of TESTS: top, files (repository-relative paths, or a function that returns them),
params (-P<top>.<name>=<value>), plusargs (+<name>=<value> on the vvp line), negatives
[(name, expected text)].
Pass rule: vvp exits 0, prints a line that starts with PASS and no line that starts with ERROR or
contains FATAL. Outputs: build/sim/machine16/<test>/ (ignored by git).
Exit code 0 when every run passes and every fault is caught, 1 otherwise, 2 when a tool is missing
or the test name is unknown.
"""
import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src', 'sim'))
sys.dont_write_bytecode = True
from negative import apply_patch, patched_files  # noqa: E402

OUT = os.path.join('build', 'sim', 'machine16')
NEGATIVE_DIR = os.path.join('src', 'sim', 'machine16', 'negative')
MEM = 'src/sim/machine16/tb_rk86_mem16.v'

TESTS = {
    'clocks16': dict(top='tb_clocks16', files=['src/sim/machine16/tb_clocks16.v', 'src/rtl/rk86_16/rk86_clocks16.v'],
                     negatives=[('divider_10', 'ERROR: clocks16: f1 period 10'), ('f2_step_4', 'ERROR: clocks16: f2 at step 4'),
                                ('f2_fall_step_6', 'ERROR: clocks16: f2_fall at step 6'),
                                ('reset_on_f1', 'ERROR: clocks16: reset changed off p3'),
                                ('reset_on_f2_fall', 'ERROR: clocks16: reset changed off p3'),
                                ('ststb_no_reset', 'ERROR: clocks16: ststb at period'),
                                ('stopped_in_reset', 'ERROR: clocks16: f1 period'),
                                ('ie4_div10', 'ERROR: clocks16: ie4 count'),
                                ('f2_fall_missing', 'ERROR: clocks16: f2_fall count'),
                                ('dot_ce_odd', 'ERROR: clocks16: dot_ce alignment'),
                                ('cclk_misaligned', 'ERROR: clocks16: cclk_fall alignment'),
                                ('ststb_reset_lag', 'ERROR: clocks16: ststb at period')]),
    'vv55': dict(top='tb_vv55', files=['src/sim/machine16/tb_vv55.v', 'src/rtl/rk86_16/k580vv55.v'],
                 negatives=[('vv55_no_output_reset', 'ERROR: vv55: mode set'), ('vv55_bsr_bit', 'ERROR: vv55: bsr'),
                            ('vv55_ibf_on_rd_fall', 'ERROR: vv55: mode 1 input'),
                            ('vv55_obf_ack_ignored', 'ERROR: vv55: mode 1 output'),
                            ('vv55_mode2_buffer', 'ERROR: vv55: mode 2'),
                            ('vv55_pc_upper_mode0_only', 'ERROR: vv55: port C byte write'),
                            ('vv55_intr_pulse', 'ERROR: vv55: intr pulse')]),
}  # the tasks that add testbenches add their entries


def prj_files(prj):
    """The RTL paths (relative to the repository root) of a .prj: lines 'verilog work "<path>"',
    paths relative to src/."""
    base = os.path.dirname(prj)
    files = []
    with open(os.path.join(ROOT, prj), encoding='utf-8') as f:
        for line in f:
            parts = line.split('"')
            if line.startswith('verilog') and len(parts) >= 3:
                files.append(os.path.normpath(os.path.join(base, parts[1])).replace(os.sep, '/'))
    return files


def run(name, test, tools, mem=None, frames=None, fault=None):
    """Builds and runs one test (or one fault of it). Returns (ok, text)."""
    iverilog, vvp, env = tools
    out = os.path.join(ROOT, OUT, name, 'neg_' + fault if fault else '')
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(out)
    files = test['files']() if callable(test['files']) else list(test['files'])
    if mem:
        files = [m for f in files for m in ([os.path.abspath(x) for x in mem] if f == MEM else [f])]
    paths = [f if os.path.isabs(f) else os.path.join(ROOT, f) for f in files]
    if fault:
        patch = os.path.join(ROOT, NEGATIVE_DIR, fault + '.patch')
        copy_root = os.path.join(out, 'copy')
        try:
            for rel in patched_files(patch):
                src = os.path.join(ROOT, rel)
                if src not in paths:
                    raise ValueError('%s is not compiled in this test' % rel)
                dst = os.path.join(copy_root, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(src, dst)
                paths[paths.index(src)] = dst
            apply_patch(ROOT, copy_root, patch)
        except (ValueError, OSError) as e:
            return None, 'ERROR: fault %s: %s' % (fault, e)
    params = dict(test.get('params', {}))
    if frames is not None:
        params['FRAMES'] = frames
    top = test['top']
    exe = os.path.join(out, name + '.vvp')
    cmd = [iverilog, '-g2005', '-o', exe, '-s', top] + ['-P%s.%s=%s' % (top, k, v) for k, v in sorted(params.items())] + paths
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=out, env=env)
    if res.returncode:
        return False, 'ERROR: iverilog: ' + (res.stdout + res.stderr)
    plusargs = ['+%s=%s' % (k, v) for k, v in test.get('plusargs', {}).items()]
    res = subprocess.run([vvp, '-n', exe] + plusargs, capture_output=True, text=True, cwd=out, env=env)
    text = res.stdout + res.stderr
    lines = [l.strip() for l in text.splitlines()]
    ok = (res.returncode == 0 and any(l.startswith('PASS') for l in lines)
          and not any(l.startswith('ERROR') or 'FATAL' in l for l in lines))
    return ok, text


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--mem', nargs='+', help='files to compile in place of ' + MEM)
    ap.add_argument('--frames', type=int)
    ap.add_argument('--list', action='store_true')
    ap.add_argument('tests', nargs='*')
    a = ap.parse_args()
    if a.list:
        for n in TESTS:
            print(n)
        return 0
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
    names = a.tests or list(TESTS)
    unknown = [n for n in names if n not in TESTS]
    if unknown:
        print('ERROR: unknown tests: %s' % ', '.join(unknown))
        return 2
    failed = 0
    for name in names:
        test = TESTS[name]
        ok, text = run(name, test, tools, a.mem, a.frames)
        print('%s: %s' % (name, 'PASS' if ok else 'FAIL'))
        if not ok:
            print(text.rstrip())
            failed += 1
        if a.negative:
            for fault, expected in test.get('negatives', []):
                bad, text = run(name, test, tools, a.mem, a.frames, fault)
                caught = bad is False and expected in text
                print('%s: negative %s %s' % (name, fault, 'FAILED as expected' if caught else 'NOT CAUGHT (expected: %s)' % expected))
                if not caught:
                    print(text.rstrip())
                    failed += 1
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
