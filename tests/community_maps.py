#!/usr/bin/env python3
"""Community map regression set: maps made for modern Quake engines, played
headless with the culling and frame time checks.

The BSP2 and protocol tests use E1M1 converted; these are real community
maps from Quaddicted (not bundled: their authors ask to be asked before
redistribution, so the zips are fetched by URL and checked by SHA-256):

    tofaz   Temple of Azathoth (BSP2, colored light, worldspawn fog)
    digs08  The Isolation (a large BSP29 map, 38614 faces, colored light)
    grim    The Grim Outpost (BSP2)
    udob1_4 Drowning in Space, a map for Copper (the map browser installs
            Copper with it and plays it with Copper's QuakeC)
    ad      Arcane Dimensions 1.81, the mod made for QuakeSpasm (320 MB, put
            in the config directory as installed): its hub and first map
            with its QuakeC, thousands of edicts, fence textures, sprites,
            translucent entities and the fog and water alpha it stuffs

Run from the repository root after a release build:

    python3 tests/community_maps.py                # exit code = failures
    python3 tests/community_maps.py --update       # rewrite tests/community_budgets.json
    python3 tests/community_maps.py --cache DIR    # where the zips are kept

For each map: it loads in the expected format (with its .lit and fog), a
play run teleports to the player start and items spread over the level
(away from triggers) where NC renders with and without PVS culling (no pixel
may differ) and Z logs one second of frame times with the PVS counts, and a
QuakeC run spawns the level through progs.dat. The counts must stay within
the budget's margin at the same camera leaf (like the budgets scenario);
the frame times only fail when far off their budget (3 times it plus 50 ms:
the runners' software rendering is noisy). The measured values go to
<out>/community.json and the workflow run's summary.
"""

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scenarios  # noqa: E402  (game_command, FRAMES_RE, budget_margin, views)

BUDGETS_PATH = os.path.join(ROOT, 'tests', 'community_budgets.json')
MAPS = [
    {'name': 'tofaz', 'zip': 'tofaz.zip', 'format': 'BSP2', 'lit': True, 'fog': True,
     'sha256': '85c31466dda028d264b89ce54d613dfd7383306db97dc2b94f95cfce2a8cb8dc'},
    {'name': 'digs08', 'zip': 'digs08.zip', 'format': 'BSP29', 'lit': True, 'fog': False,
     'sha256': 'e5e001007b6ccf799421b86f50c04523dc154295ae1e753eeb81cb18c67c5410'},
    {'name': 'grim', 'zip': 'grim_rezipped.zip', 'format': 'BSP2', 'lit': False, 'fog': False,
     'sha256': '35a12c80b60c2fee75d50476f10b0ae826e561fa376cf9447237aeea52ce0a2b'},
]
URL = 'https://www.quaddicted.com/filebase/'
SPOTS = 4                 # the player start and three items
TRIGGER_CLEARANCE = 256   # spots this far from trigger brushes (a teleporter or exit would end the run)
NC_RE = re.compile(r'PVS compare: (\d+) of (\d+) pixels differ \((\d+) alone\)')
EDICTS_RE = re.compile(r'(\d+) edicts in use')


def fetch(cache, entry):
    """The zip from the cache, downloaded when missing; None when it cannot be had"""
    os.makedirs(cache, exist_ok=True)
    path = os.path.join(cache, entry['zip'])
    for attempt in range(2):
        if not os.path.exists(path):
            try:
                with urllib.request.urlopen(URL + entry['zip'], timeout=600) as response, open(path + '.part', 'wb') as f:
                    shutil.copyfileobj(response, f)
                os.replace(path + '.part', path)
            except Exception as e:  # network trouble: reported as a failure of this map
                print('  download of %s failed: %s' % (entry['zip'], e))
                return None
        sha = hashlib.sha256()
        with open(path, 'rb') as f:
            for chunk in iter(lambda: f.read(1 << 20), b''):
                sha.update(chunk)
        digest = sha.hexdigest()
        if digest == entry['sha256']:
            return path
        print('  %s has SHA-256 %s, expected %s: fetching it again' % (entry['zip'], digest, entry['sha256']))
        os.remove(path)
    return None


