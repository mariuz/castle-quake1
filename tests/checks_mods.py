"""Checks of the QuakeC mode, demo and mod scenarios: map formats, game directories, effects, the map browser."""

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
    # A mod (qmod: its pak0.pak in the zip root, mapped to qmod/) and a map
    # for it (qmodmap, a folder mapped to qmod/maps/ that needs qmod)
    pak_path = os.path.join(out_dir, 'qmod_pak0.pak')
    bsp2convert.write_pak(pak_path, [('maps/qmod1.bsp', data)])
    mod_zip = os.path.join(site, 'qmod.zip')
    with zipfile.ZipFile(mod_zip, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(pak_path, 'pak0.pak')
        # A second pak stored (not deflated): read in place from the zip
        pak1_path = os.path.join(out_dir, 'qmod_pak1.pak')
        bsp2convert.write_pak(pak1_path, [('maps/qmod2.bsp', data)])
        z.write(pak1_path, 'pak1.pak', compress_type=zipfile.ZIP_STORED)
        z.writestr('qmod_readme.txt', 'A test mod for the map browser scenario\n')
    map_zip = os.path.join(site, 'qmodmap.zip')
    with zipfile.ZipFile(map_zip, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('qmodmap/qmodmap.bsp', data)
    releases = {}
    for name in ('qmod', 'qmodmap'):
        with open(os.path.join(site, name + '.zip'), 'rb') as f:
            releases[name] = (hashlib.sha256(f.read()).hexdigest(), str(f.tell()),
                              'http://127.0.0.1:%d/%s.zip' % (MAPBROWSER_PORT, name))
    with open(os.path.join(out_dir, 'maps.txt'), 'w') as f:
        f.write('# test catalog\n')
        f.write('\t'.join(['qtest', digest, str(size), 'Test Release', 'Scenarios', '2026-10-19', '4.50',
                           'small', 'lit,singleplayer', 'qtest1,qtest2', 'qtest/>id1/maps/', url]) + '\n')
        f.write('\t'.join(['qbad', '0' * 64, str(size), 'Broken Download', 'Scenarios', '2026-10-18', '',
                           'small', 'singleplayer', 'qtest1', 'qtest/>id1/maps/', url]) + '\n')
        f.write('\t'.join(['qmod', releases['qmod'][0], releases['qmod'][1], 'Test Mod', 'Scenarios',
                           '2026-10-17', '', 'small', 'mod,singleplayer', 'qmod1', '>qmod/', releases['qmod'][2],
                           'qmod', '', 'pak0.pak,pak1.pak']) + '\n')
        f.write('\t'.join(['qmodmap', releases['qmodmap'][0], releases['qmodmap'][1], 'Test Mod Map', 'Scenarios',
                           '2026-10-16', '', 'small', 'mod,singleplayer', 'qmodmap', 'qmodmap/>qmod/maps/',
                           releases['qmodmap'][2], 'qmod', 'qmod', '']) + '\n')

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
    result.append(('Map catalog' in log and ': 4 maps' in log, 'the test catalog is read'))
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
    mod = logs['mod']
    result += common_checks(logs, 'mod')
    result.append(('Downloading "qmod"' in mod and 'Map "qmod" installed' in mod and 'Map "qmodmap" installed' in mod
                   and mod.index('Downloading "qmod"') < mod.index('Downloading "qmodmap"'),
                   'installing a map downloads the mod it needs first'))
    result.append(('Loaded PAK "qmod:pak0.pak"' in mod, 'the mod\'s pak inside its zip is mounted'))
    result.append(('Mounted "qmod" (Test Mod) in qmod' in mod and 'Mounted "qmodmap" (Test Mod Map) in qmod' in mod,
                   'the mod and the map are mounted in the mod\'s directory'))
    result.append(('Playing "qmodmap" in QuakeC mode (qmod)' in mod and 'Loaded map "maps/qmodmap.bsp"' in mod,
                   'the mod\'s map plays in QuakeC mode'))
    result.append(('Saved screenshot' in mod and 'edicts' in mod.split('Playing "qmodmap"')[-1],
                   'the QuakeC view goes on with the script'))
    result.append((re.search(r'Loaded PK3 "[^"]*quaddicted_qmod\.zip": \d+ files \(total indexed: \d+\), read from disk',
                             mod) is not None, 'the mod\'s zip is read from disk'))
    result.append(('Unpacked "pak0.pak"' in mod and re.search(r'Loaded PAK "qmod:pak0\.pak": 1 files .*read from disk',
                                                              mod) is not None,
                   'the mod\'s deflated pak is unpacked to a file and read from there'))
    result.append((re.search(r'Loaded PAK "qmod:pak1\.pak": 1 files .*read from disk', mod) is not None,
                   'the mod\'s stored pak is read in place from its zip'))
    # Before it plays: mounting another release unmounts the ones it does not need
    result.append((mod.count('Unpacked "pak0.pak"') == 1 and mod.count('Loaded PAK "qmod:pak0.pak"') == 2,
                   'the unpacked pak is used again when the mod mounts again'))
    result.append(('Mounted now: qmod, qmodmap (game directory qmod)' in mod, 'the map mounts with its mod'))
    i = mod.find('Mounted now: qmod (game directory qmod)')
    result.append((i > 0 and 'Unmounted "qmodmap"' in mod[:i] and 'Unmounted "qmod"' not in mod[:i],
                   'mounting the mod alone unmounts its map, not the mod'))
    v = views(mod)
    j = mod.find('Map "qtest" removed')
    result.append((0 < mod.find('Unmounted "qmod"') < j and len(v) >= 1 and v[0]['map'] == 'qtest1',
                   'playing a map of id1 unmounts the mod'))
    m = re.search(r'Unmounted "qmod": (\d+) archives', mod)
    result.append((m is not None and m.group(1) == '3', 'the mod\'s zip and its two paks go (%s)' %
                   (m.group(1) if m else '-')))
    return result


def check_demoplay(logs):
    log = logs['play']
    result = common_checks(logs, 'play')
    m = re.search(r'Demo "demo1\.dem": ([\d.]+) s', log)
    length = float(m.group(1)) if m else 0
    result.append((length > 40, 'the demo\'s length is measured (%.1f s)' % length))
    seeks = SEEK_RE.findall(log)
    shots = [float(t) for t in DEMO_SHOT_RE.findall(log)]
    result.append((len(seeks) == 4 and [k[2] for k in seeks] == ['forward', 'from the start', 'forward',
                                                                  'from the start'],
                   'seeks forward and back (%s)' % ', '.join('%s -> %s %s' % (k[0], k[1], k[2]) for k in seeks)))
    if len(seeks) == 4:
        a, b = seeks[0], seeks[2]
        result.append((abs(float(a[3]) - 30) < 0.06 and abs(float(b[3]) - 30) < 0.06 and a[5:] == b[5:],
                       'seeking to 30 s forward and again after going back lands on the same spot (%s / %s)'
                       % (' '.join(a[5:]), ' '.join(b[5:]))))
        result.append((abs(float(seeks[1][3]) - 10) < 0.06 and abs(float(seeks[1][4]) - float(a[4]) + 20) < 0.2,
                       'going back to 10 s plays the demo again from the start (time %s -> %s)' % (a[4], seeks[1][4])))
    m = re.search(r'Demo paused at [\d.]+ of [\d.]+ \(time ([\d.]+)\)', log)
    result.append((m is not None and len(shots) == 7 and abs(shots[4] - float(m.group(1))) < 0.1,
                   'a paused demo stands still (time %s, screenshot %s)'
                   % (m.group(1) if m else '-', shots[4] if len(shots) > 4 else '-')))
    # 3 s at twice the speed; the screenshot comes before its frame's step
    # (up to half a second), so 5 to 6 s of the demo, 3 at the normal speed
    result.append((len(shots) == 7 and 4.4 < shots[5] - shots[4] < 6.6,
                   'twice the speed plays two seconds in one (%.2f in 3 s)'
                   % (shots[5] - shots[4] if len(shots) == 7 else 0)))
    result.append((len(shots) == 7 and len(seeks) == 4 and abs(shots[1] - float(seeks[0][4])) < 0.3,
                   'the screenshot after a seek shows it (time %s)' % (shots[1] if len(shots) > 1 else '-')))
    return result


def check_quakec(logs):
    log = logs['qc']
    result = common_checks(logs, 'qc')
    m = re.search(r'(\d+) edicts in use', log)
    count = int(m.group(1)) if m else 0
    result.append((count >= 150, 'progs.dat spawned the level (%d edicts)' % count))
    result += common_checks(logs, 'qcglide')
    gliding = [int(x) for x in re.findall(r'Entities drawn: .* (\d+) gliding', logs['qcglide'])]
    result.append((len(gliding) == 4 and max(gliding[:3]) > 0,
                   'walking monsters glide between their steps (%s)' % gliding))
    # the profile of the fight and the timing of the level load
    total = re.search(r'Profile: (\d+) QuakeC statements in ([\d.]+) s', logs['qcglide'])
    funcs = re.findall(r'Profile: (\d+) (\w+)$', logs['qcglide'], re.M)
    result.append((total is not None and int(total.group(1)) > 10000 and len(funcs) == 10 and
                   [int(c) for c, _ in funcs] == sorted((int(c) for c, _ in funcs), reverse=True),
                   'profile lists the ten QuakeC functions with the most statements (%s of %s first)'
                   % (funcs[0][1] if funcs else '-', total.group(1) if total else '-')))
    load = re.search(r'Level load "e1m1": ([\d.]+) s \(effects [\d.]+, bsp and QuakeC spawn [\d.]+, '
                     r'geometry [\d.]+, lights and sound [\d.]+\)', logs['qcglide'])
    result.append((load is not None and 'Level load "geometry of e1m1"' in logs['qcglide'],
                   'the level load logs its stages (%s s)' % (load.group(1) if load else '-')))
    result += common_checks(logs, 'qcrec') + common_checks(logs, 'qcplay')
    played = [int(x) for x in re.findall(r'Entities gliding between steps: (\d+)', logs['qcplay'])]
    result.append((len(played) == 4 and max(played) > 0,
                   'and in the recorded demo of the fight (%s)' % played))
    shared = re.search(r'Appearances: (\d+) of the (\d+) world shapes share', logs['qcglide'])
    result.append((shared is not None and int(shared.group(1)) > int(shared.group(2)) // 2,
                   'the world\'s shapes share their appearances (%s)'
                   % ('%s of %s' % shared.groups() if shared else 'no line')))
    anim = re.search(r'Animated textures: (\d+) world shapes in their own scene, (\d+) frames kept loaded',
                     logs['qcglide'])
    result.append((anim is not None and int(anim.group(1)) >= 1 and int(anim.group(2)) >= 2,
                   'the animated textures have their own scene (%s)'
                   % ('%s shapes, %s frames' % anim.groups() if anim else 'no line')))
    small = re.findall(r'Lightmaps of model [1-9]\d*: \d+ atlas page\(s\) of (\d+)x', logs['qcglide'])
    result.append((all(int(x) <= 128 for x in small), 'brush entities get small lightmap pages (%d logged)' % len(small)))
    # the console's commands of the QuakeC view (CMD: runs what the console runs)
    g = logs['qcglide']
    result.append(('God mode off' in g and 'r_lerpmove <0|1>' in g and 'map <name>, god, give' in g,
                   'the QuakeC view\'s console: help lists its commands and the settings, god'))
    result.append(('No maps/nosuchmap.bsp' in g and 'Map "e1m2" loaded in QuakeC mode' in g and
                   'Level load "e1m2"' in g, 'its map command loads another level and refuses an unknown one'))
    m = re.findall(r'Entity traces: (\d+), ([\d.]+) entities tested each of (\d+) edicts', logs['qcglide'])
    result.append((bool(m) and int(m[-1][0]) > 100 and float(m[-1][1]) < int(m[-1][2]) / 4,
                   'the area grid keeps the entity traces short (%s)'
                   % ('%s traces, %s of %s edicts each' % m[-1] if m else 'no line')))
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
                           ('maps/e1m1_2psb.bsp', bsp2convert.convert(data, '2PSB')),
                           # every edge names a vertex above 65535, like the
                           # largest BSP2 maps (Arcane Dimensions' Sepulcher)
                           ('maps/e1m1_bigv.bsp', bsp2convert.convert(data, 'BSP2', vertex_offset=65536))])


