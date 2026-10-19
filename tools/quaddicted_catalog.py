#!/usr/bin/env python3
"""Builds data/quaddicted/maps.txt, the list of the in-game map browser.

The maps come from Quaddicted's metadata (https://github.com/Quaddicted/
quaddicted-data, one JSON per release, keyed by the zip's SHA-256) and the
ratings from Quaddicted's last Quake Injector database (frozen in 2026, but
the only place with the ratings). Only releases that install into id1 and
need no mod are listed (maps, episodes, speedmaps and jams whose .bsp files
land in id1/maps/), so the game can mount the zip on top of its paks.

    python3 tools/quaddicted_catalog.py                   # fetch both and write the list
    python3 tools/quaddicted_catalog.py --data DIR --xml FILE   # from local copies

One line per release, tab separated:

    id  sha256  bytes  title  author  date  rating  size  flags  startmaps  mapping  url

id is the zip's name without .zip, rating Quaddicted's 0..5 (empty when not
rated), size small / medium / large, flags a comma list (limits: needs a
port with raised limits, lit, bsp2, singleplayer, deathmatch, coop),
startmaps the maps to start (a comma list, the first one is the default),
mapping how the zip's paths land in the game directory (from>to pairs
separated by ';', to relative to the Quake directory: 'tofaz/>id1/maps/').
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'data', 'quaddicted', 'maps.txt')
DATA_REPO = 'https://github.com/Quaddicted/quaddicted-data'
XML_URL = 'https://www.quaddicted.com/reviews/quaddicted_database.xml'
TYPES = {'map', 'speedmap', 'episode', 'mapjam', 'contest', 'chainmap', 'unfinished'}
DEPENDENCY_TAGS = ('dependency=', 'depends=')


def tag_values(tags, name):
    return [t.split('=', 1)[1] for t in tags if t.startswith(name + '=')]


def clean(text):
    return re.sub(r'\s+', ' ', text or '').strip()


def mapping_of(entry):
    """The extract mapping: {'/zip/prefix/': '/target/'} (target None: skipped)"""
    mapping = entry.get('install', {}).get('extractmapping')
    if mapping:
        return mapping
    base = tag_values(entry['tags'], 'zipbasedir')
    if base and base[0] != '/':
        return {'/': '/' + base[0].strip('/') + '/'}
    return {'/': '/'}


def place(path, mapping):
    """Where a zip path lands ('/id1/maps/x.bsp'), None when skipped"""
    p = '/' + path
    best = None
    for key in mapping:
        k = key if key.endswith('/') else key
        if p.startswith(k) and (best is None or len(k) > len(best)):
            best = k
    if best is None:
        return None
    target = mapping[best]
    if target is None or target == 'None':
        return None
    rest = p[len(best):]
    if best.endswith('/') and not target.endswith('/') and rest:
        target += '/'
    return target + rest


def in_id1(final):
    return final is not None and final.lower().startswith('/id1/')


def load_ratings(xml_path):
    ratings = {}
    try:
        root = ET.parse(xml_path).getroot()
    except Exception as e:  # the ratings are optional
        print('No ratings: %s' % e)
        return ratings
    for f in root.iter('file'):
        r = f.get('rating') or ''
        try:
            ratings[f.get('id')] = float(r) if r else None
        except ValueError:
            ratings[f.get('id')] = None
    return ratings


def build(data_dir, ratings):
    lines = []
    skipped = {}
    for path in sorted(glob.glob(os.path.join(data_dir, 'json', 'by-sha256', '*', '*.json'))):
        with open(path, encoding='utf-8') as f:
            e = json.load(f)
        tags = e.get('tags', [])
        kind = (tag_values(tags, 'type') or [''])[0]
        filename = (tag_values(tags, 'filename') or [''])[0]
        reason = None
        if kind not in TYPES:
            reason = 'type ' + kind
        elif not filename.lower().endswith('.zip'):
            reason = 'not a zip'
        elif any(t.startswith(DEPENDENCY_TAGS) for t in tags):
            reason = 'needs a mod'
        elif tag_values(tags, 'game') not in ([], ['quake']):
            reason = 'another game'
        if reason is None:
            mapping = mapping_of(e)
            files = [p for p in e.get('files', {}) if not p.endswith('/')]
            bsps = [p for p in files if p.lower().endswith('.bsp')]
            placed = [place(p, mapping) for p in bsps]
            if not bsps:
                reason = 'no loose .bsp'
            elif not all(in_id1(x) and x.lower().startswith('/id1/maps/') for x in placed):
                reason = 'installs outside id1/maps'
            elif any(p.lower().endswith('progs.dat') and in_id1(place(p, mapping)) for p in files):
                reason = 'own progs.dat'
        if reason:
            skipped[reason] = skipped.get(reason, 0) + 1
            continue
        names = [os.path.splitext(os.path.basename(x))[0].lower() for x in placed]
        starts = [s.lower() for s in tag_values(tags, 'startmap') if s.lower() in names]
        if not starts:
            starts = sorted(names)
        flags = []
        if tag_values(tags, 'exceeds_quake_limits') == ['yes'] or tag_values(tags, 'exceedslimits'):
            flags.append('limits')
        if any(p.lower().endswith('.lit') for p in files):
            flags.append('lit')
        if any('bsp2' in t.lower() for t in tag_values(tags, 'bsp_format')):
            flags.append('bsp2')
        for mode in tag_values(tags, 'game_mode'):
            if mode in ('singleplayer', 'deathmatch', 'coop') and mode not in flags:
                flags.append(mode)
        ident = filename[:-4]
        rating = ratings.get(ident)
        date = (tag_values(tags, 'release_date') or [''])[0]
        pairs = []
        for key, target in sorted(mapping.items()):
            if target is None or target == 'None':
                continue
            pairs.append('%s>%s' % (key.lstrip('/'), target.lstrip('/')))
        title = clean((tag_values(tags, 'title') or [ident])[0])
        author = clean(', '.join(tag_values(tags, 'author')))
        url = e['urls'][0] if e.get('urls') else 'https://www.quaddicted.com/filebase/' + filename
        fields = [ident, e['sha256'], str(e['bytes']), title, author, date,
                  '' if rating is None else '%.2f' % rating,
                  (tag_values(tags, 'map_size') or [''])[0], ','.join(flags), ','.join(starts),
                  ';'.join(pairs), url]
        lines.append('\t'.join(f.replace('\t', ' ') for f in fields))
    return lines, skipped


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('--data', help='a checkout of quaddicted-data (cloned when missing)')
    parser.add_argument('--xml', help='quaddicted_database.xml (fetched when missing)')
    parser.add_argument('--out', default=OUT)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        data = args.data
        if not data:
            data = os.path.join(tmp, 'data')
            subprocess.check_call(['git', 'clone', '-q', '--depth', '1', DATA_REPO, data])
        xml = args.xml
        if not xml:
            xml = os.path.join(tmp, 'db.xml')
            with urllib.request.urlopen(XML_URL, timeout=120) as r, open(xml, 'wb') as f:
                f.write(r.read())
        lines, skipped = build(data, load_ratings(xml))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# Quaddicted maps for the map browser: tools/quaddicted_catalog.py from %s\n' % DATA_REPO)
        f.write('# id\tsha256\tbytes\ttitle\tauthor\tdate\trating\tsize\tflags\tstartmaps\tmapping\turl\n')
        for line in lines:
            f.write(line + '\n')
    print('%d maps written to %s' % (len(lines), args.out))
    for reason, n in sorted(skipped.items(), key=lambda x: -x[1]):
        print('  skipped %d: %s' % (n, reason))
    return 0


if __name__ == '__main__':
    sys.exit(main())
