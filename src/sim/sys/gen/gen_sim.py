"""Exported revision -> ISim work tree with declared sim copies (host, Python 3).

Usage:
  python -B gen_sim.py <rev_dir> <tb_dir> <board> <out_dir> --ipcore-dir <dir> --ipcore-ref <dir>
         [--ipcore-sha <sha>] [--rev-sha <sha>] [--tb-sha <sha>] [--tb <file> ...] [--tb-top tb_sys]
         [--power-up <tsv>] [--power-up-map <tsv>] [--xcheck-regs <tsv>] [--xcheck-map <tsv>]

  <rev_dir>     export of the compared revision (src/, modules/)
  <tb_dir>      export of the TB revision (src/sim/, pk/): TB, models, tables
  <board>       go | mini | minig
  <out_dir>     the work tree (usually the parent of <rev_dir>); gets sim.prj (paths relative to
                <out_dir>), sim/ (sim copies, wrappers, models, sim support), tb/, the .mif files,
                roms/*.hex, sim.env, subst.txt, summary.txt
  --ipcore-dir  the generated Coregen cores (build/clone-pr03/src/ipcore_dir, built from 3fdb64f)
  --ipcore-ref  export of the revision the cores were generated from (src/ipcore, the .coe files):
                the compared revision's src/ipcore/**/*.xco and their .coe files must be equal to it,
                the .mif of the cores equal to coe2hex(.coe), otherwise the generator stops. Its file
                EXPORT_SHA (the exported commit) must match --ipcore-sha.
  --power-up-map / --xcheck-map  per-comparison overrides of the candidate modules: a row id
                (signal@first-candidate, or the bare signal for power-up rows) <TAB> modules.
  The out_dir is cleaned (everything except <rev_dir>) before it is written.

Every change of an RTL file is a declared substitution with an exact count check (subst.py);
anything unexpected stops the generator with an error (exit 2).
"""
import argparse
import hashlib
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tools'))
import hdl  # noqa: E402
import subst  # noqa: E402
from subst import SubstError  # noqa: E402
import mkhex  # noqa: E402

# Per-board expectations, counted on the instances of the elaborated hierarchy (F9): the HDMI
# I_FREQ literal (#7, text count in the top), hdmi_out_xilinx instances (#8), PLL_BASE / DCM_SP
# primitive instances (#10).
BOARDS = {
    'go': {'top': 'radio86rk', 'i_freq': 0, 'hdmi_out_xilinx': 0, 'PLL_BASE': 1, 'DCM_SP': 0},
    'mini': {'top': 'radio86rk_mini', 'i_freq': 1, 'hdmi_out_xilinx': 1, 'PLL_BASE': 1, 'DCM_SP': 1},
    'minig': {'top': 'radio86rk_minig', 'i_freq': 1, 'hdmi_out_xilinx': 1, 'PLL_BASE': 1, 'DCM_SP': 1},
}
# Coregen memories: collision check off in the sim copies (F7c)
COREGEN_MEMS = ('rambuffer', 'font', 'osd_vram', 'rom_font')
POWER_UP_SOURCE = ('power-up values and the X-check table come from build/ref/pr07-baseline (the netlists of '
                   'a9685c7), not from the F15/F23 path build/ref/machine-baseline (deviation from the plan text)')
MACROS_SYM3 = ("macros SYMBOLS[3]: read at symbol_index 3 (out of range of [0:2]) at the last macro step: X in "
               "RTL; XST: symbol bits 0,2,4,6,7 are constant 0 (pr07-baseline/go radio86rk.syr 1769-1773), bits "
               "1,3,5 are not determined by the .syr -> 0; sim copy SYMBOLS[3] = 8'h00")
# top nets wired to mcu outputs but declared reg (#2)
MCU_OUT_REGS = ('fileloader_reset', 'fileloader_wr', 'fileloader_addr', 'loader_ram_a', 'fileloader_data',
                'loader_ram_do')
F13 = ('k580wg75.v: Xst:3035 "Index value(s) does not match array range for signal <buf0>/<buf1>, simulation '
       'mismatch": obuf = lineff ? buf0[opos] : buf1[opos] with opos > 79 is X in RTL, some value in hardware; '
       'it never reaches an output (ochar <= 0 when opos > maxx). No sim copy.')


def die(msg):
    sys.stderr.write('gen_sim: ERROR: %s\n' % msg)
    sys.exit(2)


def read(path):
    with open(path, newline='') as f:
        return f.read()


def write(path, text):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, 'w', newline='') as f:
        f.write(text)


