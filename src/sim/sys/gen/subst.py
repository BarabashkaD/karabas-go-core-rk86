"""Declared sim-copy substitutions with an exact count check, and their journal.

Every change of an RTL file for the simulation goes through Journal.sub() (or one of the
builders below, which call it): the number of matches must be the expected one (an int, or a
set of allowed counts such as {0, 1}), otherwise SubstError stops the generator. Every applied
substitution is journaled; the journal is written to subst.txt and listed in summary.txt under
SIMULATED != SYNTHESIZED.
"""
import re

import hdl


class SubstError(Exception):
    pass


class Journal(object):
    def __init__(self):
        self.entries = []     # dict(num, file, desc, expected, found, kind)

    def sub(self, num, fname, text, pattern, repl, expected, desc, flags=0, kind='subst'):
        """re.subn with the count check; returns the new text."""
        rx = re.compile(pattern, flags)
        found = len(rx.findall(text))
        allowed = expected if isinstance(expected, (set, frozenset, tuple, list)) else {expected}
        if found not in allowed:
            raise SubstError('#%s %s: %s: expected %s match(es), found %d (pattern %r)'
                             % (num, fname, desc, fmt_expected(expected), found, pattern))
        new = rx.sub(repl, text) if found else text
        self.entries.append(dict(num=num, file=fname, desc=desc, expected=fmt_expected(expected), found=found,
                                 kind=kind))
        return new

    def note(self, num, fname, desc, found=1, expected='-', kind='subst'):
        self.entries.append(dict(num=num, file=fname, desc=desc, expected=expected, found=found, kind=kind))

    def lines(self, kinds=None):
        out = []
        for e in self.entries:
            if kinds and e['kind'] not in kinds:
                continue
            out.append('#%s\t%s\t%s\texpected %s, found %s'
                       % (e['num'], e['file'], e['desc'], e['expected'], e['found']))
        return out


def fmt_expected(e):
    if isinstance(e, (set, frozenset, tuple, list)):
        return ' or '.join(str(x) for x in sorted(e))
    return str(e)


# --------------------------------------------------------------------------- VHDL builders

def vhdl_context(text, ent_start):
    """library / use clauses before the entity."""
    b = hdl.blank_comments_vhdl(text[:ent_start])
    return ''.join(m.group(0).strip() + '\n' for m in re.finditer(r'(?im)^\s*(library|use)\b[^;]*;', b))


def vhdl_rename_entity(j, num, fname, text, old, new):
    """entity <old> -> <new> (declaration, end, architectures); exactly one entity."""
    text = j.sub(num, fname, text, r'(?i)\bentity\s+%s\s+is\b' % re.escape(old), 'entity %s is' % new, 1,
                 'entity %s -> %s' % (old, new))
    text = j.sub(num, fname, text, r'(?i)\bend\s+(entity\s+)?%s\s*;' % re.escape(old),
                 lambda m: 'end %s%s;' % (m.group(1) or '', new), 1, 'end %s -> end %s' % (old, new))
    text = j.sub(num, fname, text, r'(?i)\barchitecture\s+(\w+)\s+of\s+%s\s+is\b' % re.escape(old),
                 lambda m: 'architecture %s of %s is' % (m.group(1), new), {1, 2, 3},
                 'architecture of %s -> of %s' % (old, new))
    return text


def _port_decl(d, mode=None, typ=None, init=None):
    s = '%s : %s %s' % (d.name, mode or d.mode, typ or d.typ)
    i = d.init if init is None else init
    if i:
        s += ' := %s' % ' '.join(i.split())
    return s


def _entity_decl(name, generics, ports):
    s = 'entity %s is\n' % name
    if generics:
        s += '\tgeneric (\n%s\n\t);\n' % ';\n'.join(
            '\t\t%s : %s%s' % (g.name, g.typ, (' := ' + ' '.join(g.init.split())) if g.init else '')
            for g in generics)
    s += '\tport (\n%s\n\t);\nend %s;\n' % (';\n'.join('\t\t' + p for p in ports), name)
    return s


def vhdl_buffer_wrapper(j, num, fname, text, name, expected_buffers):
    """ISim leaves VHDL 'buffer' ports undriven under a Verilog parent: the entity becomes
    <name>_core and a wrapper <name> with 'out' ports drives them from internal signals.
    (Logic of modules/sim/mcu/mcu_sim_wrap.py; the port clause is the one after the keyword
    'port' at the start of a line.)"""
    units = [u for u in hdl.vhdl_units(text, fname) if u.name.lower() == name.lower()]
    if len(units) != 1:
        raise SubstError('#%s %s: entity %s found %d times' % (num, fname, name, len(units)))
    u = units[0]
    bufs = [p for p in u.port_items if p.mode == 'buffer']
    if len(bufs) != expected_buffers:
        raise SubstError('#%s %s: expected %d buffer ports of %s, found %d'
                         % (num, fname, expected_buffers, name, len(bufs)))
    ctx = vhdl_context(text, u.ent_start)
    core = vhdl_rename_entity(j, num, fname, text, name, name + '_core')
    ports = [_port_decl(p, mode='out' if p.mode == 'buffer' else p.mode) for p in u.port_items]
    w = '\n-- sim copy: wrapper with out ports in place of the buffer ports of %s_core\n' % name
    w += ctx + '\n' + _entity_decl(name, u.generics, ports) + '\narchitecture sim of %s is\n' % name
    for p in bufs:
        w += '\tsignal %s_s : %s%s;\n' % (p.name, p.typ, (' := ' + ' '.join(p.init.split())) if p.init else '')
    w += 'begin\n\tU: entity work.%s_core\n' % name
    if u.generics:
        w += '\t\tgeneric map (%s)\n' % ', '.join('%s => %s' % (g.name, g.name) for g in u.generics)
    w += '\t\tport map (\n%s\n\t\t);\n' % ',\n'.join(
        '\t\t\t%s => %s%s' % (p.name, p.name, '_s' if p.mode == 'buffer' else '') for p in u.port_items)
    for p in bufs:
        w += '\t%s <= %s_s;\n' % (p.name, p.name)
    w += 'end sim;\n'
    j.note(num, fname, '%d buffer ports -> out in the wrapper %s (%s)'
           % (len(bufs), name, ', '.join(p.name for p in bufs)), found=len(bufs), expected=expected_buffers)
    return core, w