def check_bsp2(logs):
    result = []
    for prefix, kind in (('bsp2', 'BSP2'), ('psb', '2PSB'), ('bigv', 'BSP2')):
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


def prepare_exttex(out_dir):
    # A texture pack the way QuakeSpasm-Spiked reads one: loose
    # textures/e1m1/<name>.tga in a game directory, here a red and white
    # check for each of E1M1's wall textures (not the sky or the liquids),
    # with a _luma for one of them
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bsp2convert
    data = bsp2convert.read_pak_file(bsp2convert.DEFAULT_PAKS, 'maps/e1m1.bsp')
    tex = os.path.join(out_dir, 'texmod', 'textures', 'e1m1')
    os.makedirs(tex, exist_ok=True)
    check = Image.new('RGB', (256, 256), (230, 30, 30))
    for y in range(0, 256, 32):
        for x in range(0, 256, 32):
            if (x // 32 + y // 32) % 2:
                check.paste((240, 240, 240), (x, y, x + 32, y + 32))
    names = [n for n in bsp_texture_names(data) if not n.lower().startswith(('sky', '*'))]
    for name in names:
        check.save(os.path.join(tex, name.lower() + '.tga'))
    Image.new('RGB', (256, 256), (0, 0, 80)).save(os.path.join(tex, names[0].lower() + '_luma.tga'))


def prepare_fxmod(out_dir):
    # A mod with an effectinfo.txt of its own (and no particle font): the
    # shotgun's TE_GUNSHOT and TE_TELEPORT drawn from it in QuakeC mode
    d = os.path.join(out_dir, 'fxmod')
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, 'effectinfo.txt'), 'w') as f:
        f.write('// test effects\n'
                'effect TE_GUNSHOT\ncount 12\ntype spark\ncolor 0xffe060 0xff8020\nsize 1 2\n'
                'alpha 200 256 128\nvelocityjitter 64 64 64\ngravity 1\nbounce 1.5\nstretchfactor 2\n'
                'lightradius 120\nlightradiusfade 400\nlightcolor 1 0.7 0.3\n\n'
                'effect TE_TELEPORT\ncountabsolute 80\ntype alphastatic\ncolor 0x4080ff 0xffffff\n'
                'size 2 4\nalpha 256 256 128\noriginjitter 16 16 28\nvelocityjitter 8 8 8\n')


