"""Light HDL scanning for the sim-tree generator and the power-up extraction.

Not a parser: it finds module / entity bodies, register / signal / port declarations,
initializers and instantiations in the restricted style of this repository. Comments are
blanked with spaces first (offsets and line numbers stay the same as in the source), so
a position found in the blanked text is valid in the original text.
"""
import re


def blank_comments_v(text):
    """Verilog: blank // and /* */ comments (and keep string literals)."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"' and text[j] != '\n':
                j += 2 if text[j] == '\\' else 1
            i = j + 1
        elif text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = ' '
            i = j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != '\n':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def blank_comments_vhdl(text):
    """VHDL: blank -- comments (string and character literals kept)."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = text.find('"', i + 1)
            i = n if j < 0 else j + 1
        elif c == "'" and i + 2 < n and text[i + 2] == "'":
            i += 3
        elif text.startswith('--', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            for k in range(i, j):
                if out[k] != '\r':
                    out[k] = ' '
            i = j
        else:
            i += 1
    return ''.join(out)


def lang_of(path):
    return 'vhdl' if path.lower().endswith(('.vhd', '.vhdl')) else 'verilog'


def blank(text, lang):
    return blank_comments_vhdl(text) if lang == 'vhdl' else blank_comments_v(text)


def match_paren(text, i):
    """text[i] == '(' -> index of the matching ')'."""
    depth = 0
    for j in range(i, len(text)):
        if text[j] == '(':
            depth += 1
        elif text[j] == ')':
            depth -= 1
            if depth == 0:
                return j
    raise ValueError('unbalanced parentheses at offset %d' % i)


def split_top(text, sep):
    """Split at sep outside parentheses."""
    parts, depth, cur = [], 0, []
    for c in text:
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
        if c == sep and depth == 0:
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(c)
    parts.append(''.join(cur))
    return parts


def line_of(text, pos):
    return text.count('\n', 0, pos) + 1


# --------------------------------------------------------------------------- Verilog

class Unit(object):
    """A Verilog module or a VHDL entity (with its architectures)."""

    def __init__(self, name, lang, path, start, end):
        self.name, self.lang, self.path = name, lang, path
        self.start, self.end = start, end   # body span in the file text
        self.regs = {}       # name -> Decl
        self.wires = {}      # Verilog wires: name -> Decl
        self.insts = []      # (instance name, unit name)
        self.ports = {}      # VHDL ports / Verilog ports: name -> Decl

    def __repr__(self):
        return 'Unit(%s, %s)' % (self.name, self.path)


class Decl(object):
    def __init__(self, name, kind, rng=None, init=None, pos=None, typ=None, mode=None):
        self.name, self.kind, self.rng, self.init, self.pos = name, kind, rng, init, pos
        self.typ, self.mode = typ, mode

    def width(self):
        """Width of a vector [msb:lsb] / (msb downto lsb), 1 for scalars, None if unknown."""
        r = self.rng
        if r is None:
            if self.typ is not None and not re.match(r'^(std_u?logic|bit|boolean)$', self.typ.strip(), re.I):
                return None   # VHDL vector with generic bounds, arrays, integers
            return 1
        m = re.match(r'^\s*(\d+)\s*(?::|downto|to)\s*(\d+)\s*$', r, re.I)
        if not m:
            return None
        return abs(int(m.group(1)) - int(m.group(2))) + 1


V_KEYWORDS = set('''module endmodule input output inout reg wire integer assign always initial begin end
if else case endcase default for while parameter localparam posedge negedge or and not function
endfunction task endtask generate endgenerate genvar signed real time event'''.split())


def verilog_units(text, path):
    b = blank_comments_v(text)
    units = []
    for m in re.finditer(r'\bmodule\s+(\w+)', b):
        e = re.compile(r'\bendmodule\b').search(b, m.end())
        if not e:
            raise ValueError('%s: module %s without endmodule' % (path, m.group(1)))
        u = Unit(m.group(1), 'verilog', path, m.start(), e.start())
        body = b[m.start():e.start()]
        _verilog_decls(u, body, m.start())
        units.append(u)
    return units


def _verilog_decls(u, body, base):
    # reg declarations, both in ANSI port lists and in the body
    for m in re.finditer(r'\breg\b\s*(?:signed\s*)?(\[[^\]]+\])?', body):
        rng = m.group(1)[1:-1] if m.group(1) else None
        tail_end = len(body)
        for t in (';', ')'):
            k = body.find(t, m.end())
            if 0 <= k < tail_end:
                tail_end = k
        tail = body[m.end():tail_end]
        off = m.end()
        for item in tail.split(','):
            s = item.strip()
            if not s:
                off += len(item) + 1
                continue
            if re.match(r'^(input|output|inout)\b', s):
                break
            im = re.match(r'^(\w+)\s*((?:\[[^\]]+\]\s*)*)(?:=\s*(.+))?$', s, re.S)
            if im and im.group(1) not in V_KEYWORDS:
                d = Decl(im.group(1), 'reg', rng, im.group(3).strip() if im.group(3) else None,
                         base + off + item.find(s))
                if im.group(2).strip():
                    d.kind = 'mem'
                    d.dims = re.findall(r'\[\s*(\d+)\s*:\s*(\d+)\s*\]', im.group(2))
                u.regs[d.name] = d
            off += len(item) + 1
    # port directions (ANSI lists and body declarations)
    u.vports = {}
    for m in re.finditer(r'\b(input|output|inout)\b\s*(?:wire\b|reg\b)?\s*(?:signed\b)?\s*(?:\[[^\]]+\])?\s*'
                         r'((?:\\\S+|\w+)(?:\s*,\s*(?!input\b|output\b|inout\b)(?:\w+))*)', body):
        for nm in [x.strip() for x in m.group(2).split(',')]:
            if nm and nm not in V_KEYWORDS:
                u.vports[nm] = m.group(1)
    for m in re.finditer(r'\bwire\b\s*(?:signed\s*)?(\[[^\]]+\])?\s*([^;]*);', body):
        rng = m.group(1)[1:-1] if m.group(1) else None
        for item in m.group(2).split(','):
            im = re.match(r'^\s*(\w+)', item)
            if im:
                u.wires[im.group(1)] = Decl(im.group(1), 'wire', rng, None, base + m.start())


def verilog_insts(u, text, known):
    """Instances of known module names in a Verilog unit: [(inst, module)]."""
    b = blank_comments_v(text)[u.start:u.end]
    out = []
    for m in re.finditer(r'\b(\w+)\s*(#\s*\()?', b):
        name = m.group(1)
        if name not in known or name == u.name:
            continue
        i = m.end()
        if m.group(2):
            i = match_paren(b, i - 1) + 1
        im = re.compile(r'\s*(\\\S+|\w+)\s*\(').match(b, i)
        if im:
            out.append((im.group(1).lstrip('\\'), name))
    return out


def verilog_inst_conns(text, unit, module, inst):
    """Port connections of the instance <inst> of <module> in a Verilog unit: {port: actual text}
    (named connections; '' for an empty connection). None if the instance is not found."""
    b = blank_comments_v(text)
    for m in re.finditer(r'\b%s\b\s*(#\s*\()?' % re.escape(module), b[unit.start:unit.end]):
        i = unit.start + m.end()
        if m.group(1):
            i = match_paren(b, i - 1) + 1
        im = re.compile(r'\s*\\?%s\s*\(' % re.escape(inst)).match(b, i)
        if not im:
            continue
        o = im.end() - 1
        c = match_paren(b, o)
        res = {}
        for item in split_top(b[o + 1:c], ','):
            pm = re.match(r'^\s*\.(\w+)\s*\((.*)\)\s*$', item, re.S)
            if pm:
                res[pm.group(1)] = ' '.join(pm.group(2).split())
        return res
    return None


def vhdl_inst_conns(text, unit, inst):
    """Port map of the instance labelled <inst> in a VHDL unit: {formal (lower case): actual}."""
    b = blank_comments_vhdl(text)
    for an, s, e in unit.archs:
        m = re.compile(r'(?i)\b%s\s*:' % re.escape(inst)).search(b, s, e)
        if not m:
            continue
        pm = re.compile(r'(?i)\bport\s+map\s*\(').search(b, m.end(), e)
        if not pm:
            return None
        o = pm.end() - 1
        c = match_paren(b, o)
        res = {}
        for item in split_top(b[o + 1:c], ','):
            am = re.match(r'^\s*(\w+)\s*=>\s*(.*?)\s*$', item, re.S)
            if am:
                res[am.group(1).lower()] = ' '.join(am.group(2).split())
        return res
    return None


def vhdl_processes(text, unit):
    """Processes of the architectures: [(label or '', [sensitivity names, lower case] or None, body)]."""
    b = blank_comments_vhdl(text)
    res = []
    for an, s, e in unit.archs:
        for m in re.finditer(r'(?i)(?:\b(\w+)\s*:\s*)?\bprocess\b\s*(\(([^)]*)\))?', b[s:e]):
            st = s + m.end()
            em = re.compile(r'(?i)\bend\s+process\b').search(b, st, e)
            body = b[st:em.start() if em else e]
            sens = None
            if m.group(2):
                sens = [x.strip().lower() for x in m.group(3).split(',') if x.strip()]
            res.append((m.group(1) or '', sens, body))
    return res


def vhdl_array_elem(text, unit, typ):
    """Element type of the array type <typ> declared in the architectures, or None."""
    b = blank_comments_vhdl(text)
    for an, s, e in unit.archs:
        m = re.compile(r'(?is)\btype\s+%s\s+is\s+array\s*\(.*?\)\s*of\s+(\w+)' % re.escape(typ)).search(b, s, e)
        if m:
            return m.group(1)
    return None


def verilog_initial_writes(text, unit, name):
    """Every assignment to <name> (whole, bit or part select) inside the initial blocks of the
    unit: [(value text, pos, select text or '')]."""
    return _initial_assigns(text, unit, name, True)


def verilog_initial_assigns(text, unit, name):
    """Values assigned to the whole of <name> in initial blocks of the unit: [(value text, pos)]."""
    return [(v, p) for v, p, sel in _initial_assigns(text, unit, name, True) if not sel]


def _initial_assigns(text, unit, name, _all):
    b = blank_comments_v(text)
    res = []
    for m in re.finditer(r'\binitial\b', b[unit.start:unit.end]):
        s = unit.start + m.end()
        bm = re.compile(r'\s*begin\b').match(b, s)
        if bm:
            depth, j = 0, s
            for t in re.finditer(r'\b(begin|end)\b', b[s:unit.end]):
                depth += 1 if t.group(1) == 'begin' else -1
                if depth == 0:
                    j = s + t.end()
                    break
            stmt = b[s:j]
        else:
            k = b.find(';', s)
            stmt = b[s:k + 1]
        for a in re.finditer(r'(?:\bforce\s+)?(?<![\w.])%s\b\s*((?:\[[^\]]*\]\s*)*)<?=(?!=)\s*([^;]+);'
                             % re.escape(name), stmt):
            res.append((a.group(2).strip(), s + a.start(), a.group(1).strip()))
        # concatenation targets: {a, b} = ...
        for a in re.finditer(r'\{([^{}]*)\}\s*<?=(?!=)\s*([^;]+);', stmt):
            if re.search(r'(?<![\w.])%s\b' % re.escape(name), a.group(1)):
                res.append((a.group(2).strip(), s + a.start(), '{%s}' % a.group(1).strip()))
    return res


# --------------------------------------------------------------------------- VHDL

def vhdl_units(text, path):
    b = blank_comments_vhdl(text)
    units = []
    for m in re.finditer(r'\bentity\s+(\w+)\s+is\b', b, re.I):
        name = m.group(1)
        e = re.compile(r'\bend\b\s*(?:entity\b\s*)?(?:%s\b\s*)?;' % re.escape(name), re.I).search(b, m.end())
        if not e:
            raise ValueError('%s: entity %s without end' % (path, name))
        u = Unit(name, 'vhdl', path, m.start(), len(b))
        u.ent_start, u.ent_end = m.start(), e.end()
        u.generics, u.port_items = vhdl_clause(b, m.end(), e.start(), 'generic'), vhdl_clause(b, m.end(), e.start(), 'port')
        for d in u.port_items:
            u.ports[d.name.lower()] = d
        # architectures of this entity
        u.archs = []
        for a in re.finditer(r'\barchitecture\s+(\w+)\s+of\s+%s\s+is\b' % re.escape(name), b, re.I):
            ae = re.compile(r'\bend\b\s*(?:architecture\b\s*)?(?:%s\b\s*)?;' % re.escape(a.group(1)), re.I).search(b, a.end())
            u.archs.append((a.group(1), a.start(), ae.end() if ae else len(b)))
        for an, s, e2 in u.archs:
            for sm in re.finditer(r'\bsignal\s+([\w\s,]+?)\s*:\s*([^;]*?)\s*(?::=\s*([^;]*?))?\s*;', b[s:e2], re.I):
                names = [x.strip() for x in sm.group(1).split(',') if x.strip()]
                for nm in names:
                    d = Decl(nm, 'signal', vhdl_range(sm.group(2)), sm.group(3), s + sm.start(), sm.group(2).strip())
                    d.multi = len(names) > 1
                    u.regs[nm.lower()] = d
            for im in re.finditer(r'\b(\w+)\s*:\s*entity\s+work\.(\w+)', b[s:e2], re.I):
                u.insts.append((im.group(1), im.group(2)))
            for im in re.finditer(r'\b(\w+)\s*:\s*(\w+)\s+(?:generic|port)\s+map\b', b[s:e2], re.I):
                if im.group(2).lower() not in ('entity', 'component'):
                    u.insts.append((im.group(1), im.group(2)))
        units.append(u)
    return units


def vhdl_clause(b, start, end, kw):
    """Items of the generic or port clause of an entity: [Decl] (kind 'port' / 'generic')."""
    m = re.compile(r'(?im)^\s*%s\b\s*\(' % kw).search(b, start, end)
    if not m:
        return []
    o = m.end() - 1
    c = match_paren(b, o)
    items = []
    off = o + 1
    for part in split_top(b[o + 1:c], ';'):
        pm = re.match(r'^\s*([\w\s,]+?)\s*:\s*(?:(in|out|inout|buffer)\s+)?(.*?)\s*(?::=\s*(.*?))?\s*$', part, re.S | re.I)
        if pm and pm.group(1).strip():
            for nm in [x.strip() for x in pm.group(1).split(',') if x.strip()]:
                d = Decl(nm, kw, vhdl_range(pm.group(3)), pm.group(4), off, pm.group(3).strip(),
                         (pm.group(2) or 'in').lower())
                d.span = (off, off + len(part))
                items.append(d)
        off += len(part) + 1
    return items


def vhdl_range(typ):
    m = re.search(r'\(\s*(\d+\s+(?:downto|to)\s+\d+)\s*\)', typ or '', re.I)
    return m.group(1) if m else None


# --------------------------------------------------------------------------- values

def parse_value(v):
    """A Verilog literal (7'h7F, 1'b0, 4'd14, 0) or a VHDL value ('1', "0101", x"FF",
    (others => '0'), true) -> (width or None, int) ; None if not understood."""
    if v is None:
        return None
    s = v.strip()
    m = re.match(r"^(\d+)?\s*'\s*([bhdo])\s*([0-9a-fA-F_]+)$", s)
    if m:
        base = {'b': 2, 'h': 16, 'd': 10, 'o': 8}[m.group(2).lower()]
        return (int(m.group(1)) if m.group(1) else None, int(m.group(3).replace('_', ''), base))
    if re.match(r'^\d+$', s):
        return (None, int(s))
    m = re.match(r"^'([01])'$", s)
    if m:
        return (1, int(m.group(1)))
    m = re.match(r'^"([01_]+)"$', s)
    if m:
        bits = m.group(1).replace('_', '')
        return (len(bits), int(bits, 2))
    m = re.match(r'^[xX]"([0-9a-fA-F_]+)"$', s)
    if m:
        h = m.group(1).replace('_', '')
        return (4 * len(h), int(h, 16))
    m = re.match(r"^\(\s*others\s*=>\s*'([01])'\s*\)$", s, re.I)
    if m:
        return (None, -1 if m.group(1) == '1' else 0)   # -1: all ones of the target width
    if s.lower() in ('true', 'false'):
        return (1, int(s.lower() == 'true'))
    return None


def same_value(a, b, width):
    pa, pb = parse_value(a), parse_value(b)
    if pa is None or pb is None:
        return None
    mask = (1 << width) - 1 if width else -1
    va = mask if pa[1] == -1 else pa[1]
    vb = mask if pb[1] == -1 else pb[1]
    return (va & mask) == (vb & mask)


def vhdl_literal(value, decl):
    """Table value (Verilog literal) -> VHDL literal for the declared type."""
    p = parse_value(value)
    if p is None:
        raise ValueError('cannot read value %r' % value)
    typ = (decl.typ or '').lower()
    if re.match(r'^std_u?logic$', typ):
        return "'%d'" % (p[1] & 1)
    if typ.startswith('boolean'):
        return 'true' if p[1] else 'false'
    w = decl.width()
    if w is None or 'std_logic_vector' not in typ and 'unsigned' not in typ and 'signed' not in typ:
        raise ValueError('cannot convert %r to VHDL type %r' % (value, decl.typ))
    return '"%s"' % format(p[1] & ((1 << w) - 1), '0%db' % w)
