#!/usr/bin/env python3
"""Builds and runs the smoke testbench of the build candidate (src/rk86_candidate.v,
src/sim/candidate/tb_rk86_candidate.v; docs/integration.md, The build candidate).

Usage, from any directory:
    python -B src/sim/candidate/run_candidate_sim.py [--iverilog PATH] [--frames N] [--negative] [--jobs N]
--iverilog  the iverilog program (default: iverilog on PATH); vvp is taken from its directory
--frames    native frames to run after the load (default 10; the BIOS reaches its keyboard loop
            in frame 6)
--negative  also run broken variants of the candidate (NEGATIVES below); each must fail by its
            own check. Both fail at the first reads from the slow ROM after the reset, so they
            do not exercise the address tag of the RAM path (the data check covers it only in
            the passing run)
--jobs      runs at the same time (default 1)
The sources are those of src/rk86_machine.prj, src/rk86_candidate.v and the testbench. The build
goes to build/sim/candidate/ (ignored by git).
Exit code 0 when the testbench prints RESULT: PASS and no ERROR line (and each negative run
fails by its check), 1 otherwise, 2 when a tool is missing or a build fails.
"""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'src', 'sim'))
from negative import apply_patch, patched_files  # noqa: E402
TOP = 'tb_rk86_candidate'
MANIFEST = 'src/rk86_machine.prj'
CANDIDATE = 'src/rk86_candidate.v'
TB = 'src/sim/candidate/tb_rk86_candidate.v'
BIOS = 'src/roms/BIOS.BIN'
FONT = 'src/roms/FONT.BIN'
OUT = os.path.join('build', 'sim', 'candidate')
# cpu_ready without !vid_rd is not among them: in 10 frames the CPU then steps while vid_rd
# only on steps that do not read the memory, and only the sanity check of the testbench fails.
NEGATIVES = [  # (name, what, the ERROR text that must appear); the fault is negative/<name>.patch
    ('no_rom_wait', 'cpu_ready without the ROM wait: the CPU reads 8\'hFF from the ROM',
     'the CPU did not reach the keyboard loop'),
    ('no_wait', 'cpu_ready = 1: the CPU takes the data before the memory has it',
     'CPU read data differs from the memory'),
]
NEGATIVE_DIR = 'src/sim/candidate/negative'


def manifest_files():
    files = []
    with open(os.path.join(ROOT, MANIFEST), encoding='utf-8') as f:
        for line in f:
            if line.strip():
                m = re.fullmatch(r'verilog work "([^"]+)"', line.strip())
                if not m:
                    raise ValueError('%s: bad line "%s"' % (MANIFEST, line.strip()))
                files.append('src/' + m.group(1))
    return files


def build_and_run(name, frames, iverilog, vvp, env, mutant=None):
    """Returns (ok, lines); ok is None when the build fails. mutant: (name,), its patch is applied to copies."""
    out = os.path.join(ROOT, OUT, name)
    os.makedirs(out, exist_ok=True)
    sources = [os.path.join(ROOT, rel) for rel in manifest_files() + [CANDIDATE, TB]]
    if mutant:
        patch = os.path.join(ROOT, NEGATIVE_DIR, mutant[0] + '.patch')
        copy_root = os.path.join(out, 'copy')
        try:
            for rel in patched_files(patch):
                dst = os.path.join(copy_root, rel)
                if os.path.join(ROOT, rel) not in sources:
                    raise ValueError('%s is not compiled in this run' % rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copyfile(os.path.join(ROOT, rel), dst)
                sources[sources.index(os.path.join(ROOT, rel))] = dst
            apply_patch(ROOT, copy_root, patch)
        except ValueError as e:
            return None, ['ERROR: negative %s: %s' % (mutant[0], e)]
    vvp_file = os.path.join(out, TOP + '.vvp')
    cmd = [iverilog, '-g2005', '-o', vvp_file, '-s', TOP, '-P%s.FRAMES=%d' % (TOP, frames)] + sources
    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if res.returncode != 0 or res.stdout.strip() or res.stderr.strip():
        return None, (res.stdout + res.stderr).strip().splitlines()
    res = subprocess.run([vvp, '-n', vvp_file, '+bios=' + os.path.join(ROOT, BIOS),
                          '+font=' + os.path.join(ROOT, FONT)],
                         capture_output=True, text=True, env=env, cwd=out)
    lines = (res.stdout + res.stderr).splitlines()
    ok = res.returncode == 0 and 'RESULT: PASS' in lines and not any(l.startswith('ERROR') for l in lines)
    return ok, lines


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--iverilog', default='iverilog')
    ap.add_argument('--frames', type=int, default=10)
    ap.add_argument('--negative', action='store_true')
    ap.add_argument('--jobs', type=int, default=1)
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
    env = dict(os.environ)
    env['PATH'] = bindir + os.pathsep + env.get('PATH', '')
    runs = [('run', None)]
    if a.negative:
        runs += [('negative_' + n[0], n) for n in NEGATIVES]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as pool:
        futures = [pool.submit(build_and_run, name, a.frames, iverilog, vvp, env,
                               (neg[0],) if neg else None) for name, neg in runs]
        results = [f.result() for f in futures]
    ok, lines = results[0]
    print('=== candidate: %s' % ('BUILD FAILED' if ok is None else 'PASS' if ok else 'FAIL'))
    print('\n'.join(lines))
    if ok is None:
        return 2
    for (name, neg), (nok, nlines) in zip(runs[1:], results[1:]):
        if nok is None:
            print('=== %s: BUILD FAILED' % name)
            print('\n'.join(nlines))
            return 2
        caught = nok is False and any(l.startswith('ERROR') and neg[2] in l for l in nlines)
        print('=== %s (%s): %s' % (name, neg[1],
              'FAILED as expected (%s)' % neg[2] if caught else 'NOT CAUGHT'))
        print('\n'.join(l for l in nlines if l.startswith('ERROR') or l.startswith('RESULT')))
        ok = ok and caught
    print('run_candidate_sim: %s (frames %d%s)' % ('PASS' if ok else 'FAIL', a.frames,
          ', %d negative runs' % len(NEGATIVES) if a.negative else ''))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
