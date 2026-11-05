"""Power-up values of the hardware from an XST post-synthesis netlist (one-off, host).

Usage:
  python -B power_up_from_netlist.py <synth.v> <syr> --rev <dir> --board go|mini|minig
         --ipcore-dir <dir> [--source <label>] [--regs <out.tsv>] [--xcheck <out.tsv>] [--fsm <out.tsv>]

<dir> is an exported revision (src/ and modules/); its <top>.prj and RTL give the instance
hierarchy (netlist path -> module) and the register names of every module.

Every flip-flop / latch of the netlist is printed with its primitive, its INIT (explicit, or the
primitive default: FD/FDE/FDR/FDRE/FDC/FDCE/LD/LDC = 0, FDS/FDSE/FDP/FDPE/LDP = 1), its reset
class (async: CLR/PRE pin on a non-constant net; sync: R/S; none) and its RTL register:
  --regs    one row per RTL register: module, instance path, register, width, power-up bits
            (MSB..LSB, '-' = bit not in the netlist), primitives, reset class, INIT kind.
  --xcheck  the subset for the module-local X-checkers (A5): registers with a bit that has no
            async reset/set, or with an explicit INIT.
  --fsm     the FSMs of the .syr (State | Encoding) with the power-up state from the INIT of the
            state flip-flops (<reg>_FSM_FFd<n>, n = 1 is the leftmost encoding bit).
The latch triples of an async load (<reg>_<n>_P_<n> FDP, _C_<n> FDC, _LDC LDC) are folded into one
RTL bit through the XST multiplexer (bit = LDC ? P : C); the LUT of one bit is checked and printed.
LUT-RAM and SRL primitives are listed with their INIT.
"""
import argparse
import os
import re
import sys
from collections import OrderedDict, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hdl  # noqa: E402

TOPS = {'go': 'radio86rk', 'mini': 'radio86rk_mini', 'minig': 'radio86rk_minig'}
SET_TYPES = re.compile(r'^(FDS|FDSE|FDP|FDPE|LDP|LDPE)(_1)?$')
FF_TYPES = re.compile(r'^(FD|FDE|FDR|FDRE|FDS|FDSE|FDC|FDCE|FDP|FDPE|LD|LDE|LDC|LDCE|LDP|LDPE)(_1)?$')
RAM_TYPES = re.compile(r'^(RAM\d+X\d+[SD]|RAM32M|RAM64M|RAM128X1[SD]|RAM256X1S|SRLC?16E?|SRLC32E)$')


def parse_netlist(path):
    """-> list of (type, name, params text, {pin: net}), constant nets {net: 0/1}."""
    insts, const = [], {}
    lines = open(path).read().split('\n')
    i, n = 0, len(lines)
    head = re.compile(r'^\s*([A-Z][A-Z0-9_]*)\s*(#\(|(\\\S+|[A-Za-z_]\w*)\s*\()\s*$')
    while i < n:
        m = head.match(lines[i])
        if not m:
            i += 1
            continue
        typ, params = m.group(1), ''
        if m.group(2) == '#(':
            i += 1
            while i < n:
                params += lines[i]
                if lines[i].rstrip().endswith('))'):
                    break
                i += 1
            i += 1
            nm = re.match(r'^\s*(\\\S+|[A-Za-z_]\w*)\s*\(\s*$', lines[i])
            if not nm:
                i += 1
                continue
            name = nm.group(1)
        else:
            name = m.group(3)
        pins = {}
        i += 1
        body = []
        while i < n and not re.match(r'^\s*\);', lines[i]):
            body.append(lines[i])
            i += 1
        body = '\n'.join(body)
        for pm in re.finditer(r'\.(\w+)\(', body):
            c = hdl.match_paren(body, pm.end() - 1)
            pins[pm.group(1)] = ' '.join(body[pm.end():c].split())
        insts.append((typ, name.lstrip('\\'), params, pins))
        if typ == 'GND':
            const[pins.get('G')] = 0
        elif typ == 'VCC':
            const[pins.get('P')] = 1
        i += 1
    return insts, const


