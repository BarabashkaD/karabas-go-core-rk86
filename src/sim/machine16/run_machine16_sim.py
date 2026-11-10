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
params (-P<top>.<name>=<value>), plusargs (+<name>=<value> on the vvp line), hexfiles
{name: repository-relative binary} (written by write_hexfiles as <name>.hex, one byte per line, into
the output folder, and passed as +<name>=<name>.hex), negatives [(name, expected text)].
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
                            ('vv55_intr_pulse', 'ERROR: vv55: intr pulse'),
                            ('vv55_mode_set_keeps_status', 'ERROR: vv55: mode set: status'),
                            ('vv55_wr_no_cs', 'ERROR: vv55: cs: wr'), ('vv55_rd_no_cs', 'ERROR: vv55: cs: rd'),
                            ('vv55_byte_write_inte', 'ERROR: vv55: byte write inte'),
                            ('vv55_pc3_mixed', 'ERROR: vv55: pc3 mixed')]),
    'vt57': dict(top='tb_vt57', files=['src/sim/machine16/tb_vt57.v', 'src/rtl/rk86_16/k580vt57.v'],
                 negatives=[('vt57_extra_state', 'ERROR: vt57: dack at 36'), ('vt57_s4_to_s1', 'ERROR: vt57: period 36'),
                            ('vt57_address_early', 'ERROR: vt57: address'), ('vt57_one_edge', 'ERROR: vt57: aen rise 0'),
                            ('vt57_aen_gap', 'ERROR: vt57: aen at 31'), ('vt57_hrq_late', 'ERROR: vt57: latency 36')]),
    'vt57_func': dict(top='tb_vt57_func', files=['src/sim/machine16/tb_vt57_func.v', 'src/rtl/rk86_16/k580vt57.v'],
                      negatives=[('vt57f_priority_fixed', 'ERROR: vt57f: rotating'),
                                 ('vt57f_read_strobes', 'ERROR: vt57f: read cycle'),
                                 ('vt57f_ready_ignored', 'ERROR: vt57f: ready'),
                                 ('vt57f_tc_stop_ignored', 'ERROR: vt57f: tc stop'),
                                 ('vt57f_autoload_early', 'ERROR: vt57f: autoload'),
                                 ('vt57f_mark_tc_only', 'ERROR: vt57f: mark'),
                                 ('vt57f_ff_not_reset', 'ERROR: vt57f: first/last'),
                                 ('vt57f_hlda_lost_s0', 'ERROR: vt57f: hlda lost'),
                                 ('vt57f_cont_no_hlda', 'ERROR: vt57f: hlda lost'),
                                 ('vt57f_verify_wait', 'ERROR: vt57f: verify'),
                                 ('vt57f_b2b_no_reload', 'ERROR: vt57f: autoload'),
                                 ('vt57f_address_switch', 'ERROR: vt57f: priority: address at 36'),
                                 ('vt57f_s0_no_return', 'ERROR: vt57f: s0 return'),
                                 ('vt57f_mode_any_a', 'ERROR: vt57f: addressing'),
                                 ('vt57f_status_a_only', 'ERROR: vt57f: addressing'),
                                 ('vt57f_illegal_strobes', 'ERROR: vt57f: illegal cycle'),
                                 ('vt57f_rotate_b2b_only', 'ERROR: vt57f: rotating'),
                                 ('vt57f_tcstop_all', 'ERROR: vt57f: tc stop'),
                                 ('vt57f_reset_keeps_up', 'ERROR: vt57f: reset'),
                                 ('vt57f_reload_any_channel', 'ERROR: vt57f: autoload')]),
    'vg75': dict(top='tb_vg75', files=['src/sim/machine16/tb_vg75.v', 'src/rtl/rk86_16/k580vg75.v'],
                 negatives=[('vg75_hrtc_7', 'ERROR: vg75: hrtc: power-up: HRTC high 12 ce16, expected 24'),
                            ('vg75_vrtc_short', 'ERROR: vg75: vrtc: power-up: 0 VRTC rises in 720 ce16, expected 10'),
                            ('vg75_ir_without_ie', 'ERROR: vg75: ir: power-up: status bit 5 (IR) 1, expected 0'),
                            ('vg75_ic_never', 'ERROR: vg75: ic: 00h with 2 parameters, then 27h: status bit 3 (IC) 0, expected 1'),
                            ('vg75_preset_ignored', 'ERROR: vg75: preset: HRTC high while the counters are held'),
                            ('vg75_preset_row0',
                             'ERROR: vg75: preset: VRTC not high after the first CCLK fall after the releasing command'),
                            ('vg75_lc_mode', 'ERROR: vg75: lc: row 0 line 0 char 0: LC 0, expected 9 (M = 1)'),
                            ('vg75_lpen_no_flag', 'ERROR: vg75: light pen: after LPEN rise: status bit 4 (LP) 0, expected 1'),
                            ('vg75_preset_keeps_ustop',
                             'ERROR: vg75: preset after an underrun: the first DRQ 10224 ce16 after the resume CCLK fall'),
                            ('vg75_preset_release_write',
                             'ERROR: vg75: preset: VRTC high while the counters are held, after a parameter write'),
                            ('vg75_preset_release_read',
                             'ERROR: vg75: preset: VRTC high while the counters are held, after a status read'),
                            ('vg75_ir_needs_ve',
                             'ERROR: vg75: ir: after 40h (Stop Display): 0 IRQ rises in a frame, expected 1')]),
    'vg75_dma': dict(top='tb_vg75_dma', files=['src/sim/machine16/tb_vg75_dma.v', 'src/rtl/rk86_16/k580vg75.v'],
                     negatives=[('vg75_burst_count_ignored',
                                 'ERROR: vg75: burst length: BB = 00, SSS = 001: row 6 fill: burst 0 has 78 transfers, expected 1'
                                 ' (CRT-21, [D79] 1-172, 1-179)'),
                                ('vg75_burst_space_ignored',
                                 'ERROR: vg75: burst space: BB = 00, SSS = 001: row 6 fill: DRQ 12 ce16 after the last WR rise of'
                                 ' burst 0, expected 73..84 (CRT-21, [D79] 1-172, 1-179)'),
                                ('vg75_drq_held',
                                 'ERROR: vg75: drq at wr: row 2 fill transfer 0: DRQ high 2 clk after the DMA WR fall, expected'
                                 ' low from WR fall + 2 clk to WR rise (CRT-22, [D79] 1-184 Fig. 30, D9)'),
                                ('vg75_byte_on_wr_fall',
                                 'ERROR: vg75: byte: row 0 line 0 char 0: CC 21, expected 20 (CRT-23, [D79] 1-185)'),
                                ('vg75_underrun_ignored',
                                 'ERROR: vg75: underrun: VSP low at line 61 char 0, expected high from the row 6 start to the'
                                 ' VRTC fall (CRT-25, [D79] 1-172, 1-180, S11)'),
                                ('vg75_underrun_restart_early',
                                 'ERROR: vg75: underrun: 78 DRQ rises from the row 6 start to the VRTC fall, expected 0'
                                 ' (DMA stopped until after the vertical retrace) (CRT-25, [D79] 1-172, 1-180, S11)'),
                                ('vg75_fifo_off',
                                 'ERROR: vg75: fifo: during row 1 (the row 2 fill): 78 transfers, expected 79'
                                 ' (CRT-27, [D79] 1-165, 1-176)'),
                                ('vg75_stop_dma_ignored',
                                 'ERROR: vg75: stop dma: during row 4 (the row 5 fill): 78 transfers, expected 12'
                                 ' (CRT-26, [D79] 1-175)'),
                                ('vg75_fifo_ptr_row_only',
                                 'ERROR: vg75: fifo: row 2 line 1 char 1: CC 00, expected 24 (CRT-27, [D79] 1-165, 1-176)'),
                                ('vg75_du_self_clear',
                                 'ERROR: vg75: underrun: after the row 8 start (set at the row 6 start, no read since): status'
                                 ' bit 1 (DU) 0, expected 1 (CRT-25, [D79] 1-172, 1-180, S11)'),
                                ('vg75_attr_own_position',
                                 'ERROR: vg75: non-transparent: row 2 line 9 char 1: LTEN 1, expected 0 (CRT-28, [D79] 1-176)'),
                                ('vg75_fifo_overrun_keeps_first',
                                 'ERROR: vg75: fifo: row 8 line 0 char 0: CC 29, expected 49 (CRT-27, [D79] 1-165, 1-176)')]),
    'vg75_attr': dict(top='tb_vg75_attr', files=['src/sim/machine16/tb_vg75_attr.v', 'src/rtl/rk86_16/k580vg75.v'],
                      negatives=[('vg75_ca_table_swapped',
                                  'ERROR: vg75: char attribute: UUUU = 9: row 0 line 9 char 0 (code c0): LA 1, expected 2'
                                  ' (frame 66) (CRT-30, [D79] 1-174)'),
                                 ('vg75_fa_not_reset',
                                  'ERROR: vg75: field attribute: UUUU = 9: row 0 line 0 char 0 (code 42): RVV 1, expected 0'
                                  ' (frame 153) (CRT-31, [D79] 1-175)'),
                                 ('vg75_cursor_no_blink',
                                  'ERROR: vg75: cursor: CC = 00, cursor at row 0 char 5: row 0 line 0 char 5 (code 2f): RVV 1,'
                                  ' expected 0 (frame 8) (CRT-33, [D79] 1-177, S3, S4)'),
                                 ('vg75_blink_16',
                                  'ERROR: vg75: blink: CC = 00, cursor at row 2 char 5: row 0 line 1 char 3 (code e6): VSP 0,'
                                  ' expected 1 (frame 16) (CRT-36, [D79] 1-173, 1-175, S3)'),
                                 ('vg75_ca_underline_field',
                                  'ERROR: vg75: interaction: UUUU = 9: row 1 line 0 char 11 (code e4): HGLT 1, expected 0'
                                  ' (frame 156) (CRT-32, [D79] 1-176)')]),
    'video16': dict(top='tb_video16', files=['src/sim/machine16/tb_video16.v', 'src/rtl/rk86_16/rk86_video16.v'],
                    negatives=[('video_load_at_0', 'ERROR: video16: dot'), ('video_shift_order', 'ERROR: video16: dot'),
                               ('video_lten_unlatched', 'ERROR: video16: lten'), ('video_vsp_ignored', 'ERROR: video16: vsp')]),
    'machine16': dict(top='tb_rk86_machine16',
                      files=lambda: ['src/sim/machine16/cpu_power_up.vh', 'src/sim/machine16/tb_rk86_machine16.v', MEM]
                      + prj_files('src/rk86_machine16.prj'),
                      hexfiles=dict(bios='src/roms/BIOS.BIN', font='src/roms/FONT.BIN'),
                      negatives=[('crt_wr_without_ior', 'ERROR: glue: 8275 WR'),
                                 # the 8257 on the character clock: the glue check of its CLK pin is the first
                                 # ERROR (from the first clk); the bus timing checks alone give 'aen per transfer'
                                 ('dma_on_char_clock', 'ERROR: glue: 8257 CLK: not 8224 F2'),
                                 ('vg75_drq_held', 'ERROR: hold periods'),
                                 ('vg75_burst_count_ignored', 'ERROR: burst length'),
                                 ('vg75_burst_space_ignored', 'ERROR: burst space'),
                                 ('vg75_hrtc_7', 'ERROR: hrtc')]),
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


def write_hexfiles(test, out_dir, prefix=''):
    """Writes the data files of a test (TESTS key 'hexfiles': {name: repository-relative binary}) as
    <out_dir>/<prefix><name>.hex for $readmemh (one byte per line, two hex digits). Returns
    {name: file name} (bare names, relative to out_dir)."""
    made = {}
    for name, rel in test.get('hexfiles', {}).items():
        with open(os.path.join(ROOT, rel), 'rb') as f:
            data = f.read()
        fname = '%s%s.hex' % (prefix, name)
        with open(os.path.join(out_dir, fname), 'w', newline='\n') as f:
            f.write(''.join('%02x\n' % b for b in data))
        made[name] = fname
    return made


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
    plusargs += ['+%s=%s' % (k, v) for k, v in write_hexfiles(test, out).items()]
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