def check_fxmod(logs):
    result = common_checks(logs, 'fx') + common_checks(logs, 'fxoff')
    on, off = logs['fx'], logs['fxoff']
    result.append(('effectinfo.txt: 2 effects (2 particle sections), default particle dot' in on,
                   'the mod\'s effectinfo.txt is read'))
    calls = [int(x) for x in re.findall(r'Effect particles: \d+ drawn, \d+ made by (\d+) effect calls', on)]
    result.append((len(calls) == 2 and calls[0] >= 1, 'the shotgun\'s TE_GUNSHOT comes from it (%s calls)' % calls))
    extra = re.findall(r'effect calls, (\d+) lights, (\d+) hits of the world', on)
    result.append((len(extra) == 2 and int(extra[-1][0]) >= 1 and int(extra[-1][1]) >= 1,
                   'its sparks bounce off the walls and the impact makes a light (%s)'
                   % ('%s lights, %s hits' % extra[-1] if extra else 'no line')))
    m = re.search(r'Effect "TE_TELEPORT" \(2\): (\d+) particles', on)
    result.append((m is not None and int(m.group(1)) == 80, 'TE_TELEPORT makes its 80 particles (%s)'
                   % (m.group(1) if m else 'none')))
    result.append(('r_effectinfo 0' in off and 'Effect particles:' not in off,
                   'r_effectinfo 0 leaves the shots to the engine\'s particles'))
    result += common_checks(logs, 'fxnet')
    net = [int(x) for x in re.findall(r'Effect particles: \d+ drawn, \d+ made by (\d+) effect calls', logs['fxnet'])]
    result.append((len(net) == 1 and net[0] >= 1,
                   'a network game draws the shotgun\'s impacts from it too (%s calls)' % net))
    sent = re.search(r'Effect "TE_TELEPORT" \(2\) sent, (\d+) effect messages', logs['fxnet'])
    got = [int(x) for x in re.findall(r'Effect messages: (\d+)', logs['fxnet'])]
    result.append((sent is not None and len(got) == 1 and got[0] >= 1,
                   'the server sends an effect to its clients, which draw it (%s messages)' % got))
    result += common_checks(logs, 'fxrec') + common_checks(logs, 'fxplay')
    played = [int(x) for x in re.findall(r'Effect messages: (\d+)', logs['fxplay'])]
    result.append((len(played) == 1 and played[0] == 1,
                   'an effect recorded in QuakeC mode plays in the demo (%s messages)' % played))
    return result