def init_of(typ, params):
    m = re.search(r"\.INIT\s*\(\s*1'b([01])\s*\)", params)
    if m:
        return int(m.group(1)), True
    return (1 if SET_TYPES.match(typ) else 0), False


def reset_class(typ, pins, const):
    for p in ('CLR', 'PRE'):
        if p in pins and pins[p] not in const:
            return 'async'
    for p in ('R', 'S'):
        if p in pins and pins[p] not in const:
            return 'sync'
    return 'none'


def read_prj(rev, board, ipcore_dir):
    srcdir = os.path.join(rev, 'src')
    files = []
    for line in open(os.path.join(srcdir, TOPS[board] + '.prj')):
        m = re.match(r'^\s*(verilog|vhdl)\s+\w+\s+"([^"]+)"', line)
        if m:
            p = m.group(2)
            if p.startswith('ipcore_dir/'):
                files.append(os.path.normpath(os.path.join(ipcore_dir, p[len('ipcore_dir/'):])))
            else:
                files.append(os.path.normpath(os.path.join(srcdir, p)))
    return files


def build_units(files):
    units = {}
    texts = {}
    for f in files:
        t = open(f, newline='').read()
        texts[f] = t
        us = hdl.vhdl_units(t, f) if hdl.lang_of(f) == 'vhdl' else hdl.verilog_units(t, f)
        for u in us:
            units[u.name.lower()] = u
    known = set(u.name for u in units.values() if u.lang == 'verilog') | set(units)
    for u in units.values():
        if u.lang == 'verilog':
            u.insts = hdl.verilog_insts(u, texts[u.path], known)
    return units


def hierarchy(units, top):
    """instance path ('' = top, 'machine/crt', ...) -> unit."""
    res = {}

    def walk(path, u):
        res[path] = u
        for inst, mod in u.insts:
            v = units.get(mod.lower())
            if v is not None:
                walk((path + '/' if path else '') + inst, v)
    walk('', units[top.lower()])
    return res


def split_leaf(leaf, unit):
    """FF leaf name -> (register, bit or None, role, note)."""
    names = sorted(list(unit.regs.keys()) + [k for k, d in unit.ports.items() if d.mode in ('out', 'buffer')],
                   key=len, reverse=True)
    regs = {}
    for k in names:
        regs[k.lower()] = unit.regs.get(k) or unit.ports.get(k)
    low = leaf.lower()
    m = re.match(r'^(.*)_fsm_ffd(\d+)$', low)
    if m and m.group(1) in regs:
        return regs[m.group(1)].name, int(m.group(2)), 'fsm', ''
    for k in sorted(regs, key=len, reverse=True):
        if low == k:
            return regs[k].name, None, 'bit', ''
        if low.startswith(k + '_'):
            rest = low[len(k) + 1:]
            m = re.match(r'^(\d+)_(p|c)_\d+$', rest)
            if m:
                return regs[k].name, int(m.group(1)), m.group(2), ''
            m = re.match(r'^(\d+)_ldc?$', rest)
            if m:
                return regs[k].name, int(m.group(1)), 'ldc', ''
            m = re.match(r'^(p|c)$', rest)
            if m:
                return regs[k].name, None, m.group(1), ''
            if rest in ('ld', 'ldc'):
                return regs[k].name, None, 'ldc', ''
            m = re.match(r'^(\d+)$', rest)
            if m:
                return regs[k].name, int(m.group(1)), 'bit', ''
            m = re.match(r'^(\d+)_(\d+)$', rest)
            if m:
                d = regs[k]
                if d.kind == 'mem' or (d.typ and 'array' in (d.typ or '').lower()):
                    return regs[k].name, int(m.group(2)), 'bit', 'element %s' % m.group(1)
                return regs[k].name, int(m.group(1)), 'dup', 'duplicate %s' % m.group(2)
            m = re.match(r'^(\d+)_(\d+)_(\d+)$', rest)
            if m:
                return regs[k].name, int(m.group(2)), 'bit', 'element %s' % m.group(1)
    return None, None, None, ''


