#!/usr/bin/env python3
"""Checks the reuse contract (docs/contract.md): docs/contract-signals.csv against the
board tops, the module skeletons and the board-neutral machine manifest.

Usage, from any directory:
    python tools/contract/check_contract.py                 check
    python tools/contract/check_contract.py --draft         print a CSV, one row per signal
    python tools/contract/check_contract.py --iverilog PATH also elaborate the manifest
    python tools/contract/check_contract.py --self-test     test the Verilog parser
Exit code 0 when everything matches, 1 otherwise (the errors go to stderr).
"""
import argparse
import csv
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
BOARDS = ('go', 'mini', 'minig')
TOPS = {'go': 'src/radio86rk.v', 'mini': 'src/radio86rk_mini.v', 'minig': 'src/radio86rk_minig.v'}
CSV_PATH = 'docs/contract-signals.csv'
MANIFEST = 'src/rk86_machine.prj'
SKELETONS = {'rk86_machine': 'src/rtl/rk86_machine.v',
             'karabas_keyboard': 'src/rtl/karabas_keyboard.v'}
BOUNDARIES = {'machine', 'keyboard', 'video', 'sound', 'memory', 'platform'}
FIELDS = ['signal', 'bits', 'go', 'mini', 'minig', 'boundary', 'target', 'note']
# iverilog diagnostics on manifest files that ISE accepts (docs/contract.md); not fixed
# in this series. Any other diagnostic fails the check.
KNOWN_IVERILOG = {('k580wm80a.v', 47), ('k580wm80a.v', 49), ('k580ww55.v', 29)}
KEYWORDS = {'module', 'endmodule', 'input', 'output', 'inout', 'wire', 'reg', 'integer',
            'assign', 'always', 'begin', 'end', 'if', 'else', 'case', 'endcase', 'default',
            'posedge', 'negedge', 'or', 'and', 'not', 'signed', 'parameter', 'localparam',
            'genvar', 'generate', 'endgenerate', 'for', 'initial', 'function', 'endfunction',
            'task', 'endtask', 'casex', 'casez'}
LITERAL = re.compile(r"\d*'[sS]?[bBoOdDhH]\s*[0-9a-fA-FxXzZ_?]+|\b\d+\b")
IDENT = re.compile(r'\b[A-Za-z_][A-Za-z0-9_$]*\b')
RANGE = re.compile(r'\[\s*(\d+)\s*:\s*(\d+)\s*\]')
DECL = re.compile(r'(?<![\w.$])(input|output|inout|wire|reg|integer)\b([^;]*);')
INST = re.compile(r'(?<![\w.$])([A-Za-z_]\w*)(?:\s*#\s*\((?:[^()]|\([^()]*\))*\)\s*|\s+)([A-Za-z_]\w*)\s*\(')


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', lambda m: '\n' * m.group(0).count('\n'), text, flags=re.S)
    text = re.sub(r'\(\*[^)]*?\*\)', ' ', text)
    return re.sub(r'//[^\n]*', '', text)


def split_top_level(text):
    parts, depth, cur = [], 0, []
    for ch in text:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append(''.join(cur))
    return [p.strip() for p in parts if p.strip()]


def range_width(text):
    m = RANGE.search(text or '')
    return abs(int(m.group(1)) - int(m.group(2))) + 1 if m else 1


def balanced(text, open_pos):
    depth = 0
    for i in range(open_pos, len(text)):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return text[open_pos + 1:i]
    raise ValueError('unbalanced parenthesis at offset %d' % open_pos)


def identifiers(expr):
    return [w for w in IDENT.findall(LITERAL.sub(' ', expr)) if w not in KEYWORDS]


def parse_module(path):
    """Returns (name, ports, nets, instances): ports {name: (direction, width)}, nets
    {name: width} for wire/reg/integer and implicit nets (width 1), instances [module]."""
    with open(path, encoding='utf-8', errors='replace') as f:
        text = strip_comments(f.read())
    m = re.search(r'\bmodule\s+(\w+)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?\(', text)
    if not m:
        raise ValueError('%s: no module header' % path)
    name = m.group(1)
    header = balanced(text, m.end() - 1)
    body = text[m.end() + len(header) + 1:]
    body = body[:body.rfind('endmodule')] if 'endmodule' in body else body
    ports, nets = {}, {}
    direction, width = None, 1
    for item in split_top_level(header):
        d = re.match(r'(input|output|inout)\b\s*(?:wire|reg)?\s*(?:signed)?\s*(\[[^\]]*\])?\s*(\w+)$', item)
        if d:
            direction, width = d.group(1), range_width(d.group(2))
            ports[d.group(3)] = (direction, width)
        elif re.match(r'^\w+$', item):
            ports[item] = (direction, width) if direction else (None, 1)
        else:
            raise ValueError('%s: cannot parse port "%s"' % (path, item))
    for d in DECL.finditer(body):
        kind, rest = d.group(1), d.group(2)
        r = re.match(r'\s*(?:wire|reg)?\s*(?:signed)?\s*(\[[^\]]*\])?(.*)$', rest, re.S)
        w = 32 if kind == 'integer' else range_width(r.group(1))
        for decl in split_top_level(r.group(2)):
            n = re.match(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\]\s*)*(?:=.*)?$', decl, re.S)
            if not n:
                raise ValueError('%s: cannot parse declaration "%s %s"' % (path, kind, rest.strip()))
            if kind in ('input', 'output', 'inout'):
                ports[n.group(1)] = (kind, w)
            else:
                nets[n.group(1)] = w
    declared = set(ports) | set(nets)
    used = []
    for c in re.finditer(r'\.\s*\w+\s*\(', body):
        used += identifiers(balanced(body, c.end() - 1))
    for a in re.finditer(r'\bassign\s+(.*?)=', body, re.S):
        used += identifiers(a.group(1))
    for u in used:
        if u not in declared:
            nets[u] = 1
            declared.add(u)
    instances = [i.group(1) for i in INST.finditer(body)
                 if i.group(1) not in KEYWORDS and i.group(2) not in KEYWORDS]
    return name, ports, nets, instances


