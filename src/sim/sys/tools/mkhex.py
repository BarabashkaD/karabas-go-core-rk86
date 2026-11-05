"""$readmemh files for the system simulation (host, Python 3).

Usage:
  python -B mkhex.py bin <in.bin> <out.hex>     one byte per line; the length in a // comment
  python -B mkhex.py coe <in.coe> <out.hex> [width]

coe: the logic of modules/tools/coe2hex.py (memory_initialization_radix 2, 10 or 16 -> hex; the
width in bits sets the digits per line, without it the widest value decides).
"""
import os
import re
import sys


def _write(path, lines):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(path, 'w', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


def bin2hex(src, dst):
    data = open(src, 'rb').read()
    _write(dst, ['// %s: %d bytes' % (os.path.basename(src), len(data))] + ['%02x' % b for b in data])
    return len(data)


def coe_values(src):
    text = open(src).read()
    # a line that starts with ';' is a comment, other ';' end a statement
    stmts = [s.strip() for s in re.sub(r'(?m)^\s*;.*$', '', text).split(';') if s.strip()]
    radix, values = 10, []
    for s in stmts:
        k, _, v = s.partition('=')
        k = k.strip().lower()
        if k == 'memory_initialization_radix':
            radix = int(v.strip())
        elif k == 'memory_initialization_vector':
            values = [int(x, radix) for x in re.split(r'[\s,]+', v.strip()) if x]
    if not values:
        raise ValueError('no memory_initialization_vector in ' + src)
    return values


def coe2hex(src, dst, width=None):
    values = coe_values(src)
    bits = width or max(1, max(values).bit_length())
    digits = (bits + 3) // 4
    _write(dst, ['%0*x' % (digits, x) for x in values])
    return len(values)


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ('bin', 'coe'):
        sys.exit(__doc__)
    if sys.argv[1] == 'bin':
        n = bin2hex(sys.argv[2], sys.argv[3])
    else:
        n = coe2hex(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else None)
    print('%s -> %s: %d words' % (sys.argv[2], sys.argv[3], n))


if __name__ == '__main__':
    main()
