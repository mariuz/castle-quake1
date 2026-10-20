#!/usr/bin/env python3
"""Builds data/quaddicted/maps.txt, the list of the in-game map browser.

The maps come from Quaddicted's metadata (https://github.com/Quaddicted/
quaddicted-data, one JSON per release, keyed by the zip's SHA-256) and the
ratings from Quaddicted's last Quake Injector database (frozen in 2026, but
the only place with the ratings). Listed: releases that install into id1
(maps, episodes, speedmaps and jams whose .bsp files land in id1/maps/),
mods that install into one directory of their own, and maps that need one
mod named by a dependency tag; the game mounts the zips on top of its paks.

    python3 tools/quaddicted_catalog.py                   # fetch both and write the list
    python3 tools/quaddicted_catalog.py --data DIR --xml FILE   # from local copies

One line per release, tab separated:

    id  sha256  bytes  title  author  date  rating  size  flags  startmaps  mapping  url  gamedir  needs  paks

id is the zip's name without .zip, rating Quaddicted's 0..5 (empty when not
rated), size small / medium / large, flags a comma list (limits: needs a
port with raised limits, lit, bsp2, singleplayer, deathmatch, coop),
startmaps the maps to start (a comma list, the first one is the default),
mapping how the zip's paths land in the game directory (from>to pairs
separated by ';', to relative to the Quake directory: 'tofaz/>id1/maps/'),
gamedir the Quake directory it plays in (id1, or a mod's: quoth, ad...),
needs the ids of the mod releases it needs (installed and mounted first) and
paks a mod's own pak files inside its zip (mounted after its loose files).
Mods (Quoth, Arcane Dimensions, Copper...) are listed too: their maps play
with their QuakeC (QuakeC mode).
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


def landed(entry):
    """[(zip path, where it lands)] of the release's files (skipped ones left out)"""
    mapping = mapping_of(entry)
    result = []
    for p in entry.get('files', {}):
        if p.endswith('/'):
            continue
        final = place(p, mapping)
        if final is not None:
            result.append((p, final))
    return result


def game_dir_of(files):
    """The one Quake directory (id1, quoth, ad...) the files land in, or None"""
    dirs = set(final.strip('/').split('/')[0].lower() for _, final in files if final.strip('/').count('/') >= 1 or
               final.lower().endswith('.pak'))
    return dirs.pop() if len(dirs) == 1 else None


def mod_paks(files, game_dir):
    """The zip paths of the paks a mod puts in its directory, pak0 first"""
    paks = []
    for path, final in files:
        rest = final.strip('/')[len(game_dir) + 1:].lower()
        if re.fullmatch(r'pak\d\.pak', rest):
            paks.append((rest, path))
    return [path for _, path in sorted(paks)]


def nested_maps(entry, game_dir):
    """Map names inside the release's paks (maps/x.bsp in a pak in the mod's directory)"""
    names = []
    mapping = mapping_of(entry)
    for path, info in entry.get('files', {}).items():
        final = place(path, mapping)
        if final is None or not path.lower().endswith('.pak') or not isinstance(info, dict):
            continue
        for inner in info.get('files', {}):
            if inner.lower().startswith('maps/') and inner.lower().endswith('.bsp'):
                names.append(os.path.splitext(os.path.basename(inner))[0].lower())
    return names


