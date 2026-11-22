"""Checks of the single-player scenarios: levels, saves, records, modes, input, the HUD's languages."""

import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time

from PIL import Image, ImageChops

import qtest
from qtest import *  # noqa: F401,F403


def check_records(logs):
    result = common_checks(logs, 'rec1') + common_checks(logs, 'rec2')
    a, b = logs['rec1'], logs['rec2']
    m = re.search(r'Record of "e1m1" on Normal: (\d+):(\d+\.\d+), kills 0/23, secrets 0/6, 1 runs; new: first run', a)
    result.append((m is not None, 'the first finish of E1M1 is its record'))
    first = int(m.group(1)) * 60 + float(m.group(2)) if m else 0
    m = re.search(r'Record of "e1m1" on Normal: (\d+):(\d+\.\d+), kills 0/23, secrets 0/6, 2 runs; new: time', b)
    second = int(m.group(1)) * 60 + float(m.group(2)) if m else 0
    result.append((m is not None and second < first, 'a faster second run is a new record (%.2f s after %.2f s)'
                   % (second, first)))
    result.append(('Record e1m1 on Normal:' in b and 'Map records: 1' in b, 'the console lists the record'))
    result.append((re.search(r'Menu: Hint: Records: Normal: 0:\d\d\.\d\d, kills 0/23, secrets 0/6', b) is not None,
                   'the map list shows the record of the selected map'))
    return result


def check_photo(logs):
    result = common_checks(logs, 'play') + common_checks(logs, 'pdemo')
    log = logs['play']
    result.append(('Photo mode on' in log and 'Photo mode off' in log, 'photo mode goes on and off'))
    times = [float(t) for t in re.findall(r'Photo: Level time ([\d.]+)', log)]
    result.append((len(times) == 2 and times[0] == times[1],
                   'the game stands still in photo mode (level time %s)' % ' -> '.join('%.2f' % t for t in times)))
    photos = PHOTO_RE.findall(log)
    result.append((len(photos) == 2 and photos[0][1:] == ('3200', '1800', '90', 'dof'),
                   'a depth of field photo at twice the window size (%s)' % (' '.join(photos[0][1:]) if photos else '-')))
    result.append((len(photos) == 2 and photos[1][1:] == ('1600', '900', '60', 'gray'),
                   'a grayscale photo at the window size with its own field of view (%s)' %
                   (' '.join(photos[1][1:]) if len(photos) > 1 else '-')))
    helped = re.search(r'Console: help \((\d+) commands, (\d+) lines\)', log)
    result.append((helped is not None and int(helped.group(1)) >= 40 and int(helped.group(2)) >= 35,
                   'the play view\'s command table answers help (%s)' % (helped.group(0) if helped else 'no line')))
    v = views(log)
    result.append((len(v) == 3 and v[1]['eye'] != v[0]['eye'], 'the camera flies away from the player'))
    result.append((len(v) == 3 and v[2]['eye'] == v[0]['eye'], 'leaving puts the camera back on the player'))
    d = logs['pdemo']
    shots = [float(t) for t in DEMO_SHOT_RE.findall(d)]
    result.append((len(shots) == 3 and shots[0] == shots[1] and shots[2] > shots[1],
                   'the demo waits in photo mode and goes on after (time %s)' % ' -> '.join('%.1f' % t for t in shots)))
    demo_photos = PHOTO_RE.findall(d)
    result.append((len(demo_photos) == 1 and demo_photos[0][4] == 'vignette', 'a photo from demo playback'))
    result.append((re.search(r'Console: help \(\d+ settings lines\)', d) is not None and 'Console: fov: fov' in d and
                   'Command not run in a demo: nosuch 1' in d,
                   'the demo view\'s console: help, a settings command and an unknown one'))
    return result