def sha256(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()


def rel(path, base):
    return os.path.relpath(path, base).replace(os.sep, '/')


def read_tsv(path):
    rows, hdr = [], None
    for line in open(path, newline=''):
        line = line.rstrip('\r\n')
        if not line.strip() or line.startswith('#'):
            continue
        cols = line.split('\t')
        if hdr is None:
            hdr = cols
            continue
        rows.append(dict(zip(hdr, cols + [''] * (len(hdr) - len(cols)))))
    return rows


# --------------------------------------------------------------------------- Coregen check (A6)

def check_ipcore(rev_dir, ref_dir, ipcore_dir, prj_ip, log):
    """A6: xco + coe of the revision == the ipcore source revision; mif == coe; prj cores allowed."""
    def xcos(root):
        base = os.path.join(root, 'src', 'ipcore')
        res = {}
        for d, _, fs in os.walk(base):
            for f in fs:
                if f.endswith('.xco'):
                    res[rel(os.path.join(d, f), base)] = os.path.join(d, f)
        return res
    rx, fx = xcos(rev_dir), xcos(ref_dir)
    if sorted(rx) != sorted(fx):
        die('src/ipcore/**/*.xco differ from the ipcore source revision: %s vs %s' % (sorted(rx), sorted(fx)))
    allowed, mifs = {}, {}
    for k in sorted(rx):
        if read(rx[k]).encode() != read(fx[k]).encode():
            die('src/ipcore/%s differs from the ipcore source revision (rebuild the cores)' % k)
        log.append('xco equal: src/ipcore/%s (sha256 %s)' % (k, sha256(rx[k])))
        t = read(rx[k])
        comp = re.search(r'(?m)^CSET component_name=(\S+)', t).group(1)
        allowed[(os.path.dirname(k) + '/' if os.path.dirname(k) else '') + comp + '.v'] = k
        m = re.search(r'(?m)^CSET coe_file=(\S+)', t)
        if m and m.group(1) != 'no_coe_file_loaded':
            if m.group(1).startswith('/'):
                die('src/ipcore/%s: absolute coe path %s' % (k, m.group(1)))
            coe_rev = os.path.normpath(os.path.join(os.path.dirname(rx[k]), m.group(1)))
            coe_ref = os.path.normpath(os.path.join(os.path.dirname(fx[k]), m.group(1)))
            if not os.path.isfile(coe_rev) or not os.path.isfile(coe_ref):
                die('coe file of src/ipcore/%s missing: %s' % (k, m.group(1)))
            if sha256(coe_rev) != sha256(coe_ref):
                die('%s differs from the ipcore source revision (rebuild the cores)' % rel(coe_rev, rev_dir))
            log.append('coe equal: %s (sha256 %s)' % (rel(coe_rev, rev_dir), sha256(coe_rev)))
            mifs[comp] = coe_rev
    for p in prj_ip:
        if p not in allowed:
            die('.prj references ipcore_dir/%s, which is not a core of src/ipcore' % p)
        if not os.path.isfile(os.path.join(ipcore_dir, p)):
            die('core wrapper missing: %s' % os.path.join(ipcore_dir, p))
    mif_files = []
    for p in prj_ip:
        t = read(os.path.join(ipcore_dir, p))
        for m in re.finditer(r'\.C_INIT_FILE_NAME\("([^"]+\.mif)"\)', t):
            comp = os.path.splitext(m.group(1))[0]
            mif = os.path.join(ipcore_dir, os.path.dirname(p), m.group(1))
            if comp not in mifs or not os.path.isfile(mif):
                die('%s: %s without a coe of the same core' % (p, m.group(1)))
            got = [int(x, 2) for x in read(mif).split()]
            want = mkhex.coe_values(mifs[comp])
            if got != want:
                die('%s is not coe2hex(%s) (rebuild the cores)' % (rel(mif, ipcore_dir), rel(mifs[comp], rev_dir)))
            log.append('mif equal to coe2hex: %s = %s (%d words)' % (rel(mif, ipcore_dir), rel(mifs[comp], rev_dir),
                                                                     len(got)))
            mif_files.append(mif)
    return mif_files


# --------------------------------------------------------------------------- the tree

class Src(object):
    def __init__(self, lang, key, path):
        self.lang, self.key, self.path = lang, key, path   # key: logical path (src/..., modules/..., ipcore_dir/...)
        self.text = read(path)
        self.orig = self.text
        self.extra = []       # [(key, text)] generated files placed after this one in the prj

    @property
    def changed(self):
        return self.text != self.orig


def parse_units(srcs):
    units = {}
    for s in srcs:
        us = hdl.vhdl_units(s.text, s.key) if s.lang == 'vhdl' else hdl.verilog_units(s.text, s.key)
        for u in us:
            u.src = s
            if u.name.lower() in units:
                die('unit %s defined twice (%s, %s)' % (u.name, units[u.name.lower()].src.key, s.key))
            units[u.name.lower()] = u
    return units


def unit_src(units, name):
    u = units.get(name.lower())
    return u.src if u else None


PRIMS = ('PLL_BASE', 'DCM_SP')


def fill_insts(units):
    """Verilog instances of known units and of the clock primitives."""
    known = set(u.name for u in units.values()) | set(PRIMS)
    for u in units.values():
        if u.lang == 'verilog':
            u.insts = hdl.verilog_insts(u, u.src.text, known)


def inst_counts(srcs, units, top):
    """Number of instances of every unit / primitive in the hierarchy under <top> (lower-case keys)."""
    fill_insts(units)
    counts = {}

    def walk(u, mult, depth):
        if depth > 50:
            die('instance hierarchy too deep at %s' % u.name)
        counts[u.name.lower()] = counts.get(u.name.lower(), 0) + mult
        for inst, mod in u.insts:
            if mod in PRIMS:
                counts[mod] = counts.get(mod, 0) + mult
                continue
            v = units.get(mod.lower())
            if v is not None:
                walk(v, mult, depth + 1)
    walk(units[top.lower()], 1, 0)
    return counts


def instances_of(units, name):
    """[(parent unit, instance label)] of the unit <name> (case-insensitive) in all units."""
    res = []
    for u in units.values():
        for inst, mod in u.insts:
            if mod.lower() == name.lower():
                res.append((u, inst))
    return res


def port_dir(unit, port):
    if unit.lang == 'verilog':
        return {'input': 'in', 'output': 'out', 'inout': 'inout'}.get(unit.vports.get(port))
    d = unit.ports.get(port.lower())
    return d.mode if d else None


def refs(expr, name):
    return re.search(r'(?<![\w.$])%s\b' % re.escape(name), expr or '') is not None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('rev_dir')
    ap.add_argument('tb_dir')
    ap.add_argument('board', choices=sorted(BOARDS))
    ap.add_argument('out_dir')
    ap.add_argument('--ipcore-dir', required=True)
    ap.add_argument('--ipcore-ref', required=True)
    ap.add_argument('--ipcore-sha', default='3fdb64f')
    ap.add_argument('--rev-sha', default='?')
    ap.add_argument('--tb-sha', default='?')
    ap.add_argument('--tb', action='append', help='TB file relative to <tb_dir> (default src/sim/sys/tb_sys.v)')
    ap.add_argument('--tb-top', default='tb_sys')
    ap.add_argument('--power-up', help='default <tb_dir>/src/sim/sys/power_up.tsv')
    ap.add_argument('--power-up-map', help='per-comparison override: signal <TAB> candidate modules')
    ap.add_argument('--xcheck-regs', help='default <tb_dir>/src/sim/sys/xcheck_regs.tsv')
    ap.add_argument('--xcheck-map', help='per-comparison override: id <TAB> candidate modules')
    a = ap.parse_args()

    rev, tbd, out = [os.path.abspath(x) for x in (a.rev_dir, a.tb_dir, a.out_dir)]
    sysdir = os.path.join(tbd, 'src', 'sim', 'sys')
    board = BOARDS[a.board]
    top = board['top']
    j = subst.Journal()
    checks = []

    # ---- the project of the revision
    prj = os.path.join(rev, 'src', top + '.prj')
    srcs, prj_ip = [], []
    for line in open(prj, newline=''):
        m = re.match(r'^\s*(verilog|vhdl)\s+(\w+)\s+"([^"]+)"', line)
        if not m:
            continue
        if m.group(2) != 'work':
            die('%s: library %s is not supported' % (prj, m.group(2)))
        p = m.group(3)
        if p.startswith('ipcore_dir/'):
            key = p
            path = os.path.join(os.path.abspath(a.ipcore_dir), p[len('ipcore_dir/'):])
            prj_ip.append(p[len('ipcore_dir/'):])
        else:
            path = os.path.normpath(os.path.join(rev, 'src', p))
            key = rel(path, rev)
            if key.startswith('..'):
                die('%s: %s is outside the revision' % (prj, p))
        if not os.path.isfile(path):
            die('%s: missing %s' % (prj, path))
        srcs.append(Src(m.group(1), key, path))
    shafile = os.path.join(os.path.abspath(a.ipcore_ref), 'EXPORT_SHA')
    if not os.path.isfile(shafile):
        die('%s missing: the ipcore reference export must record its commit' % shafile)
    ref_sha = read(shafile).strip()
    if not (len(a.ipcore_sha) >= 7 and ref_sha.startswith(a.ipcore_sha)):
        die('ipcore reference is an export of %s, not of --ipcore-sha %s' % (ref_sha, a.ipcore_sha))
    checks.append('ipcore reference export: %s (EXPORT_SHA) = --ipcore-sha %s' % (ref_sha, a.ipcore_sha))
    mif_files = check_ipcore(rev, os.path.abspath(a.ipcore_ref), os.path.abspath(a.ipcore_dir), prj_ip, checks)

    units = parse_units(srcs)
    if top.lower() not in units:
        die('top %s not found in %s' % (top, prj))
    counts = inst_counts(srcs, units, top)

    def need(name):
        s = unit_src(units, name)
        if s is None:
            die('unit %s not found in the project' % name)
        return s

    # ---- #1 macros: localparam array -> reg array + initial
    s = need('macros')

    def lp_array(m):
        vals = [v.strip() for v in m.group(5).split(',')]
        lo, hi = int(m.group(3)), int(m.group(4))
        idx = range(lo, hi + 1) if lo <= hi else range(lo, hi - 1, -1)
        if len(vals) != len(list(idx)):
            raise SubstError('#1 %s: %d values for [%s:%s]' % (s.key, len(vals), lo, hi))
        init = ' '.join('%s[%d] = %s;' % (m.group(2), i, v) for i, v in zip(idx, vals))
        return 'reg %s %s [%s:%s]; initial begin %s end // sim copy: ISim has no localparam arrays' % (
            m.group(1), m.group(2), m.group(3), m.group(4), init)
    s.text = j.sub(1, s.key, s.text,
                   r'localparam\s*(\[[^\]]+\])\s*(\w+)\s*\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*=\s*\{([^}]*)\}\s*;',
                   lp_array, 1, 'localparam array -> reg array + initial (ISim: no localparam arrays)')
    # #13 SYMBOLS[3]: the synthesized value of the out-of-range read (F7a)
    mu = units['macros']
    si = mu.regs.get('symbol_index')
    if si is None or si.width() != 2 or not re.search(r'\bSYMBOLS\s*\[\s*symbol_index\s*\]', s.text):
        die('#13 %s: expected SYMBOLS[symbol_index] with a 2-bit symbol_index' % s.key)
    s.text = j.sub(13, s.key, s.text, r'reg (\[7:0\]) SYMBOLS \[0:2\]; initial begin ',
                   r"reg \1 SYMBOLS [0:3]; initial begin SYMBOLS[3] = 8'h00; ", 1, MACROS_SYM3)

    # ---- #2 top: reg -> wire on nets driven by mcu outputs
    s = need(top)
    names_rx = '|'.join(MCU_OUT_REGS)
    decl_rx = r'(?m)^([ \t]*)reg(\s*(?:\[[^\]]*\])?\s*)((?:%s)\b[^;]*;)' % names_rx
    for m in re.finditer(decl_rx, s.text):
        for nm in [x.strip() for x in m.group(3).rstrip(';').split(',')]:
            if nm not in MCU_OUT_REGS:
                raise SubstError('#2 %s: declaration %r also declares %s' % (s.key, m.group(0).strip(), nm))
    s.text = j.sub(2, s.key, s.text, decl_rx, r'\1wire\2\3', 4,
                   'reg -> wire on the nets driven by mcu outputs (%s)' % ', '.join(MCU_OUT_REGS))
    for nm in MCU_OUT_REGS:
        if not re.search(r'(?m)^[ \t]*wire\s*(?:\[[^\]]*\])?\s*[^;]*\b%s\b' % nm, s.text):
            raise SubstError('#2 %s: %s not declared wire after the substitution' % (s.key, nm))

    # ---- #3 / #4 hid_parser: width adapter (GND into the core, JOY_DO(0) out); sensitivity list
    s = need('hid_parser')
    core, wrap = subst.vhdl_width_adapter(j, 3, s.key, s.text, 'hid_parser', {
        'JOY_TYPE_L': ('std_logic_vector(2 downto 0)', 'std_logic', "(others => '0')"),
        'JOY_TYPE_R': ('std_logic_vector(2 downto 0)', 'std_logic', "(others => '0')"),
        'JOY_DO': ('std_logic_vector(7 downto 0)', 'std_logic', '(0)'),
    })
    core = j.sub(4, s.key, core, r'(?i)process\s*\(\s*kb_data\s*,\s*A\s*\)', 'process( kb_data, A, KB_STATUS)',
                 {0, 1}, 'process( kb_data, A) -> process( kb_data, A, KB_STATUS) (HDLCompiler:92; XST reads '
                 'KB_STATUS)')
    # every combinational process of the core that reads KB_STATUS must have it in its sensitivity list
    cu = [x for x in hdl.vhdl_units(core, s.key) if x.name.lower() == 'hid_parser_core'][0]
    sens_ok = []
    for label, sens, body in hdl.vhdl_processes(core, cu):
        if not re.search(r'(?i)\bKB_STATUS\b', body):
            continue
        if re.search(r"(?i)\b(rising_edge|falling_edge)\b|'event\b", body) or sens is None:
            continue
        if 'kb_status' not in sens:
            die('#4 %s: process (%s) reads KB_STATUS but its sensitivity list is (%s)'
                % (s.key, label or 'unlabelled', ', '.join(sens)))
        sens_ok.append('(%s)' % ', '.join(sens))
    checks.append('#4 hid_parser_core: combinational processes reading KB_STATUS have it in the sensitivity list: %s'
                  % ('; '.join(sens_ok) or 'none read it'))
    s.text = core
    s.extra.append((os.path.splitext(s.key)[0] + '_wrap.vhd', wrap))

    # ---- #5 mcu: buffer ports -> wrapper with out ports
    s = need('mcu')
    core, wrap = subst.vhdl_buffer_wrapper(j, 5, s.key, s.text, 'mcu', 8)
    s.text = core
    s.extra.append((os.path.splitext(s.key)[0] + '_wrap.vhd', wrap))

    # ---- #6 k580ww55: always without event control
    s = need('k580ww55')
    s.text = j.sub(6, s.key, s.text, r'\balways\s+begin\b', 'always @(*) begin', 1,
                   'always begin -> always @(*) begin (ISim hangs at 0 ns)')

    # ---- #7 HDMI I_FREQ literal width
    s = need(top)
    s.text = j.sub(7, s.key, s.text, r'\.I_FREQ\s*\(\s*40\s*\)', ".I_FREQ(8'd40)", board['i_freq'],
                   ".I_FREQ(40) -> .I_FREQ(8'd40) (32-bit literal on an 8-bit VHDL port; XST truncates)")

    # ---- #8 hdmi_out_xilinx mod5 power-up (expected per board, counted on instances)
    n8 = counts.get('hdmi_out_xilinx', 0)
    if n8 != board['hdmi_out_xilinx']:
        die('#8: %d instances of hdmi_out_xilinx under %s, expected %d for %s'
            % (n8, top, board['hdmi_out_xilinx'], a.board))
    checks.append('#8 instances of hdmi_out_xilinx: %d (expected %d)' % (n8, board['hdmi_out_xilinx']))
    if n8:
        s = need('hdmi_out_xilinx')
        s.text = j.sub(8, s.key, s.text,
                       r'(?i)(signal\s+mod5\s*:\s*std_logic_vector\s*\(\s*2\s+downto\s+0\s*\))\s*;',
                       r'\1 := "000"; -- sim copy: FD INIT 0', 1,
                       'signal mod5 : std_logic_vector(2 downto 0) -> := "000" (FD INIT 0; TMDS X forever)')
    else:
        j.note(8, '-', 'hdmi_out_xilinx not in the design', found=0, expected=0)

    # ---- #9 collision check off in all Coregen memories
    for mem in COREGEN_MEMS:
        s = need(mem)
        s.text = j.sub(9, s.key, s.text, r'\.C_SIM_COLLISION_CHECK\("ALL"\)', '.C_SIM_COLLISION_CHECK("NONE")', 1,
                       'C_SIM_COLLISION_CHECK("ALL") -> ("NONE"): the behavioural model gives X on a port collision, '
                       'the hardware deterministic data by the write mode')

    # ---- #10 ideal clock models (work shadows unisims_ver), expected per board
    models = []
    for prim, f in (('PLL_BASE', 'pll_base_ideal.v'), ('DCM_SP', 'dcm_sp_ideal.v')):
        n = counts.get(prim, 0)
        if n != board[prim]:
            die('#10: %d instances of %s under %s, expected %d for %s' % (n, prim, top, board[prim], a.board))
        checks.append('#10 instances of %s: %d (expected %d)' % (prim, n, board[prim]))
        if n:
            models.append(('sim/models/' + f, read(os.path.join(sysdir, 'models', f))))
            j.note(10, 'sim/models/' + f, 'ideal %s model in work (shadows unisims_ver; declared divergence F11), '
                   '%d instance(s)' % (prim, n), found=n, expected=board[prim], kind='model')

    # ---- re-parse the substituted texts (core names map back to the logical modules)
    allsrc = srcs + []
    extra_srcs = []
    for s in srcs:
        for key, text in s.extra:
            e = Src.__new__(Src)
            e.lang, e.key, e.path, e.text, e.orig, e.extra = 'vhdl', key, None, text, None, []
            extra_srcs.append(e)
    units = parse_units(srcs + extra_srcs)
    fill_insts(units)
    logical = {}
    for k, u in units.items():
        logical[k] = u
    core_of = {}       # renamed core -> the logical name its wrapper carries
    for name in ('mcu', 'hid_parser'):
        logical[name] = units[name + '_core']
        core_of[name + '_core'] = name
    edits = {}         # src key -> [(start, end, text)]
    vblocks = {}       # unit name -> [text] inserted before endmodule / end architecture

    def add_block(u, text):
        vblocks.setdefault(u.name.lower(), (u, []))[1].append(text)

    # ---- #12 cpu_int: sourceless wire -> force 0 (as XST: Xst:653 -> GND); stop if it has a driver
    hits = [u for u in units.values() if u.lang == 'verilog' and 'cpu_int' in u.wires]
    if len(hits) != 1:
        die('#12: wire cpu_int declared in %d modules (%s), expected 1' % (len(hits), [u.name for u in hits]))
    cu = hits[0]
    cb = hdl.blank_comments_v(cu.src.text)[cu.start:cu.end]
    drivers = []
    if re.search(r'\bassign\b[^;]*?(?<![\w.$])cpu_int\b[^;=]*=', cb):
        drivers.append('continuous assignment')
    if re.search(r'\bwire\b[^;]*(?<![\w.$])cpu_int\s*=', cb):
        drivers.append('declaration assignment')
    conn_notes = []
    for inst, mod in cu.insts:
        conns = None
        if mod in PRIMS:
            conns = hdl.verilog_inst_conns(cu.src.text, cu, mod, inst)
            child = None
        else:
            child = units.get(mod.lower())
            conns = hdl.verilog_inst_conns(cu.src.text, cu, mod, inst)
        for port, actual in (conns or {}).items():
            if not refs(actual, 'cpu_int'):
                continue
            d = port_dir(child, port) if child is not None else None
            conn_notes.append('%s.%s (%s)' % (inst, port, d or 'unknown direction'))
            if d != 'in':
                drivers.append('instance %s port %s (%s)' % (inst, port, d or 'unknown direction'))
    if drivers:
        die('#12 %s: cpu_int has a driver in module %s: %s' % (cu.src.key, cu.name, '; '.join(drivers)))
    add_block(cu, "initial force cpu_int = 1'b0; // sim copy: sourceless net, Xst:653 -> GND")
    j.note(12, cu.src.key, "module %s: initial force cpu_int = 1'b0 (sourceless, Xst:653 -> GND)" % cu.name)
    checks.append('#12 cpu_int in %s: no continuous or declaration assignment, no instance output; loads: %s'
                  % (cu.name, ', '.join(conn_notes) or 'none'))

    def row_key(name, cands):
        return '%s@%s' % (name, cands[0]) if cands else name

    # ---- #11 power-up values (A3, A4)
    pu_path = a.power_up or os.path.join(sysdir, 'power_up.tsv')
    pu_rows = read_tsv(pu_path)
    override = {}
    if a.power_up_map:
        for r in read_tsv(a.power_up_map):
            override[r['signal']] = r['modules']
    placed, verdicts = [], []
    vhdl_init = {}     # unit -> [(decl, value)]
    v_init = {}        # unit -> [(sig, value)]
    for r in pu_rows:
        sig, value = r['signal'], r['value']
        base = [x.strip() for x in r['modules'].split(',') if x.strip()]
        ov = override.get(row_key(sig, base), override.get(sig))
        cands = [x.strip() for x in (ov or r['modules']).split(',') if x.strip()]
        hits = []
        for c in cands:
            u = logical.get(c.lower())
            if u is None:
                continue
            d = u.regs.get(sig) if u.lang == 'verilog' else (u.regs.get(sig.lower()) or u.ports.get(sig.lower()))
            if d is not None and (u.lang == 'verilog' or d.kind == 'signal' or d.mode in ('out', 'buffer', 'inout')):
                hits.append((c, u, d))
        if len(hits) != 1:
            die('power-up row %s (%s): %d matches in %s, expected exactly 1'
                % (sig, ','.join(cands), len(hits), [h[0] for h in hits]))
        c, u, d = hits[0]
        rtl, partial = None, False
        if u.lang == 'verilog':
            if d.init is not None:
                rtl = d.init
            else:
                ws = hdl.verilog_initial_writes(u.src.text, u, d.name)
                whole = [w for w in ws if not w[2]]
                if whole:
                    rtl = whole[0][0]
                elif ws:
                    rtl, partial = '; '.join('%s%s = %s' % (d.name, w[2], w[0]) for w in ws), True
        elif d.init is not None:
            rtl = ' '.join(d.init.split())
        where = '%s.%s (%s)' % (c, d.name, u.src.key)
        if rtl is not None:
            status = 'RTL INITIALIZER (%s.%s) = %s' % (c, d.name, rtl)
            verdicts.append(status)
            same = None if partial else hdl.same_value(rtl, value, d.width())
            if same is False:
                verdicts.append('POWER-UP DIFFERS (%s.%s: RTL %s, table %s)' % (c, d.name, rtl, value))
            elif same is None:
                verdicts.append('POWER-UP UNCOMPARED (%s.%s: RTL %s, table %s)' % (c, d.name, rtl, value))
            placed.append('%s -> %s: kept %s' % (sig, where, status))
            continue
        if u.lang == 'verilog':
            v_init.setdefault(u.name.lower(), (u, []))[1].append((d.name, value))
        else:
            vhdl_init.setdefault(u.name.lower(), (u, []))[1].append((d, value))
        placed.append('%s -> %s = %s (%s)' % (sig, where, value, r.get('source', '')))
    for k, (u, lst) in v_init.items():
        add_block(u, 'initial begin // sim copy: power-up values of the hardware (src/sim/sys/power_up.tsv)\n%s\nend'
                  % '\n'.join('\t%s = %s;' % x for x in lst))
        j.note(11, u.src.key, 'module %s: power-up initial block, %d registers (%s)'
               % (u.name, len(lst), ', '.join(x[0] for x in lst)), found=len(lst), expected=len(lst), kind='powerup')
    for k, (u, lst) in vhdl_init.items():
        for d, value in lst:
            try:
                lit = hdl.vhdl_literal(value, d)
            except ValueError as e:
                die('power-up %s.%s: %s' % (u.name, d.name, e))
            edits.setdefault(u.src.key, []).append(subst.vhdl_decl_edit(u.src.text, u, d, lit))
        j.note(11, u.src.key, 'entity %s: power-up default values, %d signals/ports (%s)'
               % (u.name, len(lst), ', '.join(x[0].name for x in lst)), found=len(lst), expected=len(lst),
               kind='powerup')

    # ---- X-checkers (A5): one row per logical register, applied exactly once per revision
    xc_path = a.xcheck_regs or os.path.join(sysdir, 'xcheck_regs.tsv')
    xrows = read_tsv(xc_path)
    xover = {}
    if a.xcheck_map:
        for r in read_tsv(a.xcheck_map):
            xover[r['id']] = r['modules']
    vlines, hlines = {}, {}      # unit -> Verilog / VHDL checker lines
    xc_land, xc_exempt, xc_other = [], [], 0
    numeric_rx = r'(?im)^\s*use\s+ieee\.numeric_std\.all\s*;'

    def vhdl_check(u, expr, label, decl_typ):
        """VHDL checker line(s) for a readable object of type decl_typ, or None (never X), or die."""
        typ = ' '.join((decl_typ or '').split())
        inc = 'work.sim_xcheck_pkg.xcount := work.sim_xcheck_pkg.xcount + 1;'
        rep = 'report "XCHECK %s (" & %s\'path_name & ")" severity note;' % (label, expr.split('(')[0])
        if re.match(r'^std_u?logic(_vector\s*\(.*\))?$', typ, re.I):
            return ['\tif is_x(%s) then %s %s end if;' % (expr, rep, inc)]
        if re.match(r'^(un)?signed\s*\(.*\)$', typ, re.I) and re.search(numeric_rx, u.src.text):
            return ['\tif is_x(std_logic_vector(%s)) then %s %s end if;' % (expr, rep, inc)]
        if re.match(r'^(integer|natural|positive|boolean)\b', typ, re.I):
            return None
        if re.search(r'(?is)\btype\s+%s\s+is\s*\(' % re.escape(typ), hdl.blank_comments_vhdl(u.src.text)):
            return None      # enumeration type: no X value, starts at its leftmost literal
        elem = hdl.vhdl_array_elem(u.src.text, u, typ)
        if elem and re.match(r'^std_u?logic(_vector)?$', elem, re.I):
            return ['\tfor i in %s\'range loop if is_x(%s(i)) then %s %s exit; end if; end loop;'
                    % (expr, expr, rep, inc)]
        die('X-check %s: type %r of %s is not supported' % (label, decl_typ, expr))

    def verilog_check(expr, label):
        return ('\tif (^(%s) === 1\'bx) begin $display("XCHECK %%m.%s = %%b", %s); '
                'sim_ctl.xcount = sim_ctl.xcount + 1; end' % (expr, label, expr))

    for r in xrows:
        boards = [x.strip() for x in r['boards'].split(',') if x.strip()]
        if a.board not in boards:
            xc_other += 1
            continue
        reg = r['register']
        cands = [x.strip() for x in xover.get(r['id'], r['modules']).split(',') if x.strip()]
        hits = []
        for c in cands:
            u = logical.get(c.lower())
            if u is None:
                continue
            d = u.regs.get(reg) if u.lang == 'verilog' else (u.regs.get(reg.lower()) or u.ports.get(reg.lower()))
            if d is not None and (u.lang == 'verilog' or d.kind == 'signal' or d.mode in ('out', 'buffer', 'inout')):
                hits.append((c, u, d))
        if len(hits) != 1:
            die('X-check row %s (candidates %s): declared in %d of them %s, expected exactly 1'
                % (r['id'], ','.join(cands), len(hits), [h[0] for h in hits]))
        c, u, d = hits[0]
        where = '%s.%s (%s)' % (c, d.name, u.src.key)
        if u.lang == 'verilog':
            if d.kind == 'mem':
                if not d.dims:
                    die('X-check %s: memory without numeric bounds' % where)
                lo, hi = sorted(int(x) for x in d.dims[0])
                vlines.setdefault(u.name.lower(), (u, []))[1].append(
                    '\tfor (sim_xc_i = %d; sim_xc_i <= %d; sim_xc_i = sim_xc_i + 1) if (^%s[sim_xc_i] === 1\'bx) '
                    'begin $display("XCHECK %%m.%s[%%0d] = %%b", sim_xc_i, %s[sim_xc_i]); '
                    'sim_ctl.xcount = sim_ctl.xcount + 1; end' % (lo, hi, d.name, d.name, d.name))
                xc_land.append('%s -> %s, memory [%d:%d]' % (r['id'], where, lo, hi))
            else:
                vlines.setdefault(u.name.lower(), (u, []))[1].append(verilog_check(d.name, d.name))
                xc_land.append('%s -> %s' % (r['id'], where))
            continue
        if d.kind == 'signal' or d.mode in ('buffer', 'inout'):
            ls = vhdl_check(u, d.name, '%s.%s' % (c, d.name), d.typ)
            if ls is None:
                xc_exempt.append('%s -> %s: type %s, never X' % (r['id'], where, d.typ))
            else:
                hlines.setdefault(u.name.lower(), (u, []))[1].extend(ls)
                xc_land.append('%s -> %s' % (r['id'], where))
            continue
        # VHDL out port: not readable inside (VHDL-93); check the net in every instantiating parent
        # (up the hierarchy while the actual is again an out port of a VHDL parent)
        def check_out(cname, port, path, depth):
            if depth > 10:
                die('X-check %s: out-port chain too long' % where)
            parents = instances_of(units, cname)
            if not parents:
                die('X-check %s: out port %s.%s, but no instance of %s found' % (where, cname, port, cname))
            for pu, inst in parents:
                label = '%s.%s.%s' % (path, inst, port) if path else '%s.%s' % (inst, port)
                if pu.lang == 'verilog':
                    conns = hdl.verilog_inst_conns(pu.src.text, pu, cname, inst) or {}
                    actual = [v for k, v in conns.items() if k.lower() == port.lower()]
                    if not actual or not actual[0]:
                        die('X-check %s: out port %s unconnected in %s instance %s' % (where, port, pu.name, inst))
                    vlines.setdefault(pu.name.lower(), (pu, []))[1].append(verilog_check(actual[0], label))
                    xc_land.append('%s -> %s, out port: checked on the net %s of %s (instance %s)'
                                   % (r['id'], where, actual[0], pu.name, inst))
                    continue
                conns = hdl.vhdl_inst_conns(pu.src.text, pu, inst) or {}
                actual = conns.get(port.lower())
                if not actual or actual.lower() == 'open':
                    die('X-check %s: out port %s unconnected in %s instance %s' % (where, port, pu.name, inst))
                base = re.match(r'^(\w+)', actual).group(1)
                pd = pu.regs.get(base.lower()) or pu.ports.get(base.lower())
                if pd is not None and pd.kind == 'port' and pd.mode == 'out' and actual == base:
                    check_out(pu.name if pu.name.lower() not in core_of else core_of[pu.name.lower()],
                              pd.name, label, depth + 1)
                    continue
                if pd is None or (pd.kind == 'port' and pd.mode not in ('buffer', 'inout')):
                    die('X-check %s: the actual %s in %s is not a readable signal' % (where, actual, pu.name))
                typ = pd.typ if actual == base else ('std_logic_vector(0 downto 0)'
                                                     if re.search(r'downto|\bto\b', actual) else 'std_logic')
                ls = vhdl_check(pu, actual, label, typ)
                hlines.setdefault(pu.name.lower(), (pu, []))[1].extend(ls or [])
                xc_land.append('%s -> %s, out port: checked on the signal %s of %s (instance %s)'
                               % (r['id'], where, actual, pu.name, inst))
        check_out(c, d.name, '', 0)
    xc_total = 0
    for k, (u, lines) in vlines.items():
        add_block(u, 'integer sim_xc_i;\nalways @(posedge sim_ctl.xcheck) begin // sim copy: X-check '
                     '(src/sim/sys/xcheck_regs.tsv)\n%s\nend' % '\n'.join(lines))
        xc_total += len(lines)
        j.note('X', u.src.key, 'module %s: X-checker, %d checks' % (u.name, len(lines)), found=len(lines),
               expected=len(lines), kind='xcheck')
    for k, (u, lines) in hlines.items():
        add_block(u, 'sim_xcheck_p : process -- sim copy: X-check (src/sim/sys/xcheck_regs.tsv)\nbegin\n'
                     '\twait until work.sim_xcheck_pkg.xcheck = \'1\';\n%s\nend process;' % '\n'.join(lines))
        xc_total += len(lines)
        j.note('X', u.src.key, 'entity %s: X-checker, %d checks' % (u.name, len(lines)), found=len(lines),
               expected=len(lines), kind='xcheck')

    # ---- declared: inputs of VHDL entities left unconnected by a Verilog parent (F7b)
    undriven = []
    for pu in units.values():
        if pu.lang != 'verilog':
            continue
        for inst, mod in pu.insts:
            cu2 = units.get(mod.lower())
            if cu2 is None or cu2.lang != 'vhdl':
                continue
            conns = dict((k.lower(), v) for k, v in (hdl.verilog_inst_conns(pu.src.text, pu, mod, inst) or {}).items())
            open_in = []
            for p in cu2.port_items:
                if p.mode == 'in' and not conns.get(p.name.lower()):
                    open_in.append("%s (%s)" % (p.name, ('default ' + ' '.join(p.init.split())) if p.init else "'U'"))
            if open_in:
                undriven.append("%s.%s (entity %s): %d unconnected inputs: %s; XST ties them to GND (Xst:2898), "
                                "the simulation keeps the VHDL default or 'U'"
                                % (pu.name, inst, cu2.name, len(open_in), ', '.join(open_in)))

    # ---- apply the blocks and edits
    for k, (u, blocks) in vblocks.items():
        if u.lang == 'verilog':
            pos = u.end
        else:
            pos = subst.vhdl_arch_end(u.src.text, u)
        body = '\n'.join(blocks)
        if u.lang == 'verilog':
            text = '\n// ---- sim copy additions (src/sim/sys/gen/gen_sim.py)\n%s\n' % body
        else:
            text = '\n-- ---- sim copy additions (src/sim/sys/gen/gen_sim.py)\n%s\n' % body
        edits.setdefault(u.src.key, []).append((pos, pos, text))
    bykey = dict((s.key, s) for s in srcs + extra_srcs)
    for key, ed in edits.items():
        if '\r\n' in bykey[key].text:   # keep the line ends of the file
            ed = [(s0, e0, t.replace('\r\n', '\n').replace('\n', '\r\n')) for s0, e0, t in ed]
        bykey[key].text = subst.apply_edits(bykey[key].text, ed)

    # ---- write the tree: everything of an earlier generation or run goes (isim/, tb.exe, .mif, logs);
    # only the export of the revision stays
    if os.path.isdir(out):
        for name in os.listdir(out):
            p = os.path.join(out, name)
            if os.path.abspath(p) == rev:
                continue
            if os.path.isdir(p) and not os.path.islink(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
    prj_lines = []
    support = [('vhdl', 'sim/support/sim_xcheck.vhd', read(os.path.join(sysdir, 'sim_xcheck.vhd')))]
    for lang, key, text in support:
        write(os.path.join(out, key), text)
        prj_lines.append('%s work "%s"' % (lang, key))
    rtl_hashes = []
    for s in srcs:
        if s.changed:
            key = 'sim/' + s.key
            write(os.path.join(out, key), s.text)
        elif s.key.startswith('ipcore_dir/'):
            key = s.key
            write(os.path.join(out, key), s.text)
        else:
            key = rel(s.path, out)
        prj_lines.append('%s work "%s"' % (s.lang, key))
        for ekey, _ in s.extra:
            e = bykey[ekey]
            write(os.path.join(out, 'sim', ekey), e.text)
            prj_lines.append('vhdl work "%s"' % ('sim/' + ekey))
        if s.path and not s.key.startswith('ipcore_dir/'):
            rtl_hashes.append('%s  %s' % (sha256(s.path), s.key))
    for key, text in models:
        write(os.path.join(out, key), text)
        prj_lines.append('verilog work "%s"' % key)
    write(os.path.join(out, 'sim/support/sim_ctl.v'), read(os.path.join(sysdir, 'sim_ctl.v')))
    prj_lines.append('verilog work "sim/support/sim_ctl.v"')
    tbs = a.tb or ['src/sim/sys/tb_sys.v']
    for t in tbs:
        src = os.path.join(tbd, t)
        if not os.path.isfile(src):
            die('TB file missing: %s' % src)
        key = 'tb/' + os.path.basename(t)
        write(os.path.join(out, key), read(src))
        prj_lines.append('verilog work "%s"' % key)
    for inc in ('board_go.vh', 'board_minig.vh', 'chain.vh'):
        p = os.path.join(sysdir, inc)
        if os.path.isfile(p):
            write(os.path.join(out, 'tb', inc), read(p))
    for m in mif_files:
        shutil.copyfile(m, os.path.join(out, os.path.basename(m)))
    roms = []
    romdir = os.path.join(rev, 'src', 'roms')
    for f in sorted(os.listdir(romdir)):
        if f.upper().endswith('.BIN'):
            n = mkhex.bin2hex(os.path.join(romdir, f), os.path.join(out, 'roms', os.path.splitext(f)[0] + '.hex'))
            roms.append('roms/%s.hex: %s, %d bytes' % (os.path.splitext(f)[0], f, n))
    write(os.path.join(out, 'run_sys_sim.sh'), read(os.path.join(sysdir, 'run_sys_sim.sh')))
    write(os.path.join(out, 'sim.prj'), '\n'.join(prj_lines) + '\n')
    write(os.path.join(out, 'sim.env'), 'BOARD=%s\nDEFINE=BOARD_%s\nTB_TOP=%s\nDUT_TOP=%s\n'
          % (a.board, a.board.upper(), a.tb_top, top))

    # ---- journal and summary
    write(os.path.join(out, 'subst.txt'),
          '# declared sim-copy substitutions: #num  file  change  count check\n' + '\n'.join(j.lines()) +
          '\n#F13\tsrc/rtl/k580wg75.v\t%s\tno sim copy\n' % F13)
    nsub = len(set(e['num'] for e in j.entries if e['kind'] in ('subst', 'model', 'powerup') and e['found']))
    sm = []
    sm.append('sim work tree: board %s, DUT top %s, TB top %s' % (a.board, top, a.tb_top))
    sm.append('revision %s; TB revision %s; ipcore source %s (%s)' % (a.rev_sha, a.tb_sha, a.ipcore_sha,
                                                                      os.path.abspath(a.ipcore_dir).replace(os.sep, '/')
                                                                      .split('/build/')[-1]))
    sm.append('')
    sm.append('SIMULATED != SYNTHESIZED (%d substitution kinds applied)' % nsub)
    for e in j.entries:
        if e['kind'] in ('subst', 'model', 'powerup') and e['found']:
            sm.append('  #%s %s: %s' % (e['num'], e['file'], e['desc']))
    sm.append('  #F13 %s' % F13)
    sm += ['  #U %s' % x for x in undriven]
    sm.append('')
    sm.append('SOURCE OF THE TABLES: %s' % POWER_UP_SOURCE)
    sm.append('')
    sm.append('POWER-UP (A3: where each row of %s landed)' % rel(pu_path, tbd).replace('\\', '/'))
    sm += ['  ' + x for x in placed]
    sm.append('')
    sm.append('VERDICTS')
    sm += ['  ' + x for x in verdicts] or ['  (none)']
    sm.append('')
    sm.append('X-CHECKERS (A5: where each row of %s landed; %d checks, trigger posedge sim_ctl.xcheck, '
              'count sim_ctl.xtotal)' % (rel(xc_path, tbd).replace('\\', '/'), xc_total))
    sm += ['  ' + x for x in xc_land]
    sm += ['  %s (exempt)' % x for x in xc_exempt]
    sm.append('  rows of other boards: %d' % xc_other)
    sm.append('')
    sm.append('CHECKS')
    sm += ['  ' + x for x in checks]
    sm += ['  ' + x for x in roms]
    sm.append('')
    sm.append('RTL FILES OF THE REVISION (sha256)')
    sm += ['  ' + x for x in rtl_hashes]
    write(os.path.join(out, 'summary.txt'), '\n'.join(sm) + '\n')
    print('gen_sim: %s -> %s: %d sources, %d substitution kinds, %d power-up rows, %d X-checked registers'
          % (a.board, out, len(prj_lines), nsub, len(pu_rows), xc_total))


if __name__ == '__main__':
    try:
        main()
    except SubstError as e:
        die(str(e))