def install(zip_path, mod_dir):
    """The zip's .bsp and .lit files into <mod>/maps"""
    maps = os.path.join(mod_dir, 'maps')
    os.makedirs(maps, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            base = os.path.basename(info.filename)
            if base.lower().endswith(('.bsp', '.lit')):
                with z.open(info) as src, open(os.path.join(maps, base.lower()), 'wb') as dst:
                    shutil.copyfileobj(src, dst)


def spots(bsp_path):
    """Camera spots (CGE coordinates, eyes 40 units above the origin): the
    player start and the items farthest from each other and from triggers"""
    with open(bsp_path, 'rb') as f:
        data = f.read()
    offset, length = struct.unpack_from('<ii', data, 4)
    text = data[offset:offset + length].decode('latin1')
    models_offset, models_length = struct.unpack_from('<ii', data, 4 + 14 * 8)
    models = [struct.unpack_from('<6f', data, models_offset + i * 64) for i in range(models_length // 64)]
    triggers, starts, items = [], [], []
    for body in re.findall(r'\{([^}]*)\}', text):
        cls = re.search(r'"classname"\s+"([^"]+)"', body)
        if not cls:
            continue
        cls = cls.group(1)
        model = re.search(r'"model"\s+"\*(\d+)"', body)
        if cls.startswith('trigger_') and model and int(model.group(1)) < len(models):
            triggers.append(models[int(model.group(1))])
        origin = re.search(r'"origin"\s+"([^"]+)"', body)
        if not origin:
            continue
        try:
            point = tuple(float(v) for v in origin.group(1).split()[:3])
        except ValueError:
            continue
        if cls == 'info_player_start':
            starts.append(point)
        elif cls.startswith(('item_', 'weapon_')):
            items.append(point)

    def clearance(p):
        best = 1e9
        for box in triggers:
            d = [max(box[i] - p[i], 0, p[i] - box[i + 3]) for i in range(3)]
            best = min(best, math.sqrt(sum(v * v for v in d)))
        return best

    chosen = starts[:1]
    candidates = [p for p in items if clearance(p) > TRIGGER_CLEARANCE]
    while len(chosen) < SPOTS and candidates:
        best = max(candidates, key=lambda p: min(sum((p[i] - c[i]) ** 2 for i in range(3)) for c in chosen)
                   if chosen else 0)
        chosen.append(best)
        candidates.remove(best)
    return ['%g;%g;%g' % (x, z + 40, -y) for x, y, z in chosen]


def run(exe, args, log_path):
    with open(log_path, 'w') as log:
        try:
            code = subprocess.run(scenarios.game_command(exe, args), stdout=log, stderr=subprocess.STDOUT, cwd=ROOT,
                                  timeout=scenarios.PROCESS_TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    with open(log_path, errors='replace') as f:
        return code, f.read()


def check_map(exe, out, mod, entry, budgets, update, results, measured):
    name = entry['name']
    bsp = os.path.join(mod, 'maps', name + '.bsp')
    if not os.path.exists(bsp):
        results.append((False, '%s: maps/%s.bsp in the zip' % (name, name)))
        return
    places = spots(bsp)
    demo = 'W:2,Y,' + ''.join('G:%s,W:0.5,Z,W:1,Z,NC,' % p for p in places) + 'Q'
    code, log = run(exe, ['-game', mod, '--autotest', name, os.path.join(out, name), '--demo', demo],
                    os.path.join(out, name + '.log'))
    results.append((code == 0, '%s: the play run exits with 0 (got %s)' % (name, code)))
    results.append(('An unhandled exception' not in log and 'Exception "' not in log, '%s: no exception' % name))
    results.append(('Loaded map "maps/%s.bsp" (%s)' % (name, entry['format']) in log,
                    '%s: loads as %s' % (name, entry['format'])))
    if entry['lit']:
        results.append(('Colored lightmaps from "maps/%s.lit"' % name in log, '%s: its .lit colors the lightmaps' % name))
    if entry['fog']:
        results.append(('Fog: density' in log, '%s: its worldspawn fog is applied' % name))
    results.append((log.count('Loading level') == 1, '%s: no level change during the run' % name))
    frames = scenarios.FRAMES_RE.findall(log)[::2]
    compares = NC_RE.findall(log)
    results.append((len(frames) == len(places) and len(compares) == len(places),
                    '%s: a Z line and a PVS compare at each of the %d spots (got %d, %d)'
                    % (name, len(places), len(frames), len(compares))))
    # A lone pixel is a crack between two faces showing what lies behind it
    for i, (differ, total, alone) in enumerate(compares):
        results.append((differ == alone, '%s spot %d: culling changes no pixel but lone ones (%s of %s differ, %s alone)'
                        % (name, i + 1, differ, total, alone)))
    rows = [{'spot': spot, 'leaf': int(m[5]), 'clusters': int(m[6]), 'shapes': int(m[8]), 'entities': int(m[10]),
             'ms_average': float(m[2]), 'ms_longest': float(m[3])} for spot, m in zip(places, frames)]
    # QuakeC: progs.dat spawns the level and runs it for a few seconds
    code, qclog = run(exe, ['-game', mod, '--autotest', 'qc:' + name, os.path.join(out, name + '_qc'), '--demo',
                            'W:3,E,Q'], os.path.join(out, name + '_qc.log'))
    edicts = EDICTS_RE.findall(qclog)
    results.append((code == 0 and edicts and int(edicts[-1]) >= 100 and 'Exception "' not in qclog,
                    '%s: QuakeC spawns the level (%s edicts, exit %s)' % (name, edicts[-1] if edicts else 0, code)))
    measured[name] = {'spots': rows, 'qc_edicts': int(edicts[-1]) if edicts else 0}
    if update:
        return
    budget = budgets.get(name)
    if budget is None:
        results.append((False, '%s: has a budget (run with --update)' % name))
        return
    for i, (row, b) in enumerate(zip(rows, budget['spots'])):
        where = '%s spot %d (%s)' % (name, i + 1, row['spot'])
        if row['spot'] != b['spot'] or row['leaf'] != b['leaf']:
            results.append((False, '%s: camera in leaf %d, budgeted in leaf %d (--update if intended)'
                            % (where, row['leaf'], b['leaf'])))
            continue
        for kind in ('clusters', 'shapes', 'entities'):
            limit = scenarios.budget_margin(b[kind], kind)
            results.append((row[kind] <= limit, '%s: %d %s drawn (budget %d, limit %.0f)'
                            % (where, row[kind], kind, b[kind], limit)))
        limit = 3 * b['ms_average'] + 50
        results.append((row['ms_average'] <= limit, '%s: %.1f ms per frame (budget %.1f, limit %.0f)'
                        % (where, row['ms_average'], b['ms_average'], limit)))


AD = {'name': 'ad', 'id': 'ad_v1_80p1final', 'zip': 'ad_v1_80p1final.zip',
      'sha256': '7ad993da6c760c446ca31fad71e9f5b6c9eee99b6354f161aa746b572fe70a7d'}
DRAWN_RE = re.compile(r'Entities drawn: (\d+) models, (\d+) sprites, (\d+) translucent')


def config_dir():
    """Where the game keeps castle-config:/ on Linux and macOS"""
    base = os.environ.get('XDG_CONFIG_HOME') or os.path.join(os.path.expanduser('~'), '.config')
    return os.path.join(base, 'castle-quake1')


def check_arcane_dimensions(exe, out, cache, results):
    """Arcane Dimensions, QuakeSpasm's showcase mod: the zip goes to the
    config directory as the map browser keeps an installed one, which then
    mounts it (unpacking its deflated paks once) and plays two of its maps
    with AD's progs.dat"""
    zip_path = fetch(cache, AD)
    if zip_path is None:
        results.append((False, 'ad: %s downloaded with the expected SHA-256' % AD['zip']))
        return
    os.makedirs(config_dir(), exist_ok=True)
    installed = os.path.join(config_dir(), 'quaddicted_%s.zip' % AD['id'])
    if not os.path.exists(installed) or os.path.getsize(installed) != os.path.getsize(zip_path):
        shutil.copyfile(zip_path, installed)
    runs = [('start', 'W:0.5,CMD:maps_play %s start,W:10,Y,G:-140;100;230,A:270,W:1,S,Q' % AD['id']),
            ('ad_e1m1', 'W:0.5,CMD:maps_play %s ad_e1m1,W:10,S,Q' % AD['id'])]
    for name, demo in runs:
        code, log = run(exe, ['--autotest', 'e1m1', os.path.join(out, 'ad_' + name), '--demo', demo],
                        os.path.join(out, 'ad_%s.log' % name))
        tag = 'ad %s' % name
        results.append((code == 0 and 'Exception "' not in log, '%s: the run exits with 0 (got %s)' % (tag, code)))
        results.append(('Playing "%s" in QuakeC mode (ad)' % name in log and
                        'Level "%s" spawned by the progs' % name in log, '%s: AD\'s QuakeC spawns the level' % tag))
        errors = re.findall(r'QuakeC error in (\w+)', log)
        results.append((not errors and 'no free edicts' not in log,
                        '%s: no QuakeC errors (%s)' % (tag, ', '.join(sorted(set(errors))) or 'none')))
        qc_lines = [l for l in log.splitlines() if l.startswith('QuakeC: ')]
        results.append((all(all(ord(c) < 128 for c in l) for l in qc_lines),
                        '%s: the gold text of the prints reads as plain text' % tag))
        drawn = DRAWN_RE.findall(log)
        models, sprites, translucent = (int(x) for x in drawn[-1]) if drawn else (0, 0, 0)
        if name == 'start':
            results.append(('Fence textures (alpha tested)' in log, '%s: the fence textures are cut out' % tag))
            results.append((sprites > 0 and 'Loaded sprite' in log, '%s: sprites drawn (%d)' % (tag, sprites)))
            results.append((translucent > 0, '%s: translucent entities drawn (%d of %d models and sprites)'
                            % (tag, translucent, models + sprites)))
        else:
            results.append(('Stuffed fog: density' in log and 'Stuffed r_wateralpha' in log,
                            '%s: the fog and water alpha AD stuffs are applied' % tag))


def check_mod_map(exe, out, results):
    """A map for a mod through the map browser: udob1_4 (Drowning in Space)
    needs Copper, which the game downloads first from Quaddicted, mounts in
    copper/ and plays with Copper's progs.dat in QuakeC mode"""
    demo = ('W:0.5,CMD:maps_remove udob1_4,CMD:maps_remove copper_v1_15,CMD:maps_install udob1_4,W:60,'
            'CMD:maps installed,CMD:maps_play udob1_4,W:3,S,Q')
    code, log = run(exe, ['--autotest', 'e1m1', os.path.join(out, 'udob1_4'), '--demo', demo],
                    os.path.join(out, 'udob1_4.log'))
    results.append((code == 0 and 'Exception "' not in log, 'udob1_4: the run exits with 0 (got %s)' % code))
    results.append(('Map "copper_v1_15" installed' in log and 'Map "udob1_4" installed' in log,
                    'udob1_4: Copper and the map download with their SHA-256'))
    results.append(('Mounted "udob1_4" (Drowning in Space) in copper' in log and
                    'Playing "udob1_4" in QuakeC mode (copper)' in log, 'udob1_4: it plays in copper/ with QuakeC'))
    progs = re.findall(r'Loaded "progs.dat": (\d+) statements', log)
    results.append((bool(progs) and int(progs[-1]) > 30000, 'udob1_4: Copper\'s progs.dat runs (%s statements)'
                    % (progs[-1] if progs else 0)))
    results.append(('Level "udob1_4" spawned by the progs' in log and 'Saved screenshot' in log,
                    'udob1_4: the level spawns and the view goes on'))
    # Leave nothing in the config directory
    run(exe, ['--autotest', 'e1m1', os.path.join(out, 'udob1_4_remove'), '--demo',
              'W:0.5,CMD:maps_remove udob1_4,CMD:maps_remove copper_v1_15,Q'], os.path.join(out, 'udob1_4_remove.log'))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exe', default=os.path.join(ROOT, 'castle-quake1' + ('.exe' if os.name == 'nt' else '')))
    parser.add_argument('--out', default=os.path.join(ROOT, 'castle-engine-output', 'community'))
    parser.add_argument('--cache', default=os.environ.get('COMMUNITY_MAPS_CACHE',
                                                        os.path.join(ROOT, 'castle-engine-output', 'community-cache')))
    parser.add_argument('--update', action='store_true', help='write the measured counts and times as the budgets')
    args = parser.parse_args()
    if not os.path.exists(args.exe):
        print('No game executable at %s: build it first (castle-engine compile --mode=release)' % args.exe)
        return 2
    shutil.rmtree(args.out, ignore_errors=True)
    mod = os.path.join(args.out, 'mod')
    os.makedirs(mod)
    budgets = {}
    if os.path.exists(BUDGETS_PATH):
        with open(BUDGETS_PATH) as f:
            budgets = json.load(f)
    results, measured = [], {}
    for entry in MAPS:
        print('=== %s' % entry['name'], flush=True)
        zip_path = fetch(args.cache, entry)
        if zip_path is None:
            results.append((False, '%s: %s downloaded with the expected SHA-256' % (entry['name'], entry['zip'])))
            continue
        install(zip_path, mod)
        start = len(results)
        check_map(args.exe, args.out, mod, entry, budgets, args.update, results, measured)
        for ok, text in results[start:]:
            print('  %s %s' % ('ok  ' if ok else 'FAIL', text), flush=True)
    print('=== udob1_4 (needs Copper)', flush=True)
    start = len(results)
    check_mod_map(args.exe, args.out, results)
    for ok, text in results[start:]:
        print('  %s %s' % ('ok  ' if ok else 'FAIL', text), flush=True)
    print('=== Arcane Dimensions', flush=True)
    start = len(results)
    check_arcane_dimensions(args.exe, args.out, args.cache, results)
    for ok, text in results[start:]:
        print('  %s %s' % ('ok  ' if ok else 'FAIL', text), flush=True)
    with open(os.path.join(args.out, 'community.json'), 'w') as f:
        json.dump(measured, f, indent=1)
    if args.update:
        with open(BUDGETS_PATH, 'w') as f:
            f.write('{\n' + ',\n'.join('  %s: {"qc_edicts": %d, "spots": [\n%s\n  ]}' % (
                json.dumps(name), m['qc_edicts'], ',\n'.join('    ' + json.dumps(r) for r in m['spots']))
                for name, m in measured.items()) + '\n}\n')
        print('budgets written to %s' % os.path.relpath(BUDGETS_PATH, ROOT))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as f:
            f.write('### Community maps\n\n| map | spot | ms average | ms longest | clusters | shapes | entities |\n'
                    '|---|---|---|---|---|---|---|\n')
            for name, m in measured.items():
                for r in m['spots']:
                    f.write('| %s | %s | %.1f | %.1f | %d | %d | %d |\n' % (
                        name, r['spot'], r['ms_average'], r['ms_longest'], r['clusters'], r['shapes'], r['entities']))
            f.write('\n')
    failures = sum(1 for ok, _ in results if not ok)
    print('%d failure(s)' % failures)
    return min(failures, 100)


if __name__ == '__main__':
    sys.exit(main())