def frames_photo(out_dir):
    result = []
    for name, size in (('play_photo_1.png', (3200, 1800)), ('play_photo_2.png', (1600, 900)),
                       ('pdemo_photo_1.png', (3200, 1800))):
        path = os.path.join(out_dir, name)
        ok = os.path.exists(path) and Image.open(path).size == size
        result.append((ok, '%s is %dx%d' % (name, size[0], size[1])))
    path = os.path.join(out_dir, 'play_photo_2.png')
    if os.path.exists(path):
        im = Image.open(path).convert('RGB').resize((160, 90))
        spread = max(max(px) - min(px) for px in im.getdata())
        bright = sum(sum(px) for px in im.getdata()) / (160 * 90 * 3)
        result.append((spread <= 3 and bright > 10, 'the grayscale photo is gray and not black '
                       '(channel spread %d, brightness %.1f)' % (spread, bright)))
    return result


def check_saves(logs):
    result = common_checks(logs, 'menusave') + common_checks(logs, 'startload')
    log = logs['menusave']
    result.append(('Saved game to "castle-config:/save_8.sav"' in log, 'Save Game in the menu saves slot 8'))
    result.append(('Thumbnail of slot 8 saved: 320x180' in log, 'the slot gets a thumbnail of the view'))
    m = re.search(r'Save 8: e1m1, health \d+, kills \d+/\d+, skill \d, \d+ s, (\S+ \S+), thumbnail (\w+)', log)
    result.append((m is not None and m.group(2) == 'yes', 'the saves list has slot 8 with its date and thumbnail (%s)' %
                   (m.group(1) if m else '-')))
    saves = re.findall(r'  Save (\S+): ', log)
    result.append((bool(saves) and saves[0] == '8', 'the newest save comes first (%s)' % ', '.join(saves[:4])))
    result.append(('Loaded game from "castle-config:/save_8.sav"' in log, 'Load Game in the menu loads it'))
    v = views(log)

    def near(a, b):
        return max(abs(x - y) for x, y in zip(a, b)) < 2

    result.append((len(v) == 3 and not near(v[1]['eye'], v[0]['eye']), 'the player moved away after saving'))
    result.append((len(v) == 3 and near(v[2]['eye'], v[0]['eye']),
                   'loading puts the player back where it was saved, standing (%s)' %
                   (' '.join('%.1f' % x for x in v[2]['eye']) if len(v) == 3 else '-')))
    s = logs['startload']
    w = views(s)
    result.append(('Loaded game from "castle-config:/save_8.sav"' in s and len(w) == 1 and len(v) == 3 and
                   near(w[0]['eye'], v[0]['eye']), 'load:8 starts the game from the savegame'))
    return result


def check_language(logs):
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import lang_strings
    result = common_checks(logs, 'de') + common_checks(logs, 'it') + common_checks(logs, 'ro')
    de = lang_strings.parse_po(os.path.join(ROOT, 'data', 'lang', 'de.po'))[1]
    it = lang_strings.parse_po(os.path.join(ROOT, 'data', 'lang', 'it.po'))[1]
    pad = 'D-pad to navigate, %s to select, %s to go back'
    log = logs['de']
    result.append((re.search(r'Language: de \(Deutsch\), \d{3} texts', log) is not None,
                   'de: -lang de loads the German texts'))
    result.append(('Hint: ' + de[pad] % ('A', 'B') in log, 'de: the menu hint is German'))
    browser = de['%d maps from Quaddicted: %s shows one, %s goes back, left / right turn the pages']
    result.append((re.search(re.escape('Hint: ' + browser.replace('%d', '\x00').replace('%s', '\x01'))
                             .replace('\x00', r'\d+').replace('\x01', '[AB]'), log) is not None,
                   'de: the map browser hint is German'))
    log = logs['it']
    result.append(('Language: en (English), 0 texts' in log, 'it: a test starts in English'))
    result.append((re.search(r'Language: it \(Italiano\), \d{3} texts', log) is not None,
                   'it: the console lang command switches to Italian'))
    result.append(('Hint: ' + it[pad] % ('A', 'B') in log, 'it: the menu hint is Italian'))
    ro = lang_strings.parse_po(os.path.join(ROOT, 'data', 'lang', 'ro.po'))[1]
    log = logs['ro']
    result.append((re.search(r'Language: ro \(Română\), \d{3} texts', log) is not None,
                   'ro: -lang ro loads the Romanian texts'))
    result.append(('Hint: ' + ro[pad] % ('A', 'B') in log, 'ro: the menu hint is Romanian'))
    return result


