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


def check_quake_hub(logs):
    log = logs['hub']
    result = common_checks(logs, 'hub')
    result.append(('Loaded map "maps/start.bsp"' in log and '5556 faces' in log, 'the id1 hub (shareware start.bsp)'))
    result.append(('Loaded model "zombie_original"' in log, 'the crucified zombies are id1\'s model, not LibreQuake\'s'))
    result.append(('"maps/start.lit" is not from the original paks of the map, ignored' in log,
                   'LibreQuake\'s start.lit is not applied to the id1 map'))
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
                                  'W:10,S,Q', '-port', '26302'], 0),
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
                                       'W:14,S,Q', '-port', '26303', '-coop'], 0),
                             ('client', ['-game', '{out}/mod', '--autotest', 'connect:127.0.0.1:26303', '{out}/client',
                                         '--demo', 'W:3,S,V:1;0;0,W:1,V:0;0;0,X,W:1.5,S,Q'], 4)],
             check_largecoords, ['rec_1'], prepare=prepare_largecoords),
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