def check_exttex(logs):
    result = common_checks(logs, 'tex')
    m = re.search(r'External textures of "e1m1": (\d+) of (\d+)', logs['tex'])
    result.append((m is not None and int(m.group(1)) >= 60, 'the pack replaces E1M1\'s textures (%s of %s)'
                   % (m.group(1), m.group(2)) if m else 'the pack replaces E1M1\'s textures'))
    return result


def frames_exttex(out_dir):
    """The walls are red and white checks: a red dominated view"""
    path = os.path.join(out_dir, 'tex_1.png')
    if not os.path.exists(path):
        return [(False, 'tex_1.png exists')]
    img = Image.open(path).convert('RGB').resize((160, 90))
    red = sum(1 for r, g, b in img.getdata() if r > 2 * g + 10 and r > 2 * b + 10)
    return [(red > 160 * 90 * 0.1, 'the red checks show on the walls (%d of %d pixels red)' % (red, 160 * 90))]


def check_video(logs):
    log = logs['vid']
    result = common_checks(logs, 'vid')
    result.append(('Video: texture filter nearest, anisotropy 1, anti-aliasing 1 samples' in log and
                   'Video: texture filter linear, anisotropy 1, anti-aliasing 1 samples' in log,
                   'the console sets the texture filter and the anisotropy'))
    result += common_checks(logs, 'wplay') + common_checks(logs, 'wqc')
    result += common_checks(logs, 'mlight') + common_checks(logs, 'mlqc') + common_checks(logs, 'mldemo')
    lit_re = r'r_modellight (\d) \((\d+) models lit, (\d+) by dynamic lights, mean ([\d.]+)\)'
    lit = re.findall(lit_re, logs['mlight'])
    result.append((len(lit) == 4 and int(lit[0][1]) >= 1 and 0.2 < float(lit[0][3]) < 0.95,
                   'the models take the light of the level (%s)'
                   % ('%s models, mean %s' % (lit[0][1], lit[0][3]) if lit else 'no line')))
    result.append((len(lit) == 4 and lit[0][2] == '0' and int(lit[1][2]) >= 1,
                   'a shot lights the models near it'))
    result.append((len(lit) == 4 and lit[3][0] == '0' and float(lit[3][3]) == 1.0,
                   'r_modellight 0 draws them full bright'))
    marks = re.findall(r'r_decals (\d) \((\d+) decals, (\d+) made\)', logs['mlight'])
    result.append((len(marks) == 3 and int(marks[0][1]) >= 3 and marks[2][2] == marks[0][2],
                   'shots leave marks on the floor, none with r_decals 0 (%s)'
                   % (', '.join('%s made' % m[2] for m in marks) if marks else 'no line')))
    marks = re.findall(r'r_decals (\d) \((\d+) decals, (\d+) made\)', logs['mlqc'])
    result.append((len(marks) == 1 and int(marks[0][1]) >= 3,
                   'and in QuakeC mode (%s)' % (marks[0][1] if marks else 'no line')))
    for name, what in (('mlqc', 'QuakeC mode'), ('mldemo', 'a demo')):
        other = re.findall(lit_re, logs[name])
        result.append((len(other) == 1 and int(other[0][1]) >= 1 and 0.2 < float(other[0][3]) < 0.95,
                       'and in %s (%s)' % (what, 'mean %s' % other[0][3] if other else 'no line')))
    play = re.findall(r'Underwater view (on|off) \(play\)', logs['wplay'])
    result.append((play == ['on', 'off'],
                   'the play view waves under water, once: not with r_waterwarp 0 (%s)' % ', '.join(play)))
    result.append(('Underwater view on (qc)' in logs['wqc'], 'QuakeC mode waves under water too'))
    return result


def frames_video(out_dir):
    """The same wall beside the player with blocky and with smooth texels"""
    paths = [os.path.join(out_dir, 'vid_%d.png' % i) for i in (1, 2)]
    if not all(os.path.exists(p) for p in paths):
        return [(False, 'vid_1.png and vid_2.png exist')]
    box = (0, 500, 300, 800)
    blocky, smooth = (Image.open(p).convert('L').crop(box) for p in paths)

    def edges(img):
        # mean step between neighbouring pixels: hard texel borders make it large
        w, h = img.size
        px = img.load()
        return sum(abs(px[x, y] - px[x + 1, y]) for y in range(h) for x in range(w - 1)) / (h * (w - 1))

    e1, e2 = edges(blocky), edges(smooth)
    return [(e1 > e2 * 1.3, 'blocky texels have harder edges than smooth ones (%.2f, %.2f)' % (e1, e2))]


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
