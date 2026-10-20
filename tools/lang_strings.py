#!/usr/bin/env python3
"""Collects the texts to translate into data/lang/castle-quake.pot and checks
the translations (data/lang/<code>.po) against it.

    python3 tools/lang_strings.py            # write the .pot, report what each .po misses
    python3 tools/lang_strings.py --check    # exit code = the number of missing or extra texts

The texts: the string literals in Tr(...) calls, the menu items
(FItems.Add: the whole text, or the "Label" of "Label: value" and a value
in brackets), the binding names, the captions, the photo effects, the
labels of the editor designs (data/ui) and a few values the code builds
items from (EXTRA). A translation keeps the format specifiers (%d, %s,
%.2f...) of its text, in the same order; tools/lang_strings.py --check
checks that too.
"""

import argparse
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANG = os.path.join(ROOT, 'data', 'lang')
POT = os.path.join(LANG, 'castle-quake.pot')
# Values menu items are built from (Options, Controls)
EXTRA = ['ON', 'OFF', 'Auto', 'Quake Lightmaps', 'Dynamic PBR', 'First-Person', 'Third-Person', 'Free-Fly',
         'South', 'East', 'behind', 'empty', 'Play', 'small', 'medium', 'large']
LITERAL = r"'(?:[^']|'')*'"


def unquote(lit):
    return lit[1:-1].replace("''", "'")


def joined(expr):
    """The text of 'a' + 'b' (only literals), else None"""
    parts = re.findall(LITERAL, expr)
    rest = re.sub(LITERAL, '', expr)
    if not parts or re.sub(r'[\s+]', '', rest):
        return None
    return ''.join(unquote(p) for p in parts)


def call_args(text, start):
    """The argument text of the call whose '(' is at start (strings and nesting respected)"""
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c == "'":
            j = i + 1
            while j < len(text):
                if text[j] == "'" and (j + 1 >= len(text) or text[j + 1] != "'"):
                    break
                j += 2 if text[j] == "'" else 1
            i = j
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return text[start + 1:i]
        i += 1
    return ''


def item_parts(item, add):
    """A menu item: the whole text when it is fixed, its label and bracketed values"""
    m = re.match(r'^([^:\[%]+): (.*)$', item)
    if m:
        add(m.group(1))
        value = m.group(2)
        b = re.match(r'^\[([^\]%:]*)\]$', value)
        if b and not re.search(r'\d', b.group(1)) and b.group(1):
            add(b.group(1))
        elif ' ' in value and not re.search(r'[\[%]|\(port', value):
            add(value)  # a fixed description ("Episode Hub"); one word is a map name ("start")
    elif '%' not in item and item.strip() and not item.startswith('maps/'):
        add(item)


def collect():
    texts = []
    seen = set()

    def add(s, where=''):
        s = s.strip('\n')
        if not s or s in seen or not re.search(r'[A-Za-z]', s):
            return
        seen.add(s)
        texts.append((s, where))

    for path in sorted(glob.glob(os.path.join(ROOT, 'code', '**', '*.pas'), recursive=True) +
                       glob.glob(os.path.join(ROOT, 'code', '**', '*.inc'), recursive=True)):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding='utf-8', errors='replace') as f:
            text = f.read()
        for m in re.finditer(r'\bTr\(', text):
            s = joined(call_args(text, m.end() - 1))
            if s is not None:
                add(s, rel)
        for m in re.finditer(r'\bFItems\.Add\(', text):
            args = call_args(text, m.end() - 1)
            lits = re.findall(LITERAL, args)
            if not lits:
                continue
            first = unquote(lits[0])
            whole = joined(args)
            if whole is not None:
                item_parts(whole, lambda s: add(s, rel))
            elif ': ' in first:
                add(first.split(': ')[0], rel)
        for name in ('BindingCaptions', 'PhotoEffectCaptions', 'SortNames'):
            m = re.search(name + r'\s*:\s*array\[[^\]]*\]\s*of\s*String\s*=\s*\(', text)
            if m:
                for lit in re.findall(LITERAL, call_args(text, m.end() - 1)):
                    add(unquote(lit), rel)
        if rel.endswith('quakecaptions.pas'):
            for lit in re.findall(r"Text: (" + LITERAL + r")\)", text):
                add(unquote(lit), rel)
    for path in sorted(glob.glob(os.path.join(ROOT, 'data', 'ui', '*.castle-user-interface'))):
        rel = os.path.relpath(path, ROOT)
        with open(path, encoding='utf-8') as f:
            design = json.load(f)

        def walk(node):
            if isinstance(node, dict):
                for key in ('Text', 'Caption'):
                    v = node.get(key)
                    if isinstance(v, list):
                        for line in v:
                            add(line, rel)
                    elif isinstance(v, str):
                        add(v, rel)
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(design)
    for s in EXTRA:
        add(s, 'tools/lang_strings.py')
    return texts