def check_pads(logs):
    result = []
    for prefix, family, confirm, back in (('ps', 'PlayStation', 'Cross', 'Circle'), ('switch', 'Nintendo', 'A', 'B'),
                                          ('xbox', 'Xbox', 'A', 'B')):
        log = logs[prefix]
        result += common_checks(logs, prefix)
        result.append(('%s buttons, %s confirms, %s goes back' % (family, confirm, back) in log,
                       '%s: the pad is told by its name' % prefix))
        result.append(('Menu opened from the gamepad' in log, '%s: Start opens the menu' % prefix))
        result.append(('Hint: D-pad to navigate, %s to select, %s to go back' % (confirm, back) in log,
                       '%s: the menu names its buttons' % prefix))
        result.append(('Map catalog' in log and '%s shows one, %s goes back' % (confirm, back) in log,
                       '%s: %s confirms into the map browser' % (prefix, confirm)))
        result.append(('Menu closed from the gamepad' in log, '%s: %s on the main page closes the menu' % (prefix, back)))
        v = views(log)
        result.append((len(v) == 2 and abs(v[1]['eye'][2] - v[0]['eye'][2]) < 1,
                       '%s: closing with the jump button does not jump (eye height %s)' %
                       (prefix, ' -> '.join('%.1f' % x['eye'][2] for x in v))))
    return result


def check_e1m1_finish(logs):
    v = views(logs['finish'])
    result = common_checks(logs, 'finish')
    result.append((len(v) == 4, 'four screenshots (got %d)' % len(v)))
    if len(v) == 4:
        result.append((v[0]['map'] == 'e1m1', 'starts in e1m1'))
        result.append((v[1]['eye'][1] - v[0]['eye'][1] > 200,
                       'walked forward with the physics (%.0f units)' % (v[1]['eye'][1] - v[0]['eye'][1])))
        result.append((v[2]['intermission'], 'the exit starts the intermission'))
        result.append((v[3]['map'] == 'e1m2' and not v[3]['intermission'], 'a button press loads e1m2'))
    result.append(('Successfully initialized map "maps/e1m2.bsp"' in logs['finish'], 'e1m2 initialized'))
    return result


def check_e1m1_saveload(logs):
    log = logs['saveload']
    result = common_checks(logs, 'saveload')
    saves = SAVE_RE.findall(log)
    saved = [s for kind, s in saves if kind == 'Saved']
    loaded = [s for kind, s in saves if kind == 'Loaded']
    result.append((len(saved) == 1 and len(loaded) == 1, 'one save and one load (%d, %d)' % (len(saved), len(loaded))))
    if saved and loaded:
        result.append((saved[0] == loaded[0], 'the load restores what was saved: "%s" / "%s"' % (saved[0], loaded[0])))
        health = int(re.search(r'health (-?\d+)', saved[0]).group(1))
        shells = int(re.search(r'shells (\d+)', saved[0]).group(1))
        result.append((shells == 23, 'two shots fired before the save (shells %d)' % shells))
        result.append((health < 100, 'saved in the middle of a fight (health %d)' % health))
    v = views(log)
    if len(v) == 2 and saved:
        before_load = v[0]['health']
        saved_health = int(re.search(r'health (-?\d+)', saved[0]).group(1))
        result.append((before_load < saved_health,
                       'the fight went on after the save (health %d after, %d saved)' % (before_load, saved_health)))
    return result


def check_liquid_items(logs):
    result = common_checks(logs, 'hub') + common_checks(logs, 'boxes')
    boxes = logs['boxes']
    result.append(('Loaded map "maps/b_bh25.bsp"' in boxes, 'the health box is the brush model maps/b_bh25.bsp'))
    result.append(('not found in PAK' not in boxes, 'no item model is missing'))
    result.append(('Picked up "You got 25 health" (maps/b_bh25.bsp)' in boxes, 'walking into the box picks it up'))
    return result


