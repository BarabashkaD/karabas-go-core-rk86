"""Review of the power-up table against the netlist extraction (plan Task 2 Step 4).

Usage: python -B power_up_review.py --extract <dir> [--table power_up.tsv] [--boards go,mini,minig]
<dir>: the output of gen/power_up_from_netlist.py (regs_<board>.tsv; the repository keeps it under
build/sim/sys/extract). Every row of the table is compared with the power_up_bits of the same register
(candidate module + register name) in the extraction of every board: bits the netlist lacks ('-', trimmed)
are not compared; an FSM register ("state <bits> ...") is compared as its power-up state. Rows of 1-D
memories (LUT RAM, "every element" in the source column) are not in the register extraction and are
listed as MEM. Exit status 1 if any row differs, or a register row has no extraction on any board.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'gen'))
import hdl  # noqa: E402


def tsv(path):
    rows, hdr = [], None
    for ln in open(path, newline=''):
        ln = ln.rstrip('\r\n')
        if ln.startswith('#') or not ln.strip():
            continue
        f = ln.split('\t')
        if hdr is None:
            hdr = f
            continue
        rows.append(dict(zip(hdr, f + [''] * (len(hdr) - len(f)))))
    return rows


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description='Power-up table against the netlist extraction')
    ap.add_argument('--extract', required=True, help='directory with regs_<board>.tsv')
    ap.add_argument('--table', default=os.path.join(here, '..', 'power_up.tsv'))
    ap.add_argument('--boards', default='go,mini,minig')
    a = ap.parse_args()
    ex = {}
    for b in a.boards.split(','):
        p = os.path.join(a.extract, 'regs_%s.tsv' % b)
        if not os.path.isfile(p):
            print('ERROR no extraction %s' % p)
            return 1
        for r in tsv(p):
            ex.setdefault((r['module'], r['register']), []).append((b, r))
    nok = nbad = nmiss = nmem = 0
    for r in tsv(a.table):
        cands = [c.strip() for c in r['modules'].split(',') if c.strip()]
        hits = [(c, x) for c in cands for x in ex.get((c, r['signal']), [])]
        _, v = hdl.parse_value(r['value'])
        if not hits:
            if 'every element' in r.get('source', ''):
                nmem += 1
                print('MEM   %-14s %-10s value %s (LUT RAM, not in the register extraction; source: %s)'
                      % (r['signal'], r['modules'], r['value'], r['source'][:80]))
            else:
                nmiss += 1
                print('NO EXTRACTION  %-14s %s' % (r['signal'], r['value']))
            continue
        for c, (b, x) in hits:
            bits = x['power_up_bits']
            width = int(x['width'])
            tb = format(v & ((1 << width) - 1), '0%db' % width)
            if bits.startswith('state'):
                st = bits.split()[1]
                good = st == tb[-len(st):] and int(tb, 2) == int(st, 2)
                print('%s   %-5s %-14s %-10s table %s extraction %s' % ('OK ' if good else 'BAD', b, r['signal'], c,
                                                                          tb, bits))
            else:
                bad = [i for i in range(width) if bits[i] != '-' and bits[i] != tb[i]]
                good = not bad
                print('%s   %-5s %-14s %-10s table %s extraction %s %s' % ('OK ' if good else 'BAD', b, r['signal'],
                                                                             c, tb, bits, x['primitives']))
            if good:
                nok += 1
            else:
                nbad += 1
    print('POWER-UP REVIEW: %d board rows OK, %d differ, %d register rows without extraction, %d memory rows (MEM)'
          % (nok, nbad, nmiss, nmem))
    print('POWER-UP REVIEW %s' % ('PASS' if not (nbad or nmiss) else 'FAIL'))
    return 1 if (nbad or nmiss) else 0


if __name__ == '__main__':
    sys.exit(main())