def lut_eval(init_hex, nin, inputs):
    """LUT output for {input index: value}."""
    idx = sum(v << k for k, v in inputs.items())
    return (int(init_hex, 16) >> idx) & 1


def parse_fsms(syr):
    lines = open(syr, errors='replace').read().split('\n')
    res = []
    for i, l in enumerate(lines):
        m = re.match(r'^Optimizing FSM <([^>]+)> on signal <(\w+)\[[^\]]*\]> with ([\w-]+) encoding\.', l)
        if not m:
            continue
        table = []
        j = i + 4
        while j < len(lines) and not lines[j].startswith('---'):
            t = re.match(r'^\s*(\S+)\s*\|\s*(\S+)', lines[j])
            if t:
                table.append((t.group(1), t.group(2)))
            j += 1
        res.append({'fsm': m.group(1), 'signal': m.group(2), 'encoding': m.group(3), 'table': table,
                    'line': i + 1})
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('synth')
    ap.add_argument('syr')
    ap.add_argument('--rev', required=True)
    ap.add_argument('--board', required=True, choices=sorted(TOPS))
    ap.add_argument('--ipcore-dir', required=True, help='generated Coregen cores (ipcore_dir of a build)')
    ap.add_argument('--regs')
    ap.add_argument('--xcheck')
    ap.add_argument('--fsm')
    ap.add_argument('--source', default='', help='label of the netlist for the source column')
    a = ap.parse_args()
    label = a.source or os.path.basename(os.path.dirname(os.path.abspath(a.synth)))

    insts, const = parse_netlist(a.synth)
    units = build_units(read_prj(a.rev, a.board, a.ipcore_dir))
    hier = hierarchy(units, TOPS[a.board])
    paths = sorted(hier, key=len, reverse=True)

    def locate(name):
        parts = name.split('/')
        for k in range(len(parts) - 1, -1, -1):
            p = '/'.join(parts[:k])
            if p in hier:
                return p, '/'.join(parts[k:])
        return None, name

    regs = OrderedDict()   # (path, reg) -> info
    unresolved, rams, by_q = [], [], {}
    for typ, name, params, pins in insts:
        if 'Q' in pins:
            by_q[pins['Q']] = (typ, name, params, pins)
        if RAM_TYPES.match(typ):
            m = re.search(r"\.INIT\s*\(\s*([^)]*)\)", params)
            rams.append((typ, name, m.group(1).strip() if m else '(default)'))
            continue
        if not FF_TYPES.match(typ):
            continue
        init, explicit = init_of(typ, params)
        path, leaf = locate(name)
        if path is None or '/' in leaf:
            unresolved.append((typ, name, init, explicit, 'no unit for the path'))
            continue
        u = hier[path]
        reg, bit, role, note = split_leaf(leaf, u)
        if reg is None:
            unresolved.append((typ, name, init, explicit, 'no register of %s matches' % u.name))
            continue
        key = (path, reg)
        r = regs.setdefault(key, {'unit': u, 'bits': {}, 'types': set(), 'reset': set(), 'explicit': False,
                                  'roles': defaultdict(dict), 'notes': set(), 'insts': []})
        r['types'].add(typ)
        r['reset'].add(reset_class(typ, pins, const))
        r['explicit'] |= explicit
        r['insts'].append(name)
        if note:
            r['notes'].add(note)
        b = 0 if bit is None else bit
        if role in ('bit', 'dup'):
            r['bits'].setdefault(b, init)
        r['roles'][b][role] = (init, typ, name, pins)

    # DSP48A1 output registers (PREG = 1) that hold an RTL register: power-up 0
    for typ, name, params, pins in insts:
        if not typ.startswith('DSP48') or not re.search(r'\.PREG\s*\(\s*1\s*\)', params):
            continue
        for net in pins.get('P', '').strip('{}').split(','):
            nm = re.match(r'^\s*\\(\S+)\s*\[(\d+)\]\s*$', net)
            if not nm:
                continue
            path, leaf = locate(nm.group(1))
            if path is None or '/' in leaf:
                continue
            u = hier[path]
            reg = (u.regs.get(leaf) or u.regs.get(leaf.lower()))
            if reg is None:
                continue
            r = regs.setdefault((path, reg.name), {'unit': u, 'bits': {}, 'types': set(), 'reset': set(),
                                                   'explicit': False, 'roles': defaultdict(dict),
                                                   'notes': set(), 'insts': []})
            r['types'].add(typ + '.PREG')
            r['reset'].add(reset_class(typ, {k: v for k, v in pins.items() if k == 'RSTP'} and {'R': pins['RSTP']}
                                       or {}, const))
            r['bits'][int(nm.group(2))] = 0
            r['notes'].add('DSP48A1 P register (power-up 0)')

    # async-load triples: bit = LDC ? P : C (checked on the LUT of one bit)
    mux_report, mux_done = [], set()
    for key, r in regs.items():
        for b, roles in r['roles'].items():
            if 'ldc' in roles and 'p' in roles and 'c' in roles:
                p, c, l = roles['p'][0], roles['c'][0], roles['ldc'][0]
                r['bits'][b] = p if l else c
                if key not in mux_done:
                    mux_done.add(key)
                    qn = {k: roles[k][3].get('Q') for k in ('p', 'c', 'ldc')}
                    for typ, name, params, pins in insts:
                        if re.match(r'^LUT[3-6]$', typ) and set(qn.values()) <= set(pins.values()):
                            ins = {int(k[1:]): v for k, v in pins.items() if re.match(r'^I\d$', k)}
                            pos = {role: [k for k, v in ins.items() if v == qn[role]][0] for role in qn}
                            init_hex = re.search(r"\.INIT\s*\(\s*\d+'h([0-9A-Fa-f]+)", params).group(1)
                            ok = all(lut_eval(init_hex, len(ins), {pos['ldc']: lv, pos['p']: pv, pos['c']: cv})
                                     == (pv if lv else cv)
                                     for lv in (0, 1) for pv in (0, 1) for cv in (0, 1)
                                     if len(ins) == 3)
                            mux_report.append('%s/%s bit %d: LUT %s INIT %s, I%d=LDC I%d=P I%d=C -> out = LDC ? P : C: %s'
                                              % (key[0], key[1], b, name, init_hex, pos['ldc'], pos['p'], pos['c'],
                                                 'VERIFIED' if ok and len(ins) == 3 else 'NOT VERIFIED'))
                            break
                r['notes'].add('async load P/C/LDC folded (LDC ? P : C)')

    fsms = parse_fsms(a.syr)
    fsm_rows = []
    for f in fsms:
        path, reg = f['fsm'].rsplit('/', 1)[0], f['signal']
        r = None
        for key in regs:
            if key[0] == path and key[1].lower() == reg.lower():
                r = regs[key]
        nb = len(f['table'][0][1]) if f['table'] else 0
        bits = ''
        state = 'unresolved'
        if r is not None:
            ffd = {b: roles['fsm'][0] for b, roles in r['roles'].items() if 'fsm' in roles}
            bits = ''.join(str(ffd.get(k, '-')) for k in range(1, nb + 1))
            for st, enc in f['table']:
                if enc == bits:
                    state = st
            if state == 'unresolved' and f['encoding'] == 'one-hot' and bits.count('-') == 1 \
                    and set(bits) <= {'0', '-'}:
                # XST drops the flip-flop of one one-hot state: that state is "no other bit set"
                want = ''.join('1' if c == '-' else '0' for c in bits)
                for st, enc in f['table']:
                    if enc == want:
                        state = '%s (inferred: one-hot bit %d has no flip-flop, the others are 0)' \
                                % (st, bits.index('-') + 1)
        fsm_rows.append((f, path, reg, bits, state))
        if r is not None:
            r['fsm'] = (f, bits, state)

    # ---- output
    def bits_str(r, width):
        if 'fsm' in r:
            return 'state %s (FSM bits %s)' % (r['fsm'][2], r['fsm'][1])
        hi = max(r['bits']) if r['bits'] else 0
        w = max(width or 0, hi + 1)
        return ''.join(str(r['bits'].get(k, '-')) for k in range(w - 1, -1, -1))

    hdr = 'module\tinstance\tregister\twidth\tpower_up_bits\tprimitives\treset\tinit\tnotes\tsource'
    rows = []
    for (path, reg), r in regs.items():
        u = r['unit']
        d = u.regs.get(reg) or u.regs.get(reg.lower()) or u.ports.get(reg.lower())
        width = d.width() if d else None
        rows.append((u.name, path or '.', reg, str(width or '?'), bits_str(r, width), ','.join(sorted(r['types'])),
                     ','.join(sorted(r['reset'])), 'explicit' if r['explicit'] else 'default',
                     '; '.join(sorted(r['notes'])), label))
    rows.sort(key=lambda x: (x[1], x[2]))

    def write(path, rws):
        with open(path, 'w', newline='\n') as f:
            f.write('# generated by src/sim/sys/gen/power_up_from_netlist.py from %s (%s)\n' % (label, a.board))
            f.write(hdr + '\n')
            for x in rws:
                f.write('\t'.join(x) + '\n')

    if a.regs:
        write(a.regs, rows)
    if a.xcheck:
        xs = [x for x in rows if 'none' in x[6].split(',') or 'sync' in x[6].split(',') or x[7] == 'explicit']
        write(a.xcheck, xs)
    if a.fsm:
        with open(a.fsm, 'w', newline='\n') as f:
            f.write('# generated by src/sim/sys/gen/power_up_from_netlist.py from %s (%s)\n' % (label, a.board))
            f.write('fsm\tinstance\tsignal\tencoding\ttable\tstate_ff_bits\tpower_up_state\tsyr_line\n')
            for fr, path, reg, bits, state in fsm_rows:
                f.write('\t'.join((fr['fsm'], path, reg, fr['encoding'],
                                   ' '.join('%s=%s' % t for t in fr['table']), bits or '-', state,
                                   str(fr['line']))) + '\n')

    print('netlist %s: %d instances, %d FF/latch registers, %d unresolved FF/latches, %d LUT-RAM/SRL'
          % (a.synth, len(insts), len(regs), len(unresolved), len(rams)))
    print('\n== async-load multiplexer check')
    for x in mux_report or ['(no P/C/LDC triple found)']:
        print(x)
    print('\n== FSMs (.syr State | Encoding + INIT of the state flip-flops)')
    for fr, path, reg, bits, state in fsm_rows:
        print('%s on %s/%s (%s, .syr line %d): %s; FFd bits %s -> power-up state %s'
              % (fr['fsm'], path, reg, fr['encoding'], fr['line'], ' '.join('%s=%s' % t for t in fr['table']),
                 bits or '-', state))
    print('\n== LUT-RAM / SRL (INIT)')
    for x in rams:
        print('%s %s INIT %s' % x)
    print('\n== unresolved flip-flops / latches')
    for x in unresolved:
        print('%s %s INIT %d (%s) - %s' % (x[0], x[1], x[2], 'explicit' if x[3] else 'default', x[4]))
    if not a.regs:
        print('\n== registers')
        print(hdr)
        for x in rows:
            print('\t'.join(x))


if __name__ == '__main__':
    main()