def frames_liquid_items(out_dir):
    """The liquid of the hub's NIGHTMARE wall (*blood1) is drawn and ripples:
    two frames of a still camera 0.5 s apart differ. The world textures
    carry the fullbright mask in their alpha, which made every blended
    liquid fully transparent (0 pixels changed)."""
    a = Image.open(os.path.join(out_dir, 'hub_1.png')).convert('RGB')
    b = Image.open(os.path.join(out_dir, 'hub_2.png')).convert('RGB')
    view = (0, 0, a.width, a.height * 3 // 4)
    diff = ImageChops.difference(a.crop(view), b.crop(view)).convert('L').point(lambda v: 255 if v > 8 else 0)
    changed = diff.histogram()[255]
    return [(changed > 2000, 'the liquid ripples (%d pixels changed in 0.5 s)' % changed)]


def check_budgets(logs):
    result = []
    measured = {}
    for name, spots in BUDGET_SPOTS.items():
        result += common_checks(logs, name)
        lines = FRAMES_RE.findall(logs.get(name, ''))[::2]
        result.append((len(lines) == len(spots), '%s: a Z line at each of the %d spots (got %d)'
                       % (name, len(spots), len(lines))))
        result.append((logs.get(name, '').count('Loading level') == 1,
                       '%s: no level change during the run (a spot on a trigger)' % name))
        result.append((all(int(m[5]) > 0 for m in lines), '%s: every spot is inside the map (leaf %s)'
                       % (name, ', '.join(m[5] for m in lines))))
        measured[name] = [{'spot': spot, 'leaf': int(m[5]), 'clusters': int(m[6]), 'shapes': int(m[8]),
                           'entities': int(m[10]), 'frames': int(m[0]), 'ms_average': float(m[2]),
                           'ms_longest': float(m[3])}
                          for spot, m in zip(spots, lines)]
    report = os.path.join(logs['_out'], 'budgets.json')
    with open(report, 'w') as f:
        json.dump(measured, f, indent=1)
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        # The frame times on the workflow run's page (llvmpipe: informative only)
        with open(summary, 'a') as f:
            f.write('### Performance budgets\n\n| map | spot | ms average | ms longest | clusters | shapes | entities |\n'
                    '|---|---|---|---|---|---|---|\n')
            for name, rows in measured.items():
                for r in rows:
                    f.write('| %s | %s | %.1f | %.1f | %d | %d | %d |\n' % (
                        name, r['spot'], r['ms_average'], r['ms_longest'], r['clusters'], r['shapes'], r['entities']))
            f.write('\n')
    for name, rows in measured.items():
        print('  %s: %s' % (name, '; '.join('%.1f ms, %d clusters, %d shapes, %d entities'
                                            % (r['ms_average'], r['clusters'], r['shapes'], r['entities'])
                                            for r in rows)))
    if qtest.UPDATE:
        budgets = {name: [{k: r[k] for k in ('spot', 'leaf', 'clusters', 'shapes', 'entities')} for r in rows]
                   for name, rows in measured.items()}
        with open(BUDGETS_PATH, 'w') as f:
            # One line per spot, so a diff shows which spot changed
            f.write('{\n' + ',\n'.join('  %s: [\n%s\n  ]' % (json.dumps(name), ',\n'.join(
                '    ' + json.dumps(row) for row in rows)) for name, rows in budgets.items()) + '\n}\n')
        result.append((True, 'budgets written to %s' % os.path.relpath(BUDGETS_PATH, ROOT)))
        return result
    if not os.path.exists(BUDGETS_PATH):
        result.append((False, 'budgets exist (%s; run with --update)' % os.path.relpath(BUDGETS_PATH, ROOT)))
        return result
    with open(BUDGETS_PATH) as f:
        budgets = json.load(f)
    for name, rows in measured.items():
        for i, (row, budget) in enumerate(zip(rows, budgets.get(name, []))):
            where = '%s spot %d (%s)' % (name, i + 1, row['spot'])
            if row['spot'] != budget['spot'] or row['leaf'] != budget['leaf']:
                result.append((False, '%s: the camera is in leaf %d, budgeted in leaf %d (moved spot or changed '
                               'map loading: --update if intended)' % (where, row['leaf'], budget['leaf'])))
                continue
            for kind in ('clusters', 'shapes', 'entities'):
                limit = budget_margin(budget[kind], kind)
                result.append((row[kind] <= limit, '%s: %d %s drawn (budget %d, limit %.0f)'
                               % (where, row[kind], kind, budget[kind], limit)))
    return result


def check_touch(logs):
    log = logs['touch']
    result = common_checks(logs, 'touch')
    v = views(log)
    yaws = [float(m) for m in re.findall(r'View: map \S+, eye \S+ \S+ \S+, yaw ([^,]+),', log)]
    result.append(('Touch controls shown' in log, 'the touch controls are shown'))
    result.append((len(v) == 4, 'four screenshots (got %d)' % len(v)))
    if len(v) == 4:
        result.append((v[1]['eye'][1] - v[0]['eye'][1] > 200,
                       'the move stick walks forward (%.0f units)' % (v[1]['eye'][1] - v[0]['eye'][1])))
        result.append((abs(yaws[2] - yaws[1]) > 15, 'a drag on the right turns the view (yaw %.0f -> %.0f)'
                       % (yaws[1], yaws[2])))
        result.append((v[3]['ammo'] < v[2]['ammo'], 'the fire button fires (ammo %d -> %d)'
                       % (v[2]['ammo'], v[3]['ammo'])))
    result.append(('Touch TD 4' in log and 'buttons fire on' in log, 'the button touches are logged'))
    # A portrait phone (1170 x 2532 at devicePixelRatio 3): the UI scale
    # keeps 800 design units across and the stick still walks
    phone = logs['phone']
    result += common_checks(logs, 'phone')
    result.append(('UI scale 1.46 for 1170 x 2532 pixels at density 3.00' in phone,
                   'a portrait phone gets the UI scale 1.46 (800 design units across)'))
    pv = views(phone)
    result.append((len(pv) == 2 and pv[1]['eye'][1] - pv[0]['eye'][1] > 200,
                   'the stick walks on the portrait phone (%s)' % ', '.join('%.0f' % p['eye'][1] for p in pv)))
    return result


def check_quake_hub(logs):
    log = logs['hub']
    result = common_checks(logs, 'hub')
    result.append(('Loaded map "maps/start.bsp"' in log and '5556 faces' in log, 'the id1 hub (shareware start.bsp)'))
    result.append(('Loaded model "zombie_original"' in log, 'the crucified zombies are id1\'s model, not LibreQuake\'s'))
    result.append(('"maps/start.lit" is not from the original paks of the map, ignored' in log,
                   'LibreQuake\'s start.lit is not applied to the id1 map'))
    return result


def check_randommap(logs):
    log = logs['rnd']
    result = common_checks(logs, 'rnd')
    maps = {m.group(1): m for m in RANDOM_RE.finditer(log)}
    m = maps.get('42')
    result.append((m is not None, 'random42 is built'))
    if m:
        result.append((m.group(2) == m.group(3), 'every room is reachable (%s of %s)' % (m.group(3), m.group(2))))
        # The demo script teleports to this exit: a generator change moves it
        result.append((m.group(4) == '416 480 24' and m.group(5) == '-320 768 56',
                       'the start and the exit of seed 42 (start %s, exit %s)' % (m.group(4), m.group(5))))
    result.append(('Colored lightmaps from "maps/random42.lit"' in log, 'random42 has colored light'))
    v = views(log)
    result.append((len(v) == 4, 'four screenshots (got %d)' % len(v)))
    if len(v) == 4:
        result.append((v[0]['map'] == 'random42' and v[0]['eye'] == (416, 480, 46), 'starts at the start of random42'))
        walked = ((v[1]['eye'][0] - v[0]['eye'][0]) ** 2 + (v[1]['eye'][1] - v[0]['eye'][1]) ** 2) ** 0.5
        result.append((walked > 150, 'walked toward the exit (%.0f units)' % walked))
        result.append((v[2]['intermission'], 'the exit pad starts the intermission'))
        result.append((v[3]['map'] == 'random43' and not v[3]['intermission'], 'a button press loads random43'))
    result.append(('43' in maps, 'random43 is built for the next level'))

    result += common_checks(logs, 'rqc')
    m = re.search(r'(\d+) edicts in use', logs['rqc'])
    count = int(m.group(1)) if m else 0
    result.append((count >= 40, 'progs.dat spawned random42 (%d edicts)' % count))

    host = [x.group(0) for x in RANDOM_RE.finditer(logs['rhost'])]
    client = [x.group(0) for x in RANDOM_RE.finditer(logs['rclient'])]
    result += common_checks(logs, 'rhost') + common_checks(logs, 'rclient')
    result.append((len(host) == 1 and host == client, 'the client builds the same random7 as the host'))
    result.append(('signon 4' in logs['rclient'], 'the client joins the random map'))
    return result


def check_access(logs):
    result = common_checks(logs, 'pickup') + common_checks(logs, 'monsters')
    result.append(('Caption: Health' in logs['pickup'], 'the health box is captioned'))
    hinted = re.findall(r'Caption: (.+) \((left|right|ahead|behind)\)', logs['monsters'])
    result.append((len(hinted) >= 2, 'monsters waking are captioned with a direction (%s)' %
                   ', '.join('%s %s' % h for h in hinted[:4])))
    result.append(('Caption:' not in logs['off'], 'no captions when they are off'))
    return result


def check_horde(logs):
    result = common_checks(logs, 'waves') + common_checks(logs, 'rndhorde')
    w = logs['waves']
    m = re.search(r'Horde on "e1m1": (\d+) spawn spots', w)
    result.append((m is not None and int(m.group(1)) > 20, 'E1M1 has horde spawn spots (%s)' % (m.group(1) if m else 0)))
    result.append(('Wave 1: 6 monsters' in w, 'wave 1 brings 6 monsters'))
    m = re.search(r'Wave 1 cleared: score (\d+)', w)
    result.append((m is not None and int(m.group(1)) >= 100, 'killing wave 1 clears it with a score (%s)' %
                   (m.group(1) if m else '-')))
    result.append(('Wave 2: 8 monsters' in w, 'wave 2 follows with 8 monsters'))
    v = views(w)
    result.append((len(v) == 2 and v[1]['kills'] >= 6, 'the kills count the horde (%s)' %
                   (v[1]['kills'] if len(v) == 2 else '-')))
    result.append(('Wave 1:' in logs['rndhorde'] and 'Horde on "random42"' in logs['rndhorde'],
                   'horde mode on a random map'))
    return result


def check_speedrun(logs):
    result = common_checks(logs, 'run1') + common_checks(logs, 'run2')
    r1, r2 = logs['run1'], logs['run2']
    m = re.search(r'Speedrun: e1m1 in (\d+):(\d+)\.(\d+) \(first run\)', r1)
    result.append((m is not None, 'the first run is timed'))
    result.append(('New best run of "e1m1" kept' in r1, 'the first run is kept as the ghost'))
    result.append(('Ghost of "e1m1": best' in r2, 'the second run races the ghost'))
    m = re.search(r'Checkpoint at \S+: ([-+]\d+\.\d+)', r2)
    result.append((m is not None and float(m.group(1)) > 0, 'the slower run is behind at the checkpoint (%s)' %
                   (m.group(1) if m else '-')))
    m = re.search(r'Speedrun: e1m1 in \S+ \(best \S+, ([-+]\d+\.\d+)\)', r2)
    result.append((m is not None and float(m.group(1)) > 0, 'the split at the end is behind the best (%s)' %
                   (m.group(1) if m else '-')))
    result.append(('New best run' not in r2, 'a slower run does not replace the ghost'))
    return result
