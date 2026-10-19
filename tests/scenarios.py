#!/usr/bin/env python3
"""Gameplay scenarios: scripted headless games with checks on their logs and
screenshots compared against small reference images.

Run from the repository root after a release build:

    python3 tests/scenarios.py                 # all scenarios, exit code = failures
    python3 tests/scenarios.py --only e1m1_finish
    python3 tests/scenarios.py --update        # rewrite tests/reference/*.png

Needs Pillow and, without a display, xvfb-run (Linux). The comparison scales
both images to 160x90 and takes the mean absolute difference of the RGB
channels: animation, monster movement and timers stay below the threshold,
a broken renderer, missing textures or a wrong place do not (runs differ by
less than 0.5 of 255, a wrong view or untextured walls by more than 9). Every
screenshot must also not be (nearly) black. On a failure the actual image,
the reference and their difference are written next to each other into the
output directory (`<shot>_compare.png`).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFERENCE_DIR = os.path.join(ROOT, 'tests', 'reference')
COMPARE_SIZE = (160, 90)
DEFAULT_THRESHOLD = 5.0    # mean absolute difference, 0..255; runs differ by < 0.5, a wrong view by > 9
BLACK_LIMIT = 4.0          # mean brightness of the 3D view (above the HUD) below this: black frame
PROCESS_TIMEOUT = 300
BUDGETS_PATH = os.path.join(ROOT, 'tests', 'budgets.json')
UPDATE = False             # --update: also rewrite tests/budgets.json


class Scenario:
    def __init__(self, name, runs, checks, references, threshold=DEFAULT_THRESHOLD, prepare=None,
                 frame_checks=None):
        self.name = name
        self.prepare = prepare        # function(out_dir) run before the processes, or None
        self.frame_checks = frame_checks  # function(out_dir) -> [(ok, description)] on the screenshots, or None
        self.runs = runs              # [(prefix, args, delay before start)]
        self.checks = checks          # function(logs) -> [(ok, description)]
        self.references = references  # screenshot names compared with tests/reference
        self.threshold = threshold


def game_command(exe, args):
    command = [exe] + args
    if sys.platform.startswith('linux') and not os.environ.get('DISPLAY'):
        command = ['xvfb-run', '-a', '-s', '-screen 0 800x600x24'] + command
    return command


def run_scenario(exe, out_dir, scenario):
    """Start the scenario's processes (in parallel, each after its delay) and
    return {prefix: log text}."""
    if scenario.prepare is not None:
        scenario.prepare(out_dir)
    processes = []
    start = time.time()
    for prefix, args, delay in scenario.runs:
        while time.time() - start < delay:
            time.sleep(0.1)
        log_path = os.path.join(out_dir, prefix + '.log')
        log = open(log_path, 'w')
        full_args = [a.replace('{out}', out_dir) for a in args]
        processes.append((prefix, log_path, log,
                          subprocess.Popen(game_command(exe, full_args), stdout=log, stderr=subprocess.STDOUT,
                                           cwd=ROOT)))
    logs = {}
    for prefix, log_path, log, process in processes:
        try:
            process.wait(timeout=PROCESS_TIMEOUT)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
        with open(log_path, errors='replace') as f:
            logs[prefix] = f.read()
        logs[prefix + ':exit'] = process.returncode
    logs['_out'] = out_dir
    return logs


# Log parsing ------------------------------------------------------------------

VIEW_RE = re.compile(r'View: map (\S+), eye (\S+) (\S+) (\S+), yaw (\S+), pitch (\S+), weapon (\d+), ammo (\d+), '
                     r'health (-?\d+), kills (\d+)/(\d+), intermission (\w+)')
NET_SHOT_RE = re.compile(r'Saved screenshot to .*\(signon (\d+), health (-?\d+), ammo (\d+), frags (-?\d+)')
PREDICTION_RE = re.compile(r'Prediction on: .* error \S+ \(max (\S+)\)')
SERVER_STATS_RE = re.compile(r'entities per frame: (\S+) sent, (\S+) outside the PVS, (\S+) dropped')
SAVE_RE = re.compile(r'(Saved|Loaded) game (?:to|from) "[^"]*" \((health -?\d+, armor \d+, shells \d+, kills \d+/\d+, '
                     r'monsters \d+)\)')


def views(log):
    result = []
    for m in VIEW_RE.finditer(log):
        result.append({
            'map': m.group(1), 'eye': (float(m.group(2)), float(m.group(3)), float(m.group(4))),
            'weapon': int(m.group(7)), 'ammo': int(m.group(8)), 'health': int(m.group(9)),
            'kills': int(m.group(10)), 'intermission': m.group(12) == 'yes'})
    return result


def common_checks(logs, prefix):
    log = logs.get(prefix, '')
    return [
        (logs.get(prefix + ':exit') == 0, '%s exits with 0 (got %s)' % (prefix, logs.get(prefix + ':exit'))),
        ('An unhandled exception' not in log and 'Exception "' not in log, '%s logs no exception' % prefix),
    ]


# Scenarios --------------------------------------------------------------------

MAPBROWSER_PORT = 26340


def prepare_mapbrowser(out_dir):
    # A catalog of two "Quaddicted" releases served over HTTP from this
    # process: qtest (E1M1 as qtest1 and, in BSP2, qtest2, in a qtest/
    # folder of the zip mapped to id1/maps/) and qbad (the same zip with a
    # wrong SHA-256, which must not install)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    import hashlib
    import http.server
    import threading
    import zipfile
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    site = os.path.join(out_dir, 'site')
    os.makedirs(site, exist_ok=True)
    zip_path = os.path.join(site, 'qtest.zip')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('qtest/', '')
        z.writestr('qtest/qtest1.bsp', data)
        z.writestr('qtest/qtest2.bsp', bsp2convert.convert(data, 'BSP2'))
        z.writestr('qtest/qtest_readme.txt', 'A test release for the map browser scenario\n')
    with open(zip_path, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    size = os.path.getsize(zip_path)
    url = 'http://127.0.0.1:%d/qtest.zip' % MAPBROWSER_PORT
    with open(os.path.join(out_dir, 'maps.txt'), 'w') as f:
        f.write('# test catalog\n')
        f.write('\t'.join(['qtest', digest, str(size), 'Test Release', 'Scenarios', '2026-10-19', '4.50',
                           'small', 'lit,singleplayer', 'qtest1,qtest2', 'qtest/>id1/maps/', url]) + '\n')
        f.write('\t'.join(['qbad', '0' * 64, str(size), 'Broken Download', 'Scenarios', '2026-10-18', '',
                           'small', 'singleplayer', 'qtest1', 'qtest/>id1/maps/', url]) + '\n')

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=site, **kwargs)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', MAPBROWSER_PORT), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def check_mapbrowser(logs):
    log = logs['browse']
    result = common_checks(logs, 'browse')
    result.append(('Map catalog' in log and ': 2 maps' in log, 'the test catalog is read'))
    result.append(('qtest: Test Release by Scenarios (2026) 4.5/5' in log, 'maps lists the catalog by rating'))
    result.append(('Map "qbad": SHA-256' in log and 'Map "qbad" installed' not in log,
                   'a download with the wrong SHA-256 is not installed'))
    result.append(('Map "qtest" is not installed' in log, 'an uninstalled map does not play'))
    result.append(('Map "qtest" installed' in log, 'the download is checked and installed'))
    result.append(('Loaded PK3' in log and 'quaddicted_qtest.zip' in log, 'the zip is mounted'))
    v = views(log)
    result.append((len(v) == 3 and v[0]['map'] == 'qtest1', 'its start map plays from the folder mapped to maps/'))
    result.append((len(v) == 3 and v[1]['map'] == 'qtest2' and 'Loaded map "maps/qtest2.bsp" (BSP2)' in log,
                   'its second map (BSP2) plays'))
    result.append((len(v) == 3 and v[2]['map'] == 'qtest1', 'the menu walks to the map browser and plays it'))
    result.append(('Map "qtest" removed' in log and log.rstrip().count('[installed]') == 1,
                   'removing it leaves no installed map'))
    return result


DEMO_SHOT_RE = re.compile(r'Saved screenshot to ".*?" \(signon \d+, health -?\d+, ammo \d+, frags -?\d+, '
                          r'time ([\d.]+)\)')
PHOTO_RE = re.compile(r'Photo saved to "(.*?)": (\d+)x(\d+), fov (\d+), (\w+)')


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
    v = views(log)
    result.append((len(v) == 3 and v[1]['eye'] != v[0]['eye'], 'the camera flies away from the player'))
    result.append((len(v) == 3 and v[2]['eye'] == v[0]['eye'], 'leaving puts the camera back on the player'))
    d = logs['pdemo']
    shots = [float(t) for t in DEMO_SHOT_RE.findall(d)]
    result.append((len(shots) == 3 and shots[0] == shots[1] and shots[2] > shots[1],
                   'the demo waits in photo mode and goes on after (time %s)' % ' -> '.join('%.1f' % t for t in shots)))
    demo_photos = PHOTO_RE.findall(d)
    result.append((len(demo_photos) == 1 and demo_photos[0][4] == 'vignette', 'a photo from demo playback'))
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


def check_deathmatch(logs):
    result = common_checks(logs, 'dm_host') + common_checks(logs, 'dm_client')
    result.append(('Client 2 connected' in logs['dm_host'], 'the client joined the host'))
    shots = NET_SHOT_RE.findall(logs['dm_client'])
    result.append((len(shots) == 2, 'two client screenshots (got %d)' % len(shots)))
    if len(shots) == 2:
        result.append((shots[0][0] == '4' and shots[1][0] == '4', 'signon complete'))
        result.append((int(shots[1][2]) < int(shots[0][2]),
                       'the client\'s shot reached the server (ammo %s -> %s)' % (shots[0][2], shots[1][2])))
    stats = SERVER_STATS_RE.findall(logs['dm_host'])
    result.append((bool(stats), 'the server logs its client frames'))
    if stats:
        sent, culled, dropped = (float(x) for x in stats[-1])
        result.append((dropped == 0, 'no entity dropped from a full frame (%.1f per frame)' % dropped))
        result.append((culled > 0, 'entities outside the client\'s PVS are not sent (%.1f per frame, %.1f sent)'
                       % (culled, sent)))
    errors = [float(e) for e in PREDICTION_RE.findall(logs['dm_client'])]
    result.append((bool(errors) and max(errors) < 32,
                   'prediction stays close to the server (max error %s)' % (max(errors) if errors else 'none')))
    return result


def check_quakec(logs):
    log = logs['qc']
    result = common_checks(logs, 'qc')
    m = re.search(r'(\d+) edicts in use', log)
    count = int(m.group(1)) if m else 0
    result.append((count >= 150, 'progs.dat spawned the level (%d edicts)' % count))
    return result


def check_lightmap_pages(logs):
    log = logs['pages']
    result = common_checks(logs, 'pages')
    m = re.search(r'Lightmaps of model 0: (\d+) atlas page\(s\) of \d+x\d+, \d+ rows used, (\d+) faces without room', log)
    pages = int(m.group(1)) if m else 0
    result.append((pages > 1, 'small atlas pages: the world lightmaps fill several (%d)' % pages))
    result.append((m is not None and m.group(2) == '0', 'every face found room (%s without)' % (m.group(2) if m else '?')))
    return result


def prepare_bsp2(out_dir):
    # E1M1 rewritten in the BSP2 and 2PSB formats, in a -game directory
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    bsp2convert.write_pak(os.path.join(out_dir, 'pak0.pak'),
                          [('maps/e1m1_bsp2.bsp', bsp2convert.convert(data, 'BSP2')),
                           ('maps/e1m1_2psb.bsp', bsp2convert.convert(data, '2PSB'))])


def check_bsp2(logs):
    result = []
    for prefix, kind in (('bsp2', 'BSP2'), ('psb', '2PSB')):
        log = logs[prefix]
        result += common_checks(logs, prefix)
        result.append(('(%s): 5516 faces' % kind in log, '%s map loads with the faces of e1m1' % kind))
        v = views(log)
        result.append((len(v) == 2, '%s: two screenshots (got %d)' % (prefix, len(v))))
        if len(v) == 2:
            result.append((v[1]['eye'][1] - v[0]['eye'][1] > 200,
                           '%s: walked forward on its hulls (%.0f units)' % (prefix, v[1]['eye'][1] - v[0]['eye'][1])))
    return result


def prepare_gamedir(out_dir):
    # A mod directory the way mods ship: loose files, a pak0.pak overriding
    # one of them, and a deflated .pk3 overriding another
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    import zipfile
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    mod = os.path.join(out_dir, 'mod')
    os.makedirs(os.path.join(mod, 'maps'), exist_ok=True)
    for name in ('e1m1_loose', 'e1m1_prio', 'e1m1_paktest'):
        with open(os.path.join(mod, 'maps', name + '.bsp'), 'wb') as f:
            f.write(data)
    bsp2convert.write_pak(os.path.join(mod, 'pak0.pak'), [('maps/e1m1_paktest.bsp', bsp2convert.convert(data, '2PSB'))])
    with zipfile.ZipFile(os.path.join(mod, 'maps.pk3'), 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('maps/e1m1_pk3.bsp', bsp2convert.convert(data, 'BSP2'))
        z.writestr('maps/e1m1_prio.bsp', bsp2convert.convert(data, 'BSP2'))


def check_gamedir(logs):
    result = []
    for prefix, name, kind, what in (('loose', 'e1m1_loose', 'BSP29', 'a loose map loads'),
                                     ('pk3', 'e1m1_pk3', 'BSP2', 'a deflated map in a .pk3 loads'),
                                     ('prio', 'e1m1_prio', 'BSP2', 'the .pk3 overrides a loose file'),
                                     ('paktest', 'e1m1_paktest', '2PSB', 'pak0.pak overrides a loose file')):
        result += common_checks(logs, prefix)
        result.append(('Loaded map "maps/%s.bsp" (%s)' % (name, kind) in logs[prefix], what))
    return result


def prepare_litfog(out_dir):
    # E1M1 with a .lit of its own gray light (must look unchanged), with a
    # red tinted .lit, and with a worldspawn fog key
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    maps = os.path.join(out_dir, 'mod', 'maps')
    os.makedirs(maps, exist_ok=True)
    files = {'e1m1_gray.bsp': data, 'e1m1_gray.lit': bsp2convert.make_lit(data),
             'e1m1_red.bsp': data, 'e1m1_red.lit': bsp2convert.make_lit(data, (1.6, 0.6, 0.4)),
             'e1m1_fog.bsp': bsp2convert.set_worldspawn_key(data, 'fog', '0.1 0.5 0.35 0.25')}
    for name, content in files.items():
        with open(os.path.join(maps, name), 'wb') as f:
            f.write(content)


def check_litfog(logs):
    result = []
    for prefix in ('gray', 'red', 'fog'):
        result += common_checks(logs, prefix)
    result.append(('Colored lightmaps from "maps/e1m1_gray.lit"' in logs['gray'], 'the gray .lit is read'))
    result.append(('Colored lightmaps from "maps/e1m1_red.lit"' in logs['red'], 'the red .lit is read'))
    result.append(('Fog: density 0.100, color 0.5 0.35 0.25' in logs['fog'], 'the worldspawn fog key is applied'))
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


def prepare_envmsg(out_dir):
    # A mod with E1M1 fogged (worldspawn fog), E1M1 with a worldspawn sky
    # key and the six faces of that skybox (gfx/env/test*.tga)
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    import struct
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    maps = os.path.join(out_dir, 'mod', 'maps')
    env = os.path.join(out_dir, 'mod', 'gfx', 'env')
    os.makedirs(maps, exist_ok=True)
    os.makedirs(env, exist_ok=True)
    with open(os.path.join(maps, 'e1m1_fog.bsp'), 'wb') as f:
        f.write(bsp2convert.set_worldspawn_key(data, 'fog', '0.1 0.5 0.35 0.25'))
    with open(os.path.join(maps, 'e1m1_sky.bsp'), 'wb') as f:
        f.write(bsp2convert.set_worldspawn_key(data, 'sky', 'test'))
    colors = {'rt': (200, 60, 60), 'bk': (60, 200, 60), 'lf': (60, 60, 200),
              'ft': (200, 200, 60), 'up': (60, 200, 200), 'dn': (200, 60, 200)}
    for suffix, (r, g, b) in colors.items():
        # An uncompressed 24-bit TGA, top-left origin
        header = struct.pack('<BBBHHBHHHHBB', 0, 0, 2, 0, 0, 0, 0, 0, 32, 32, 24, 0x20)
        with open(os.path.join(env, 'test' + suffix + '.tga'), 'wb') as f:
            f.write(header + bytes((b, g, r)) * (32 * 32))


def check_envmsg(logs):
    result = []
    for prefix in ('rec', 'play', 'host', 'client'):
        result += common_checks(logs, prefix)
    rec, play = logs['rec'], logs['play']
    result.append(('Recorded demo "castle-config:/envmsg.dem"' in rec, 'the demo is recorded'))
    result.append(('Skybox "test"' in rec, 'the console sky command shows the skybox'))
    result.append(('Fog: density 0.100' in play, 'playback: the map\'s fog'))
    result.append(('Fog: density 0.200, color 0.1' in play, 'playback: the fog changed by the console (svc_fog)'))
    result.append(('Skybox "test"' in play, 'playback: the skybox set by the console (svc_skybox)'))
    result.append(('Illegible server message' not in play + logs['client'], 'no message the reader cannot parse'))
    result.append(('protocol 666' in logs['host'], 'a level with a sky key is protocol 666 on the server'))
    result.append(('Skybox "test"' in logs['client'], 'the network client shows the level\'s skybox'))
    return result


DEMO_VIEW_RE = re.compile(r'View entity \d+ at (\S+) (\S+) (\S+) \(protocol (\d+)\)')


def prepare_largecoords(out_dir):
    # E1M1 moved by 8192 units along x and y: beyond the 16-bit coordinates
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    maps = os.path.join(out_dir, 'mod', 'maps')
    os.makedirs(maps, exist_ok=True)
    with open(os.path.join(maps, 'e1m1_far.bsp'), 'wb') as f:
        f.write(bsp2convert.translate(data, (8192, 8192, 0)))


def check_largecoords(logs):
    result = []
    for prefix in ('rec', 'play', 'host', 'client'):
        result += common_checks(logs, prefix)
    rec = views(logs['rec'])
    result.append((len(rec) == 2, 'two recorded screenshots (got %d)' % len(rec)))
    played = [tuple(float(v) for v in m[:3]) + (m[3],) for m in DEMO_VIEW_RE.findall(logs['play'])]
    result.append(('protocol 999' in logs['play'], 'the demo is protocol 999'))
    if len(rec) == 2 and played:
        eye = rec[1]['eye']
        x, y, z, protocol = played[-1]
        result.append((eye[1] > 8000, 'walked beyond 4096 units (eye y %.1f)' % eye[1]))
        result.append((abs(x - eye[0]) < 1 and abs(y - eye[1]) < 16 and abs(z + 22 - eye[2]) < 16,
                       'playback ends where the recording did (%.1f %.1f %.1f, recorded eye %.1f %.1f %.1f)'
                       % (x, y, z, eye[0], eye[1], eye[2])))
    result.append(('protocol 999' in logs['host'], 'the server picks protocol 999 for the far map'))
    shots = NET_SHOT_RE.findall(logs['client'])
    result.append((len(shots) == 2 and int(shots[1][2]) < int(shots[0][2]),
                   'the client\'s shot reached the server (%s)' % ' -> '.join(s[2] for s in shots)))
    client = DEMO_VIEW_RE.findall(logs['client'])
    result.append((bool(client) and all(float(c[0]) > 4096 and float(c[1]) > 4096 for c in client),
                   'the client is beyond 4096 units (%s)' % ', '.join('%s %s' % c[:2] for c in client)))
    errors = [float(e) for e in PREDICTION_RE.findall(logs['client'])]
    result.append((bool(errors) and max(errors) < 32,
                   'prediction stays close to the server (max error %s)' % (max(errors) if errors else 'none')))
    result.append(('Illegible server message' not in logs['play'] + logs['client'], 'no message the reader cannot parse'))
    return result


# Performance budgets: fixed camera spots per map (CGE coordinates of the
# player start and items spread over the level); at each the play view's Z
# logs one second of frame times with the PVS counts. The counts are
# deterministic (they depend on the camera's leaf), the frame times under
# llvmpipe are not, so only the counts are budgets and the times are logged.
BUDGET_SPOTS = {
    'e1m1': ['480;128;352', '-360;-40;-2912', '1256;-392;-1704', '128;-168;-1216', '544;-48;-2480',
             '1376;-392;-808'],
    'e1m3': ['-736;128;1592', '1600;576;-968', '24;-168;-152', '1608;-112;584', '-1736;-296;552',
             '544;-112;1424'],
    'start': ['0;464;160', '-560;88;-592', '1168;40;-1360', '-1456;56;-1744', '-336;40;-1296', '1168;40;-2448'],
    'lq_e0m2': ['-2304;284;3520', '248;-120;-3336', '960;40;568', '-2288;-24;-768', '-304;104;2336',
                '-656;-184;-1392'],
}
FRAMES_RE = re.compile(r'Frames: (\d+) in (\S+) s, (\S+) ms average, (\S+) ms longest, culling (\w+), leaf (-?\d+), '
                       r'clusters (\d+)/(\d+), shapes (\d+)/(\d+), entities (\d+)/(\d+)')


def budget_demo(spots):
    # The first Z of a spot starts counting, the second logs that spot's
    # second (the first Z of the next spot logs the move: skipped); the
    # screenshot is of the player start
    return 'W:1,Y,S,' + ''.join('G:%s,W:0.5,Z,W:1,Z,' % spot for spot in spots) + 'Q'


def budget_margin(budget, kind):
    # The growth a count may have before it fails: monsters walking in and
    # out of view move the entity count by a few
    if kind == 'entities':
        return budget * 1.2 + 3
    return budget * 1.1 + 2


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
    if UPDATE:
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


RANDOM_RE = re.compile(r'Random map (\d+): (\d+) rooms \((\d+) reachable\).*?start ([-\d]+ [-\d]+ [-\d]+), '
                       r'exit ([-\d]+ [-\d]+ [-\d]+)')


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


def check_bots(logs):
    result = common_checks(logs, 'bhost') + common_checks(logs, 'bclient')
    h = logs['bhost']
    m = re.search(r'Navigation of "e1m1": (\d+) spots, (\d+) links', h)
    result.append((m is not None and int(m.group(1)) > 1000, 'E1M1 has bot navigation (%s spots)' %
                   (m.group(1) if m else 0)))
    joined = re.findall(r'Bot "(\w+)" joined as client', h)
    result.append((len(joined) == 3, 'three bots join (%s)' % ', '.join(joined)))
    result.append((re.search(r'Client \d+ connected', h) is not None, 'a network client joins with the bots'))
    lines = re.findall(r'Bots: (.*)', h)
    last = lines[-1] if lines else ''
    moved = [float(x) for x in re.findall(r'([\d.]+) units', last)]
    result.append((len(moved) == 3 and min(moved) > 1000, 'every bot walks the map (%s units)' %
                   ', '.join('%.0f' % x for x in moved)))
    frags = sum(int(x) for line in lines for x in re.findall(r'(-?\d+) frags', line))
    result.append((frags != 0 or 'fighting' in ' '.join(lines), 'the bots fight (%d frags in the logs)' % frags))
    shots = NET_SHOT_RE.findall(logs['bclient'])
    result.append((len(shots) == 1 and shots[0][0] == '4', 'the client plays with the bots'))
    return result


SCENARIOS = [
    Scenario('e1m1_finish', [('finish', ['--autotest', 'e1m1', '{out}/finish', '--demo',
                                         'W:0.5,Y,S,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,G:1312;-230;-544,W:1.5,S,'
                                         'W:5,X,W:3,S,Q'], 0)],
             # finish_3 (the intermission) looks from a random info_intermission spot: not compared
             check_e1m1_finish, ['finish_1', 'finish_4']),
    Scenario('e1m1_saveload', [('saveload', ['--autotest', 'e1m1', '{out}/saveload', '--demo',
                                             'W:0.5,G:1312;-218;-1156,A:270,C:2,W:1.5,X,W:0.6,X,W:0.6,O:scenario,'
                                             'W:3,S,L:scenario,S,Q'], 0)],
             check_e1m1_saveload, []),
    Scenario('deathmatch', [('dm_host', ['--autotest', 'host:start', '{out}/dm_host', '--demo', 'W:16,S,Q',
                                         '-port', '26300'], 0),
                            ('dm_client', ['--autotest', 'connect:127.0.0.1:26300', '{out}/dm_client', '--demo',
                                           'W:3,S,V:1;0;0,W:1,V:0;0;0,X,W:1.5,S,Q'], 4)],
             check_deathmatch, []),
    Scenario('quakec', [('qc', ['--autotest', 'qc:e1m1', '{out}/qc', '--demo', 'W:1,E,S,Q'], 0)],
             check_quakec, ['qc_1']),
    # The same view as finish_1 with 128 x 128 lightmap atlas pages: its
    # reference is a copy of e1m1_finish_finish_1 (one 2048 x 2048 page)
    Scenario('lightmap_pages', [('pages', ['-lmatlas', '128', '--autotest', 'e1m1', '{out}/pages', '--demo',
                                           'W:0.5,Y,S,Q'], 0)],
             check_lightmap_pages, ['pages_1']),
    # E1M1 converted to BSP2 and 2PSB: the same start view as finish_1 (the
    # references are copies of e1m1_finish_finish_1) and the same walk
    Scenario('bsp2', [('bsp2', ['-game', '{out}', '--autotest', 'e1m1_bsp2', '{out}/bsp2', '--demo',
                                'W:0.5,Y,S,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,Q'], 0),
                      ('psb', ['-game', '{out}', '--autotest', 'e1m1_2psb', '{out}/psb', '--demo',
                               'W:0.5,Y,S,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,Q'], 0)],
             check_bsp2, ['bsp2_1', 'psb_1'], prepare=prepare_bsp2),
    # Loose files, pak0.pak and a .pk3 in a -game directory, and which one
    # wins; the views are the finish_1 start view (copied references)
    Scenario('gamedir', [('loose', ['-game', '{out}/mod', '--autotest', 'e1m1_loose', '{out}/loose', '--demo',
                                    'W:0.5,Y,S,Q'], 0),
                         ('pk3', ['-game', '{out}/mod', '--autotest', 'e1m1_pk3', '{out}/pk3', '--demo',
                                  'W:0.5,Y,S,Q'], 0),
                         ('prio', ['-game', '{out}/mod', '--autotest', 'e1m1_prio', '{out}/prio', '--demo',
                                   'W:0.5,Q'], 0),
                         ('paktest', ['-game', '{out}/mod', '--autotest', 'e1m1_paktest', '{out}/paktest', '--demo',
                                      'W:0.5,Q'], 0)],
             check_gamedir, ['loose_1', 'pk3_1'], prepare=prepare_gamedir),
    # Colored light and fog: gray_1 is the finish_1 view (copied reference),
    # red_1 and fog_1 have their own references
    Scenario('litfog', [('gray', ['-game', '{out}/mod', '--autotest', 'e1m1_gray', '{out}/gray', '--demo',
                                  'W:0.5,Y,S,Q'], 0),
                        ('red', ['-game', '{out}/mod', '--autotest', 'e1m1_red', '{out}/red', '--demo',
                                 'W:0.5,Y,S,Q'], 0),
                        ('fog', ['-game', '{out}/mod', '--autotest', 'e1m1_fog', '{out}/fog', '--demo',
                                 'W:0.5,Y,S,Q'], 0)],
             check_litfog, ['gray_1', 'red_1', 'fog_1'], prepare=prepare_litfog),
    # The liquids and the item boxes: the LibreQuake hub's *blood1 wall from
    # a still camera twice (it must ripple), and E1M1's health boxes after
    # walking into one (boxes_1 has a reference: two boxes left, one rotten)
    Scenario('liquid_items', [('hub', ['--autotest', 'start', '{out}/hub', '--demo',
                                       'W:3,G:300;-200;-1700,A:180,P:-40,W:1,S,W:0.5,S,Q'], 0),
                              ('boxes', ['--autotest', 'e1m1', '{out}/boxes', '--demo',
                                         'W:0.5,G:1392;-386;-824,W:0.5,G:1300;-386;-690,A:75,P:-20,W:0.5,S,Q'], 0)],
             check_liquid_items, ['boxes_1'], frame_checks=frames_liquid_items),
    # The Quake episode hub plays id1's models and sounds (Pak.PreferOriginal),
    # not LibreQuake's: the crucified zombies of the hard hall hang on its walls
    Scenario('quake_hub', [('hub', ['--game', 'quake', '--autotest', 'start', '{out}/hub', '--demo',
                                    'W:1,Y,G:856;-18;-700,A:90,W:0.5,P:15,W:0.3,S,Q'], 0)],
             check_quake_hub, ['hub_1']),
    # FitzQuake's svc_fog and svc_skybox: a demo recorded on a fogged map
    # whose fog and sky the console changes, played back by a second
    # process; a host on a map with a sky key and a client joining it
    Scenario('envmsg', [('rec', ['-game', '{out}/mod', '--autotest', 'e1m1_fog', '{out}/rec', '--demo',
                                 'W:0.5,Y,R:envmsg,W:1,CMD:fog 0.2 0.1 0.2 0.6,W:1,CMD:sky test,W:1,S,R,Q'], 0),
                        ('play', ['-game', '{out}/mod', '--autotest', 'castle-config:/envmsg.dem', '{out}/play',
                                  '--demo', 'W:6,S,Q'], 15),
                        ('host', ['-game', '{out}/mod', '--autotest', 'host:e1m1_sky', '{out}/host', '--demo',
                                  'W:10,S,Q', '-port', '26302', '-coop'], 0),
                        ('client', ['-game', '{out}/mod', '--autotest', 'connect:127.0.0.1:26302', '{out}/client',
                                    '--demo', 'W:4,S,Q'], 4)],
             check_envmsg, [], prepare=prepare_envmsg),
    # Protocol 999: E1M1 moved beyond the 16-bit coordinates (rec_1 is the
    # finish_1 view, copied reference); a demo recorded there plays back at
    # the same positions, and a host and a client play on it
    Scenario('largecoords', [('rec', ['-game', '{out}/mod', '--autotest', 'e1m1_far', '{out}/rec', '--demo',
                                      'W:0.5,Y,S,R:far,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,R,Q'], 0),
                             ('play', ['-game', '{out}/mod', '--autotest', 'castle-config:/far.dem', '{out}/play',
                                       '--demo', 'W:5,S,Q'], 15),
                             ('host', ['-game', '{out}/mod', '--autotest', 'host:e1m1_far', '{out}/host', '--demo',
                                       'W:20,S,Q', '-port', '26303', '-coop'], 0),
                             ('client', ['-game', '{out}/mod', '--autotest', 'connect:127.0.0.1:26303', '{out}/client',
                                         '--demo', 'W:6,S,V:1;0;0,W:1,V:0;0;0,X,W:1.5,S,Q'], 4)],
             check_largecoords, ['rec_1'], prepare=prepare_largecoords),
    # Touch controls: the move stick, a look drag and the fire button on
    # E1M1 (touch_1 has a reference: the overlay over the start view), then
    # the menu button opens the menu
    Scenario('touch', [('touch', ['--autotest', 'e1m1', '{out}/touch', '--demo',
                                  'W:0.5,Y,TD:1;0.15;0.2,TM:1;0.15;0.35,S,W:1.5,TU:1,W:0.3,S,'
                                  'TD:2;0.7;0.5,TM:2;0.8;0.5,TU:2,W:0.2,S,TD:3;0.9125;0.1556,W:0.4,TU:3,W:0.5,S,'
                                  'TD:4;0.97;0.95,W:0.3,TU:4,W:0.3,Q'], 0),
                       ('phone', ['--geometry', '1170x2532', '-density', '3', '-touch', '--autotest', 'e1m1',
                                  '{out}/phone', '--demo', 'W:0.5,Y,S,TD:1;0.2;0.12,TM:1;0.2;0.2,W:1.5,TU:1,W:0.2,S,Q'],
                        0)],
             check_touch, ['touch_1', 'phone_1']),
    # A random map: the start view (reference), a walk, the exit pad of
    # seed 42 (G: its coordinates), the tallies and random43; QuakeC spawns
    # it; a client builds the host's random7 from the name alone
    Scenario('randommap', [('rnd', ['--autotest', 'random42', '{out}/rnd', '--demo',
                                    'W:0.5,Y,S,V:1;0;0,W:1,V:0;0;0,S,G:-320;80;-768,W:1.5,S,W:5,X,W:3,S,Q'], 0),
                           ('rqc', ['--autotest', 'qc:random42', '{out}/rqc', '--demo', 'W:1,E,S,Q'], 0),
                           ('rhost', ['--autotest', 'host:random7', '{out}/rhost', '--demo', 'W:16,S,Q',
                                      '-port', '26310'], 0),
                           ('rclient', ['--autotest', 'connect:127.0.0.1:26310', '{out}/rclient', '--demo',
                                        'W:6,S,Q'], 4)],
             check_randommap, ['rnd_1']),
    # Accessibility: captions and the high contrast HUD on E1M1's health box
    # (pickup_1 has a reference: the caption panel and the black and yellow
    # status bar), monsters waking in random42's exit room captioned with a
    # direction, and no captions by default
    Scenario('access', [('pickup', ['--autotest', 'e1m1', '{out}/pickup', '--demo',
                                    'W:0.5,CMD:captions 1,CMD:hud_contrast 1,G:1392;-386;-824,W:0.5,'
                                    'G:1300;-386;-690,A:75,P:-20,W:0.3,S,Q'], 0),
                        ('monsters', ['--autotest', 'random42', '{out}/monsters', '--demo',
                                      'W:0.5,CMD:captions 1,Y,G:-450;80;-768,A:180,X,W:2,S,Q'], 0),
                        ('off', ['--autotest', 'random42', '{out}/off', '--demo',
                                 'W:0.5,Y,G:-450;80;-768,A:180,X,W:2,Q'], 0)],
             check_access, ['pickup_1']),
    # Horde mode: E1M1's monsters give way to waves (killall clears wave 1,
    # wave 2 follows after the pause) and a random map plays it too
    Scenario('horde', [('waves', ['-horde', '--autotest', 'e1m1', '{out}/waves', '--demo',
                                  'W:0.5,Y,W:5,S,CMD:killall,W:8,S,Q'], 0),
                       ('rndhorde', ['-horde', '--autotest', 'random42', '{out}/rndhorde', '--demo',
                                     'W:0.5,Y,W:5,S,Q'], 0)],
             check_horde, []),
    # Speedrun timer and ghost: a first run on E1M1 (6 s forward, the exit)
    # becomes the ghost, a second one at half speed races it: behind at the
    # checkpoint and at the end, and not kept. The second starts after the
    # first wrote castle-config:/ghost_e1m1.ghost
    Scenario('speedrun', [('run1', ['-speedrun', '-ghost', '--autotest', 'e1m1', '{out}/run1', '--demo',
                                    'W:0.3,CMD:ghost_reset,Y,V:1;0;0,W:6,V:0;0;0,G:1312;-230;-544,W:1.5,S,Q'], 0),
                          ('run2', ['-speedrun', '-ghost', '--autotest', 'e1m1', '{out}/run2', '--demo',
                                    'W:0.3,Y,V:0.5;0;0,W:3,S,W:9,V:0;0;0,G:1312;-230;-544,W:1.5,S,Q'], 20)],
             check_speedrun, []),
    # Bots: a deathmatch host on E1M1 with three bots (navigation built from
    # the map, items, fights, frags) and a network client joining them
    Scenario('bots', [('bhost', ['-bots', '3', '--autotest', 'host:e1m1', '{out}/bhost', '--demo', 'W:60,S,Q',
                                 '-port', '26320'], 0),
                      ('bclient', ['--autotest', 'connect:127.0.0.1:26320', '{out}/bclient', '--demo',
                                   'W:6,S,Q'], 5)],
             check_bots, []),
    # Map browser: a test catalog served over HTTP, a download with a wrong
    # SHA-256 refused, the good one installed, mounted with its folder
    # mapped to maps/, both start maps played (the console, then the menu
    # with the virtual gamepad) and the release removed
    Scenario('mapbrowser', [('browse', ['-mapcatalog', '{out}/maps.txt', '--autotest', 'e1m1', '{out}/browse',
                                        '--demo',
                                        'W:0.5,CMD:maps_remove qtest,CMD:maps,CMD:maps_install qbad,W:2,'
                                        'CMD:maps_play qtest,CMD:maps_install qtest,W:3,CMD:maps installed,'
                                        'CMD:maps_play qtest,W:1.5,S,CMD:maps_play qtest qtest2,W:1.5,S,'
                                        'TD:4;0.97;0.95,W:0.3,TU:4,W:0.3,GB:down,W:0.3,GB:down,W:0.3,GB:down,'
                                        'W:0.3,GB:south,W:0.5,GB:down,W:0.3,GB:south,W:0.5,GB:down,W:0.3,GB:down,'
                                        'W:0.3,GB:down,W:0.3,GB:down,W:0.3,GB:south,W:1.5,S,'
                                        'CMD:maps_remove qtest,CMD:maps installed,Q'], 0)],
             check_mapbrowser, [], prepare=prepare_mapbrowser),
    # Photo mode: E1M1 paused while the camera flies off, a depth of field
    # photo at twice the window size and a grayscale one at fov 60, the
    # camera back on the player after; a demo waits in photo mode
    Scenario('photo', [('play', ['--autotest', 'e1m1', '{out}/play', '--demo',
                                 'W:0.5,Y,S,CMD:photo 1,M:-60,T:25,P:-10,W:2,S,CMD:photo_effect dof,'
                                 'CMD:photo_shot,CMD:photo_effect gray,CMD:photo_fov 60,CMD:photo_scale 1,'
                                 'W:0.2,CMD:photo_shot,CMD:photo 0,W:0.3,S,Q'], 0),
                       ('pdemo', ['--autotest', 'demo1.dem', '{out}/pdemo', '--demo',
                                  'W:3,S,CMD:photo 1,M:-40,CMD:photo_effect vignette,W:1,CMD:photo_shot,S,'
                                  'CMD:photo 0,W:1,S,Q'], 0)],
             check_photo, [], frame_checks=frames_photo),
    # Performance budgets: the PVS counts at fixed spots on four maps against
    # tests/budgets.json (--update rewrites it), frame times in budgets.json
    # of the output directory; one map after the other, so the frame times
    # are not shared with another process
    Scenario('budgets', [(name, ['--autotest', name, '{out}/' + name, '--demo', budget_demo(spots)], 20 * i)
                         for i, (name, spots) in enumerate(BUDGET_SPOTS.items())],
             check_budgets, []),
]


# Images -----------------------------------------------------------------------

def small(path):
    return Image.open(path).convert('RGB').resize(COMPARE_SIZE, Image.BILINEAR)


def mean_difference(a, b):
    diff = ImageChops.difference(a, b)
    histogram = diff.histogram()
    total = 0
    for channel in range(3):
        values = histogram[channel * 256:(channel + 1) * 256]
        total += sum(i * n for i, n in enumerate(values))
    return total / (COMPARE_SIZE[0] * COMPARE_SIZE[1] * 3), diff


def brightness(image):
    """Mean brightness of the 3D view: the top 3/4, without the status bar"""
    width, height = image.size
    view = image.convert('L').crop((0, 0, width, height * 3 // 4))
    histogram = view.histogram()
    return sum(i * n for i, n in enumerate(histogram)) / (view.size[0] * view.size[1])


def image_checks(out_dir, scenario, update):
    result = []
    shots = sorted(f[:-4] for f in os.listdir(out_dir)
                   if f.endswith('.png') and not f.endswith('_compare.png')
                   and any(f.startswith(prefix + '_') for prefix, _, _ in scenario.runs))
    for shot in shots:
        image = small(os.path.join(out_dir, shot + '.png'))
        level = brightness(image)
        result.append((level > BLACK_LIMIT, '%s is not black (brightness %.1f)' % (shot, level)))
    for shot in scenario.references:
        actual_path = os.path.join(out_dir, shot + '.png')
        reference_path = os.path.join(REFERENCE_DIR, scenario.name + '_' + shot + '.png')
        if not os.path.exists(actual_path):
            result.append((False, '%s was taken' % shot))
            continue
        image = small(actual_path)
        if update:
            os.makedirs(REFERENCE_DIR, exist_ok=True)
            image.save(reference_path)
            result.append((True, '%s written as the reference' % shot))
            continue
        if not os.path.exists(reference_path):
            result.append((False, '%s has a reference (%s)' % (shot, os.path.relpath(reference_path, ROOT))))
            continue
        reference = Image.open(reference_path).convert('RGB').resize(COMPARE_SIZE)
        difference, diff = mean_difference(image, reference)
        ok = difference <= scenario.threshold
        result.append((ok, '%s matches the reference (difference %.1f, limit %.1f)' %
                       (shot, difference, scenario.threshold)))
        if not ok:
            compare = Image.new('RGB', (COMPARE_SIZE[0] * 3, COMPARE_SIZE[1]))
            compare.paste(image, (0, 0))
            compare.paste(reference, (COMPARE_SIZE[0], 0))
            compare.paste(diff.point(lambda v: min(255, v * 4)), (COMPARE_SIZE[0] * 2, 0))
            compare.save(os.path.join(out_dir, shot + '_compare.png'))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exe', default=os.path.join(ROOT, 'castle-quake1' + ('.exe' if os.name == 'nt' else '')))
    parser.add_argument('--out', default=os.path.join(ROOT, 'castle-engine-output', 'scenarios'))
    parser.add_argument('--only', action='append', help='run only this scenario (repeatable)')
    parser.add_argument('--update', action='store_true', help='write the screenshots as the new references')
    args = parser.parse_args()
    global UPDATE
    UPDATE = args.update

    if not os.path.exists(args.exe):
        print('No game executable at %s: build it first (castle-engine compile --mode=release)' % args.exe)
        return 2
    failures = 0
    for scenario in SCENARIOS:
        if args.only and scenario.name not in args.only:
            continue
        out_dir = os.path.join(args.out, scenario.name)
        shutil.rmtree(out_dir, ignore_errors=True)
        os.makedirs(out_dir)
        print('=== %s' % scenario.name, flush=True)
        started = time.time()
        logs = run_scenario(args.exe, out_dir, scenario)
        results = scenario.checks(logs) + image_checks(out_dir, scenario, args.update)
        if scenario.frame_checks is not None:
            results += scenario.frame_checks(out_dir)
        for ok, description in results:
            print('  %s %s' % ('ok  ' if ok else 'FAIL', description))
            if not ok:
                failures += 1
        print('  (%.0f s)' % (time.time() - started), flush=True)
    print('%d failure(s)' % failures)
    return min(failures, 100)


if __name__ == '__main__':
    sys.exit(main())