def bits_width(bits):
    if not bits:
        return None
    m = re.fullmatch(r'(\d+)(?::(\d+))?', bits)
    if not m:
        raise ValueError('bad bits "%s"' % bits)
    return 1 if m.group(2) is None else abs(int(m.group(1)) - int(m.group(2))) + 1


def manifest_files():
    with open(os.path.join(ROOT, MANIFEST), encoding='utf-8') as f:
        lines = [l.strip() for l in f if l.strip()]
    files = []
    for l in lines:
        m = re.fullmatch(r'(?:verilog|vhdl) work "([^"]+)"', l)
        if not m:
            raise ValueError('%s: bad line "%s"' % (MANIFEST, l))
        files.append(os.path.normpath(os.path.join('src', m.group(1))))
    return files


def load_tops():
    tops = {b: parse_module(os.path.join(ROOT, TOPS[b])) for b in BOARDS}
    names = {b: set(t[1]) | set(t[2]) for b, t in tops.items()}
    widths = {}
    for b, t in tops.items():
        widths[b] = {k: v[1] for k, v in t[1].items()}
        widths[b].update(t[2])
    return names, widths


def check(errors):
    names, widths = load_tops()
    skel = {}
    for mod, rel in SKELETONS.items():
        p = os.path.join(ROOT, rel)
        if os.path.exists(p):
            n, ports, _, _ = parse_module(p)
            if n != mod:
                errors.append('%s: the module is %s, expected %s' % (rel, n, mod))
            skel[mod] = ports
    with open(os.path.join(ROOT, CSV_PATH), newline='', encoding='utf-8') as f:
        reader = csv.DictReader(f)
        if reader.fieldnames != FIELDS:
            errors.append('%s: header must be %s' % (CSV_PATH, ','.join(FIELDS)))
            return
        rows = list(reader)
    seen, pending = {}, {}
    referenced = {m: set() for m in skel}
    for i, r in enumerate(rows, start=2):
        sig = r['signal']
        where = '%s:%d (%s)' % (CSV_PATH, i, sig)
        pres = tuple(r[b] for b in BOARDS)
        expect = tuple('y' if sig in names[b] else '-' for b in BOARDS)
        if pres != expect:
            errors.append('%s: go/mini/minig is %s, the tops say %s' % (where, '/'.join(pres), '/'.join(expect)))
        seen.setdefault(sig, pres)
        if r['boundary'] not in BOUNDARIES:
            errors.append('%s: boundary "%s" is not one of %s' % (where, r['boundary'], ', '.join(sorted(BOUNDARIES))))
        targets = [t.strip() for t in r['target'].split(';') if t.strip()]
        if not targets:
            errors.append('%s: no target' % where)
        if len(targets) > 1 and not r['note'].strip():
            errors.append('%s: several targets need a note' % where)
        try:
            bw = bits_width(r['bits'])
        except ValueError as e:
            errors.append('%s: %s' % (where, e))
            continue
        for t in targets:
            if t == 'platform':
                continue
            m = re.fullmatch(r'internal:(\w+)', t)
            if m:
                if m.group(1) not in SKELETONS:
                    errors.append('%s: "%s": no such module in the contract' % (where, t))
                continue
            m = re.fullmatch(r'(planned:)?(\w+)\.(\w+)', t)
            if not m or m.group(2) not in SKELETONS:
                errors.append('%s: bad target "%s"' % (where, t))
                continue
            planned, mod, port = m.groups()
            if mod not in skel:
                if planned:
                    pending[mod] = pending.get(mod, 0) + 1
                else:
                    errors.append('%s: %s is not in this tree; write planned:%s' % (where, SKELETONS[mod], t))
                continue
            if port not in skel[mod]:
                errors.append('%s: %s has no port %s' % (where, mod, port))
                continue
            referenced[mod].add(port)
            pw = skel[mod][port][1]
            for b in BOARDS:
                if sig in widths[b]:
                    sw = bw if bw is not None else widths[b][sig]
                    if sw != pw:
                        errors.append('%s: %d bit(s) on %s, %s.%s has %d' % (where, sw, b, mod, port, pw))
    for b in BOARDS:
        for n in sorted(names[b] - set(seen)):
            errors.append('%s: %s is not in %s' % (TOPS[b], n, CSV_PATH))
    for mod, ports in skel.items():
        for p in sorted(set(ports) - referenced[mod]):
            errors.append('%s.%s: no signal maps to this port' % (mod, p))
    for mod, n in sorted(pending.items()):
        print('note: %d target(s) wait for %s' % (n, SKELETONS[mod]))
    check_manifest(errors)


