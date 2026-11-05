"""Host checks of a system-simulation run and the run verdict (plan Task 4/5).

Usage: python -B run_host_checks.py <result dir> --rev <revision export> [--ppm]
<result dir>: build/sim/sys/out/<run-id>/<board>-<sha7>[-<tag>] (perf.txt, summary.txt, simout/ of
run_sys_sim.sh). <revision export>: the export of the simulated revision (its src/roms: FONT.BIN for the
rendering, BIOS.BIN for the screen layout).

If the run snapped pictures (simout/snaps.txt, chain basic): tools/render.py (the reference rendering of
every snap; at least one snap keys* with the cursor on) and tools/screen.py --golden <snap> on every
simout/ram_<snap>.hex (the screen text is written to simout/ram_<snap>.txt). The verdict of the run is
PASS only if the guest verdict (perf.txt VERDICT) is PASS and every host check passes. Writes
<result dir>/host_checks.txt and appends the section HOST CHECKS with "RUN VERDICT PASS|FAIL" to
<result dir>/summary.txt (an earlier section is replaced). Exit status 0 = PASS, 1 = FAIL.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = '\nHOST CHECKS (tools/run_host_checks.py)\n'


def run(cmd, out_file=None):
    p = subprocess.run([sys.executable, '-B'] + cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    text = p.stdout.decode('utf-8', 'replace')
    if out_file:
        with open(out_file, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text)
    return p.returncode, text


def main():
    ap = argparse.ArgumentParser(description='Host checks and the verdict of a system-simulation run')
    ap.add_argument('result')
    ap.add_argument('--rev', required=True, help='export of the simulated revision (src/roms)')
    ap.add_argument('--ppm', action='store_true', help='also the PPM images of the rendering')
    a = ap.parse_args()
    res = os.path.abspath(a.result)
    simout = os.path.join(res, 'simout')
    lines = []
    ok = True

    guest = None
    perf = os.path.join(res, 'perf.txt')
    if os.path.isfile(perf):
        for ln in open(perf):
            if ln.startswith('VERDICT '):
                guest = ln.split()[1]
    lines.append('guest verdict (perf.txt): %s' % (guest or 'missing'))
    if guest != 'PASS':
        ok = False

    snaps = os.path.join(simout, 'snaps.txt')
    if os.path.isfile(snaps) and os.path.getsize(snaps) > 0:
        font = os.path.join(a.rev, 'src', 'roms', 'FONT.BIN')
        bios = os.path.join(a.rev, 'src', 'roms', 'BIOS.BIN')
        cmd = [os.path.join(HERE, 'render.py'), simout, '--font', font, '--cursor-on', 'keys']
        if a.ppm:
            cmd.append('--ppm')
        st, text = run(cmd)
        last = text.strip().splitlines()[-1] if text.strip() else 'no output'
        lines.append('render.py: %s (simout/render.txt)' % last)
        if st != 0:
            ok = False
        sys.path.insert(0, HERE)
        import frames  # noqa: E402
        _, order = frames.read_snaps(snaps)
        for n in order:
            ram = os.path.join(simout, 'ram_%s.hex' % n)
            if not os.path.isfile(ram):
                lines.append('screen.py %s: FAIL simout/ram_%s.hex missing' % (n, n))
                ok = False
                continue
            st, text = run([os.path.join(HERE, 'screen.py'), ram, '--bios', bios, '--ascii', '--golden', n],
                           os.path.join(simout, 'ram_%s.txt' % n))
            last = text.strip().splitlines()[-1] if text.strip() else 'no output'
            lines.append('screen.py --golden %s: %s (simout/ram_%s.txt)' % (n, last, n))
            if st != 0:
                ok = False
    else:
        lines.append('no snapped pictures (simout/snaps.txt): no rendering, no screen text')
    lines.append('RUN VERDICT %s' % ('PASS' if ok else 'FAIL'))
    for ln in lines:
        print(ln)
    with open(os.path.join(res, 'host_checks.txt'), 'w', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')
    sm = os.path.join(res, 'summary.txt')
    if os.path.isfile(sm):
        text = open(sm).read()
        k = text.find(MARK)
        if k >= 0:
            text = text[:k]
        with open(sm, 'w', newline='\n') as f:
            f.write(text.rstrip('\n') + '\n' + MARK + ''.join('  %s\n' % x for x in lines))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