def vhdl_width_adapter(j, num, fname, text, name, adapt):
    """The entity becomes <name>_core; a wrapper <name> declares the ports of adapt with the
    width the instantiating Verilog connects. adapt: {port: (expected original type, new type,
    core actual)} - for an input the core gets the given value (GND, as XST ties the
    zero-extended sourceless nets), for an output the wrapper drives the given slice."""
    units = [u for u in hdl.vhdl_units(text, fname) if u.name.lower() == name.lower()]
    if len(units) != 1:
        raise SubstError('#%s %s: entity %s found %d times' % (num, fname, name, len(units)))
    u = units[0]
    byname = dict((p.name.upper(), p) for p in u.port_items)
    for pn, (orig, new, actual) in adapt.items():
        p = byname.get(pn.upper())
        if p is None or ' '.join(p.typ.lower().split()) != orig.lower():
            raise SubstError('#%s %s: port %s of %s is %r, expected %r'
                             % (num, fname, pn, name, p.typ if p else None, orig))
    ctx = vhdl_context(text, u.ent_start)
    core = vhdl_rename_entity(j, num, fname, text, name, name + '_core')
    ports = []
    for p in u.port_items:
        a = adapt.get(p.name.upper())
        ports.append(_port_decl(p, typ=a[1]) if a else _port_decl(p))
    w = '\n-- sim copy: %s with the port widths of the Verilog instance (as XST: GND into the core)\n' % name
    w += ctx + '\n' + _entity_decl(name, u.generics, ports) + '\narchitecture sim of %s is\n' % name
    outs = [(p, adapt[p.name.upper()]) for p in u.port_items if p.name.upper() in adapt and p.mode != 'in']
    ins = [(p, adapt[p.name.upper()]) for p in u.port_items if p.name.upper() in adapt and p.mode == 'in']
    for p, a in ins:
        w += '\tsignal %s_s : %s := %s;\n' % (p.name, p.typ, a[2])
    for p, a in outs:
        w += '\tsignal %s_s : %s;\n' % (p.name, p.typ)
    w += 'begin\n\tU: entity work.%s_core\n' % name
    if u.generics:
        w += '\t\tgeneric map (%s)\n' % ', '.join('%s => %s' % (g.name, g.name) for g in u.generics)
    maps = []
    for p in u.port_items:
        a = adapt.get(p.name.upper())
        if a:
            maps.append('\t\t\t%s => %s_s' % (p.name, p.name))
        else:
            maps.append('\t\t\t%s => %s' % (p.name, p.name))
    w += '\t\tport map (\n%s\n\t\t);\n' % ',\n'.join(maps)
    for p, a in outs:
        w += '\t%s <= %s_s%s;\n' % (p.name, p.name, a[2])
    w += 'end sim;\n'
    j.note(num, fname, 'wrapper %s: %s' % (name, '; '.join('%s %s -> %s (core %s)' % (k, v[0], v[1], v[2])
                                                          for k, v in sorted(adapt.items()))),
           found=1, expected=1)
    return core, w


# --------------------------------------------------------------------------- edits by position

def apply_edits(text, edits):
    """edits: [(start, end, new)] on the original offsets, non-overlapping."""
    for s, e, new in sorted(edits, key=lambda x: x[0], reverse=True):
        text = text[:s] + new + text[e:]
    return text


def vhdl_decl_edit(text, u, decl, value_vhdl):
    """Edit that gives the VHDL signal / port <decl> the default value (splits a multi-name declaration)."""
    b = hdl.blank_comments_vhdl(text)
    if decl.kind == 'signal':
        s = decl.pos
        e = b.index(';', s)
        m = re.match(r'(?is)signal\s+([\w\s,]+?)\s*:\s*(.*?)\s*$', b[s:e])
        names = [x.strip() for x in m.group(1).split(',') if x.strip()]
        typ = ' '.join(m.group(2).split())
        others = [x for x in names if x.lower() != decl.name.lower()]
        new = ''
        if others:
            new = 'signal %s : %s; ' % (', '.join(others), typ)
        new += 'signal %s : %s := %s' % (decl.name, typ, value_vhdl)
        return (s, e, new)
    # port item
    s, e = decl.span
    item = b[s:e]
    k = len(item.rstrip())
    m = re.match(r'(?is)(\s*)([\w\s,]+?)\s*:\s*(.*)$', item[:k])
    names = [x.strip() for x in m.group(2).split(',') if x.strip()]
    rest = ' '.join(m.group(3).split())
    others = [x for x in names if x.lower() != decl.name.lower()]
    new = m.group(1)
    if others:
        new += '%s : %s; ' % (', '.join(others), rest)
    new += '%s : %s := %s' % (decl.name, rest, value_vhdl)
    return (s, s + k, new)


def endmodule_pos(text, u):
    return u.end   # start of 'endmodule'


def vhdl_arch_end(text, u):
    """Offset of the 'end' of the first architecture of the entity."""
    b = hdl.blank_comments_vhdl(text)
    an, s, e = u.archs[0]
    m = None
    for m in re.finditer(r'(?i)\bend\b', b[s:e]):
        pass
    return s + m.start()