def check_manifest(errors):
    files = manifest_files()
    defined = set()
    parsed = []
    for f in files:
        p = os.path.join(ROOT, f)
        if not os.path.exists(p):
            errors.append('%s: %s does not exist' % (MANIFEST, f))
            continue
        name, _, _, inst = parse_module(p)
        defined.add(name)
        parsed.append((f, inst))
    for f, inst in parsed:
        for i in inst:
            if i not in defined:
                errors.append('%s: instantiates %s, which is not in %s' % (f, i, MANIFEST))


def run_iverilog(errors, iverilog):
    files = manifest_files()
    env = dict(os.environ)
    env['PATH'] = os.path.dirname(os.path.abspath(iverilog)) + os.pathsep + env.get('PATH', '')
    for f in files:
        mod = os.path.splitext(os.path.basename(f))[0]
        cmd = [iverilog, '-g2005', '-o', os.devnull, '-s', mod] + [os.path.join(ROOT, s) for s in files]
        res = subprocess.run(cmd, capture_output=True, text=True, env=env)
        out = res.stdout + res.stderr
        if 'Unknown module type' in out:
            errors.append('iverilog %s: unknown module (a vendor primitive or core?)' % mod)
        new = [l for l in out.splitlines()
               if re.search(r'([\w.]+\.v):(\d+):', l)
               and (os.path.basename(re.search(r'([\w.]+\.v):(\d+):', l).group(1)),
                    int(re.search(r'([\w.]+\.v):(\d+):', l).group(2))) not in KNOWN_IVERILOG]
        for l in new:
            errors.append('iverilog %s: %s' % (mod, l.strip()))
        print('iverilog %s: exit %d%s' % (mod, res.returncode,
              ', known findings only' if res.returncode and not new else ''))


def draft():
    names, _ = load_tops()
    w = csv.writer(sys.stdout, lineterminator='\n')
    w.writerow(FIELDS)
    for n in sorted(set().union(*names.values()), key=str.lower):
        w.writerow([n, ''] + ['y' if n in names[b] else '-' for b in BOARDS] + ['', '', ''])


def self_test():
    src = '\n'.join([
        'module t(input clk, output reg [7:0] q, input [3:0] a, b);',
        'wire x, y; // wire z;',
        '/* reg hidden; */',
        'reg [20:0] r1, r2 [0:3];',
        'wire [7:0] w = {6\'b0, x, 1\'b1};',
        'sub #(.P(3)) u(.A(imp1), .B(a[1:0]), .C({4\'d0, imp2}));',
        'assign imp3 = x;',
        'assign used_late = later;',
        'always @(*) begin if (x) q <= 8\'h00; end',
        'always @(posedge clk) if (x) q <= 8\'h01;',
        'always @(posedge clk) case (a) 4\'d0: q <= 8\'h02; endcase',
        'wire later;',
        'endmodule', ''])
    fd, path = tempfile.mkstemp(suffix='.v')
    with os.fdopen(fd, 'w') as f:
        f.write(src)
    try:
        name, ports, nets, inst = parse_module(path)
    finally:
        os.remove(path)
    want_ports = {'clk': ('input', 1), 'q': ('output', 8), 'a': ('input', 4), 'b': ('input', 4)}
    want_nets = {'x': 1, 'y': 1, 'r1': 21, 'r2': 21, 'w': 8, 'later': 1,
                 'imp1': 1, 'imp2': 1, 'imp3': 1, 'used_late': 1}
    ok = name == 't' and ports == want_ports and nets == want_nets and inst == ['sub']
    print('self-test: %s' % ('ok' if ok else 'FAILED'))
    if not ok:
        print('  name %r\n  ports %r\n  nets %r\n  instances %r' % (name, ports, nets, inst))
    return ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--draft', action='store_true')
    ap.add_argument('--iverilog')
    ap.add_argument('--self-test', action='store_true')
    args = ap.parse_args()
    if args.self_test:
        return 0 if self_test() else 1
    if args.draft:
        draft()
        return 0
    errors = []
    try:
        check(errors)
        if args.iverilog:
            run_iverilog(errors, args.iverilog)
    except (OSError, ValueError) as e:
        errors.append(str(e))
    for e in errors:
        print(e, file=sys.stderr)
    print('%s: %d error(s)' % ('ok' if not errors else 'FAILED', len(errors)))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