def po_escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')


def parse_po(path):
    entries = {}
    header = ''
    state, msgid, msgstr = None, '', ''

    def unesc(s):
        return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), s)

    def flush():
        nonlocal header
        if state == 'str':
            if msgid == '':
                header = msgstr
            else:
                entries[msgid] = msgstr

    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            m = re.match(r'^(msgid|msgstr) "(.*)"$', line)
            if m:
                if m.group(1) == 'msgid':
                    flush()
                    state, msgid, msgstr = 'id', unesc(m.group(2)), ''
                else:
                    state, msgstr = 'str', unesc(m.group(2))
            elif line.startswith('"') and line.endswith('"'):
                if state == 'id':
                    msgid += unesc(line[1:-1])
                elif state == 'str':
                    msgstr += unesc(line[1:-1])
    flush()
    return header, entries


def specifiers(s):
    return re.findall(r'%[-0-9.]*[dsfxegn]', s)


def write_pot(texts):
    os.makedirs(LANG, exist_ok=True)
    with open(POT, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# The texts of Castle Quake to translate: tools/lang_strings.py writes this file.\n')
        f.write('# A translation is data/lang/<code>.po with the same msgid entries (and a line\n')
        f.write('# "<code> <name>" in data/lang/languages.txt).\n')
        f.write('msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n\n')
        for s, where in texts:
            f.write('#: %s\nmsgid "%s"\nmsgstr ""\n\n' % (where, po_escape(s)))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--check', action='store_true', help='only check, the exit code counts the problems')
    args = parser.parse_args()
    texts = collect()
    ids = [s for s, _ in texts]
    if not args.check:
        write_pot(texts)
        print('%d texts written to %s' % (len(texts), os.path.relpath(POT, ROOT)))
    problems = 0
    if args.check:
        pot_ids = set(parse_po(POT)[1]) if os.path.exists(POT) else set()
        stale = [s for s in ids if s not in pot_ids] + [s for s in pot_ids if s not in ids]
        if stale:
            print('%s is out of date (%d texts differ): run python3 tools/lang_strings.py'
                  % (os.path.relpath(POT, ROOT), len(stale)))
            for s in stale[:20]:
                print('  %r' % s)
        problems += len(stale)
    for path in sorted(glob.glob(os.path.join(LANG, '*.po'))):
        name = os.path.basename(path)
        _, entries = parse_po(path)
        missing = [s for s in ids if not entries.get(s)]
        extra = [s for s in entries if s not in ids]
        wrong = [s for s in ids if entries.get(s) and specifiers(entries[s]) != specifiers(s)]
        print('%s: %d of %d texts, %d missing, %d not used, %d with other format specifiers'
              % (name, len(ids) - len(missing), len(ids), len(missing), len(extra), len(wrong)))
        for s in missing[:20]:
            print('  missing: %r' % s)
        for s in extra[:20]:
            print('  not used: %r' % s)
        for s in wrong[:20]:
            print('  specifiers: %r -> %r' % (s, entries[s]))
        problems += len(missing) + len(extra) + len(wrong)
    return min(problems, 100) if args.check else 0


if __name__ == '__main__':
    sys.exit(main())