def build(data_dir, ratings):
    lines = []
    skipped = {}
    entries = {}
    for path in sorted(glob.glob(os.path.join(data_dir, 'json', 'by-sha256', '*', '*.json'))):
        with open(path, encoding='utf-8') as f:
            e = json.load(f)
        filename = (tag_values(e.get('tags', []), 'filename') or [''])[0]
        if filename.lower().endswith('.zip'):
            entries[filename[:-4].lower()] = e

    def mod_info(ident):
        """(game dir, paks) of a mod release that installs into one directory other than id1"""
        e = entries.get(ident)
        if e is None:
            return None
        files = landed(e)
        game_dir = game_dir_of(files)
        if game_dir is None or game_dir == 'id1':
            return None
        if any(p.lower().endswith('progs.dat') for p, _ in files) or mod_paks(files, game_dir):
            return game_dir, mod_paks(files, game_dir)
        return None

    # Releases other ones need are listed even without maps of their own
    required = set()
    for e in entries.values():
        required.update(d.lower() for d in tag_values(e.get('tags', []), 'dependency'))

    for ident in sorted(entries):
        e = entries[ident]
        tags = e.get('tags', [])
        kinds = tag_values(tags, 'type')
        filename = (tag_values(tags, 'filename') or [''])[0]
        reason = None
        game_dir = 'id1'
        needs = []
        paks = []
        files = landed(e)
        if not set(kinds) & (TYPES | {'mod'}) and ident not in required:
            reason = 'type ' + ','.join(kinds)
        elif tag_values(tags, 'game') not in ([], ['quake']):
            reason = 'another game'
        if reason is None:
            deps = [d.lower() for d in tag_values(tags, 'dependency')]
            if not deps and tag_values(tags, 'depends'):
                reason = 'a dependency not by name'
            for d in deps:
                info = mod_info(d)
                if info is None:
                    reason = 'needs %s' % ('a mission pack' if d in ('hipnotic', 'rogue') else 'an unknown release')
                    break
                if game_dir not in ('id1', info[0]):
                    reason = 'needs two mods'
                    break
                game_dir = info[0]
                needs.append(d)
        if reason is None and not needs and ('mod' in kinds or ident in required):
            info = mod_info(ident)
            if info is None:
                reason = 'a mod outside one directory'
            else:
                game_dir, paks = info
        if reason is None:
            if game_dir == 'id1':
                if not all(final.lower().startswith('/id1/') for _, final in files):
                    reason = 'installs outside id1'
                elif any(p.lower().endswith('progs.dat') for p, _ in files):
                    reason = 'own progs.dat'
            elif not needs:
                pass
            elif any(not final.lower().startswith('/%s/' % game_dir) and not final.lower().startswith('/id1/maps/')
                     for _, final in files):
                reason = 'installs outside its mod'
        if reason is None:
            bsps = [final for _, final in files if final.lower().endswith('.bsp') and '/maps/' in final.lower()]
            names = [os.path.splitext(os.path.basename(x))[0].lower() for x in bsps] + nested_maps(e, game_dir)
            starts = [s.lower() for s in tag_values(tags, 'startmap') if s.lower() in names or paks]
            if not starts:
                starts = sorted(set(names))
            if not starts and ident not in required:
                reason = 'no maps'
        if reason:
            skipped[reason] = skipped.get(reason, 0) + 1
            continue
        flags = []
        if tag_values(tags, 'exceeds_quake_limits') == ['yes'] or tag_values(tags, 'exceedslimits'):
            flags.append('limits')
        if any(p.lower().endswith('.lit') for p, _ in files):
            flags.append('lit')
        if any('bsp2' in t.lower() for t in tag_values(tags, 'bsp_format')):
            flags.append('bsp2')
        if game_dir != 'id1':
            flags.append('mod')
        if not starts:
            flags.append('hidden')
        for mode in tag_values(tags, 'game_mode'):
            if mode in ('singleplayer', 'deathmatch', 'coop') and mode not in flags:
                flags.append(mode)
        rating = ratings.get(filename[:-4])
        date = (tag_values(tags, 'release_date') or [''])[0]
        pairs = []
        for key, target in sorted(mapping_of(e).items()):
            if target is None or target == 'None':
                continue
            target = target.lstrip('/')
            # A map for a mod that installs into id1/maps goes to the mod's maps
            if game_dir != 'id1' and target.lower().startswith('id1/'):
                target = game_dir + target[3:]
            pairs.append('%s>%s' % (key.lstrip('/'), target))
        title = clean((tag_values(tags, 'title') or [filename[:-4]])[0])
        author = clean(', '.join(tag_values(tags, 'author')))
        url = e['urls'][0] if e.get('urls') else 'https://www.quaddicted.com/filebase/' + filename
        fields = [filename[:-4], e['sha256'], str(e['bytes']), title, author, date,
                  '' if rating is None else '%.2f' % rating,
                  (tag_values(tags, 'map_size') or [''])[0], ','.join(flags), ','.join(starts),
                  ';'.join(pairs), url, game_dir, ','.join(needs), ','.join(paks)]
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
        f.write('# id\tsha256\tbytes\ttitle\tauthor\tdate\trating\tsize\tflags\tstartmaps\tmapping\turl\tgamedir\tneeds\tpaks\n')
        for line in lines:
            f.write(line + '\n')
    print('%d maps written to %s' % (len(lines), args.out))
    for reason, n in sorted(skipped.items(), key=lambda x: -x[1]):
        print('  skipped %d: %s' % (n, reason))
    return 0


if __name__ == '__main__':
    sys.exit(main())
