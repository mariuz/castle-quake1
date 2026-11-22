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
import struct
import subprocess
import sys
import time

from PIL import Image, ImageChops

import qtest
from qtest import *  # noqa: F401,F403
from checks_play import *  # noqa: F401,F403
from checks_net import *  # noqa: F401,F403
from checks_mods import *  # noqa: F401,F403


class Scenario:
    def __init__(self, name, runs, checks, references, threshold=DEFAULT_THRESHOLD, prepare=None,
                 frame_checks=None, dark=()):
        self.name = name
        self.dark = dark              # runs whose screenshots may be dark (a random deathmatch spawn)
        self.prepare = prepare        # function(out_dir) run before the processes, or None
        self.frame_checks = frame_checks  # function(out_dir) -> [(ok, description)] on the screenshots, or None
        self.runs = runs              # [(prefix, args, delay before start)]
        self.checks = checks          # function(logs) -> [(ok, description)]
        self.references = references  # screenshot names compared with tests/reference
        self.threshold = threshold


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


SCENARIOS = [
    Scenario('e1m1_finish', [('finish', ['--autotest', 'e1m1', '{out}/finish', '--demo',
                                         'W:0.5,Y,S,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,G:1312;-230;-544,W:1.5,S,'
                                         'W:5,X,W:3,S,Q'], 0)],
             # finish_3 (the intermission) looks from a random info_intermission spot: not compared
             check_e1m1_finish, ['finish_1', 'finish_4']),
    Scenario('e1m1_saveload', [('saveload', ['--autotest', 'e1m1', '{out}/saveload', '--demo',
                                             'W:0.5,G:1312;-218;-1156,A:270,C:2,W:1.5,X,W:0.6,X,W:0.6,O:scenario,'
                                             'W:4,S,L:scenario,S,Q'], 0)],
             check_e1m1_saveload, []),
    Scenario('deathmatch', [('dm_host', ['--autotest', 'host:start', '{out}/dm_host', '--demo', 'W:16,S,Q',
                                         '-port', '26300'], 0),
                            ('dm_client', ['--autotest', 'connect:127.0.0.1:26300', '{out}/dm_client', '--demo',
                                           'W:3,S,V:1;0;0,W:1,V:0;0;0,X,W:1.5,S,Q'], 4)],
             check_deathmatch, []),
    # qcglide: shots wake the first room's monsters, which walk in steps
    # of 0.1 s and glide between them (r_lerpmove)
    Scenario('quakec', [('qc', ['--autotest', 'qc:e1m1', '{out}/qc', '--demo', 'W:1,E,S,Q'], 0),
                        ('qcglide', ['--autotest', 'qc:e1m1', '{out}/qcglide', '--demo',
                                     'W:1,Y,X,W:1,X,W:2,S,W:0.05,S,W:0.05,S,CMD:profile,CMD:help,CMD:god,'
                                     'CMD:map nosuchmap,CMD:map e1m2,W:1,S,Q'], 0),
                        # the same fight recorded and played back: the demo
                        # carries the step flag and the monsters glide there too
                        ('qcrec', ['--autotest', 'qc:e1m1', '{out}/qcrec', '--demo',
                                   'W:0.5,R:glidedemo,W:0.5,Y,X,W:1,X,W:4,R,S,Q'], 0),
                        ('qcplay', ['--autotest', 'castle-config:/glidedemo.dem', '{out}/qcplay', '--demo',
                                    'W:3,S,W:0.33,S,W:0.33,S,W:0.33,S,Q'], 12)],
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
                               'W:0.5,Y,S,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,Q'], 0),
                      ('bigv', ['-game', '{out}', '--autotest', 'e1m1_bigv', '{out}/bigv', '--demo',
                                'W:0.5,Y,S,V:1;0;0,W:1.5,V:0;0;0,W:0.3,S,Q'], 0)],
             check_bsp2, ['bsp2_1', 'psb_1', 'bigv_1'], prepare=prepare_bsp2),
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
    # Horde mode: E1M1's monsters give way to waves (killall clears wave 1 -- twice, as its last monsters may still be coming in on a slow machine --,
    # wave 2 follows after the pause) and a random map plays it too
    Scenario('horde', [('waves', ['-horde', '--autotest', 'e1m1', '{out}/waves', '--demo',
                                  'W:0.5,Y,W:5,S,CMD:killall,W:2,CMD:killall,W:8,S,Q'], 0),
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
    # the map, items, fights, frags) and a network client joining them; the
    # idle host is their target and may be dead at the end, so it takes no
    # screenshot
    Scenario('bots', [('bhost', ['-bots', '3', '--autotest', 'host:e1m1', '{out}/bhost', '--demo', 'W:60,Q',
                                 '-port', '26320', '-spawnspot', '2'], 0),
                      ('bclient', ['--autotest', 'connect:127.0.0.1:26320', '{out}/bclient', '--demo',
                                   'W:6,S,Q'], 5),
                      ('bloop', ['-netloopback', '-bots', '3', '--autotest', 'host:e1m1', '{out}/bloop', '--demo',
                                 'W:22,S,Q'], 0)],
             check_bots, [], dark=('bloop',)),
    # Map browser: a test catalog served over HTTP, a download with a wrong
    # SHA-256 refused, the good one installed, mounted with its folder
    # mapped to maps/, both start maps played (the console, then the menu
    # with the virtual gamepad) and the release removed; then a map that needs a mod
    # downloads the mod first and plays in QuakeC mode
    Scenario('mapbrowser', [('browse', ['-mapcatalog', '{out}/maps.txt', '--autotest', 'e1m1', '{out}/browse',
                                        '--demo',
                                        'W:0.5,CMD:maps_remove qtest,CMD:maps_remove qmodmap,CMD:maps_remove qmod,'
                                        'CMD:maps,CMD:maps_install qbad,W:2,'
                                        'CMD:maps_play qtest,CMD:maps_install qtest,W:3,CMD:maps installed,'
                                        'CMD:maps_play qtest,W:1.5,S,CMD:maps_play qtest qtest2,W:1.5,S,'
                                        'TD:4;0.97;0.95,W:0.3,TU:4,W:0.3,GB:down,W:0.3,GB:down,W:0.3,GB:down,'
                                        'W:0.3,GB:south,W:0.5,GB:down,W:0.3,GB:south,W:0.5,GB:down,W:0.3,GB:down,'
                                        'W:0.3,GB:down,W:0.3,GB:down,W:0.3,GB:south,W:1.5,S,'
                                        'CMD:maps_remove qtest,CMD:maps installed,Q'], 0),
                            ('mod', ['-mapcatalog', '{out}/maps.txt', '--autotest', 'e1m1', '{out}/mod', '--demo',
                                     'W:0.5,CMD:maps_remove qmodmap,CMD:maps_remove qmod,CMD:maps_install qmodmap,'
                                     'W:4,CMD:maps installed,CMD:maps_install qtest,W:3,CMD:maps_mount qmodmap,'
                                     'CMD:maps_mount qmod,CMD:maps_play qtest,W:1.5,S,CMD:maps_remove qtest,'
                                     'CMD:maps_play qmodmap,W:2,S,Q'], 40)],
             check_mapbrowser, [], prepare=prepare_mapbrowser),
    # Photo mode: E1M1 paused while the camera flies off, a depth of field
    # photo at twice the window size and a grayscale one at fov 60, the
    # camera back on the player after; a demo waits in photo mode
    Scenario('photo', [('play', ['--autotest', 'e1m1', '{out}/play', '--demo',
                                 'W:0.5,Y,S,CMD:photo 1,M:-60,T:25,P:-10,W:2,S,CMD:photo_effect dof,'
                                 'CMD:photo_shot,CMD:photo_effect gray,CMD:photo_fov 60,CMD:photo_scale 1,'
                                 'W:0.2,CMD:photo_shot,CMD:photo 0,W:0.3,S,CMD:help,CMD:nosuch,Q'], 0),
                       ('pdemo', ['--autotest', 'demo1.dem', '{out}/pdemo', '--demo',
                                  'W:3,S,CMD:photo 1,M:-40,CMD:photo_effect vignette,W:1,CMD:photo_shot,S,'
                                  'CMD:photo 0,CMD:help,CMD:fov,CMD:nosuch 1,W:1,S,Q'], 0)],
             check_photo, [], frame_checks=frames_photo),
    # LAN discovery: a host answers the search of another process, which
    # joins the game it found
    Scenario('lan', [('lhost', ['--autotest', 'host:e1m1', '{out}/lhost', '--demo', 'W:14,S,Q', '-port', '26002'], 0),
                     ('lfind', ['--autotest', 'e1m1', '{out}/lfind', '--demo',
                                'W:1,CMD:lan,W:3.5,CMD:lan_join 1,W:4,S,Q'], 3)],
             check_lan, [], dark=('lhost', 'lfind')),
    # A spectator joins a deathmatch with two bots: it follows a player,
    # fire follows the next one, jump flies freely
    Scenario('spectate', [('shost', ['--autotest', 'host:e1m1', '{out}/shost', '--demo', 'W:16,S,Q', '-port', '26003',
                                     '-bots', '2'], 0),
                          ('spec', ['-spectate', '--autotest', 'connect:127.0.0.1:26003', '{out}/spec', '--demo',
                                    'W:3,S,X,W:1,S,J,W:0.3,V:1;0;0,W:1,V:0;0;0,S,Q'], 3)],
             check_spectate, [], dark=('shost', 'spec')),
    # Bots in coop: two bots on E1M3 with a player who stands still follow
    # him, fight and kill the monsters they meet
    Scenario('coopbots', [('cbhost', ['-coop', '-bots', '2', '--autotest', 'host:e1m3', '{out}/cbhost', '--demo',
                                      'W:31,S,Q', '-port', '26004'], 0)],
             check_coopbots, [], dark=('cbhost',)),
    # Recording a network game: the client starts recording mid-game
    # (R:netdemo), walks and fires, stops; the demo then plays back
    Scenario('netrecord', [('rhost', ['--autotest', 'host:e1m1', '{out}/rhost', '--demo', 'W:14,S,Q', '-port', '26005',
                                      '-bots', '1', '-spawnspot', '2'], 0),
                           ('rclient', ['--autotest', 'connect:127.0.0.1:26005', '{out}/rclient', '--demo',
                                        'W:2,R:netdemo,W:1,V:1;0;0,W:2,V:0;0;0,X,W:2,S,R,Q'], 3),
                           ('rplay', ['--autotest', 'castle-config:/netdemo.dem', '{out}/rplay', '--demo',
                                      'W:0.5,S,W:4,S,Q'], 16)],
             # -spawnspot: the host and the client start at fixed, lit spots
             check_netrecord, [], dark=('rhost',)),
    # Chat: a client says something, everyone gets it; the host answers
    Scenario('chat', [('chost', ['--autotest', 'host:e1m1', '{out}/chost', '--demo',
                                 'WL:hello there,W:0.5,SAY:gg,W:2.5,S,Q', '-port',
                                 '26006'], 0),
                      ('cclient', ['--autotest', 'connect:127.0.0.1:26006', '{out}/cclient', '--demo',
                                   'WL:Connected,W:1.5,SAY:hello there,WL:: gg,W:0.5,S,Q'], 2)],
             check_chat, [], dark=('chost', 'cclient')),
    # Player names and colors: a coop host and a client, each with its
    # -name and -color; the client turns to the host's player
    Scenario('names', [('nhost', ['-name', 'Ranger', '-color', '4', '12', '--autotest', 'host:e1m1', '{out}/nhost',
                                  '--demo', 'W:9,S,Q', '-port', '26008', '-coop'], 0),
                       ('nclient', ['-name', 'Scout', '-color', '13', '3', '--autotest', 'connect:127.0.0.1:26008',
                                    '{out}/nclient', '--demo', 'W:4,A:0,P:-10,W:0.5,S,SB,Q'], 2)],
             check_names, [], frame_checks=frames_names),
    # Teamplay: a red host and a blue client with three bots, who even the
    # teams and fight only the other one
    Scenario('teamplay', [('thost', ['-name', 'Ranger', '-color', '4', '4', '-teamplay', '1', '--autotest', 'host:e1m1',
                                     '{out}/thost', '--demo', 'W:30,SB,S,Q', '-port', '26009', '-bots', '3'], 0),
                          ('tclient', ['-name', 'Scout', '-color', '13', '13', '--autotest', 'connect:127.0.0.1:26009',
                                       '{out}/tclient', '--demo', 'W:25,SB,S,Q'], 2)],
             check_teamplay, [], dark=('thost', 'tclient')),
    # Map records: E1M1 finished after a walk, then straight away (a new
    # best time), listed in the console and in Map Warp's hint
    Scenario('records', [('rec1', ['--autotest', 'e1m1', '{out}/rec1', '--demo',
                                   'W:0.5,CMD:records_reset e1m1,Y,V:1;0;0,W:2,V:0;0;0,G:1312;-230;-544,W:6.5,S,Q'], 0),
                         ('rec2', ['--autotest', 'e1m1', '{out}/rec2', '--demo',
                                   'W:0.5,Y,G:1312;-230;-544,W:6.5,S,CMD:records e1m1,X,W:2,GB:start,W:0.5,GB:down,'
                                   'W:0.3,GB:down,W:0.3,GB:south,W:0.5,GB:down,W:0.5,S,Q'], 18)],
             check_records, []),
    # External textures: a texture pack in a game directory replaces E1M1's
    # wall textures (QuakeSpasm-Spiked's textures/<map>/<name>.tga)
    # Video options: the wall textures blocky, then smooth (without the
    # anisotropic filter, which smooths them on the software renderer)
    Scenario('video', [('vid', ['--autotest', 'e1m1', '{out}/vid', '--demo',
                                'W:0.3,CMD:gl_texture_anisotropy 1,CMD:map e1m1,W:2.5,S,'
                                'CMD:gl_texturemode linear,CMD:map e1m1,W:2.5,S,Q'], 0),
                       # the eyes in E1M1's water: the picture waves, in the
                       # play view and in QuakeC mode, and not with r_waterwarp 0
                       ('wplay', ['--autotest', 'e1m1', '{out}/wplay', '--demo',
                                  'W:1,Y,G:550;-318;-920,W:0.6,S,G:480;46;-352,W:0.4,CMD:r_waterwarp 0,'
                                  'G:550;-318;-920,W:0.6,S,Q'], 0),
                       # the models take the light of the level, a shot lights
                       # the weapon, r_modellight 0 is full bright again
                       ('mlight', ['--autotest', 'e1m1', '{out}/mlight', '--demo',
                                   'W:1,CMD:r_modellight,X,W:0.4,CMD:r_modellight,CMD:r_modellight 0,W:0.5,'
                                   'CMD:r_modellight,P:-35,X,W:0.5,CMD:r_decals,S,CMD:r_decals 0,X,W:0.5,'
                                   'CMD:r_decals,Q'], 0),
                       ('mlqc', ['--autotest', 'qc:e1m1', '{out}/mlqc', '--demo',
                                 'W:1,CMD:r_modellight,P:-35,X,W:0.5,CMD:r_decals,S,Q'], 0),
                       ('mldemo', ['--autotest', 'demo1.dem', '{out}/mldemo', '--demo',
                                   'W:3,CMD:r_modellight,S,Q'], 0),
                       ('wqc', ['--autotest', 'qc:e1m1', '{out}/wqc', '--demo',
                                'W:1,Y,G:550;-318;-920,W:0.6,S,Q'], 0)],
             check_video, [], frame_checks=frames_video),
    # A mod's effectinfo.txt draws the shotgun's impacts in QuakeC mode
    # (and not with r_effectinfo 0)
    Scenario('fxmod', [('fx', ['-game', '{out}/fxmod', '--autotest', 'qc:e1m1', '{out}/fx', '--demo',
                               'W:1,X,W:0.2,S,W:0.6,CMD:effect TE_TELEPORT,W:0.2,S,Q'], 0),
                       ('fxoff', ['-game', '{out}/fxmod', '--autotest', 'qc:e1m1', '{out}/fxoff', '--demo',
                                  'W:0.5,CMD:r_effectinfo 0,W:0.5,X,W:0.2,S,Q'], 0),
                       # the same in a network game: the host's own view
                       ('fxnet', ['-game', '{out}/fxmod', '--autotest', 'host:e1m1', '{out}/fxnet', '--demo',
                                  'W:4,X,W:0.3,CMD:effect TE_TELEPORT,W:0.3,S,Q', '-port', '26014',
                                  '-netloopback'], 0),
                       # QuakeC mode records the effect into a demo, which plays it
                       ('fxrec', ['-game', '{out}/fxmod', '--autotest', 'qc:e1m1', '{out}/fxrec', '--demo',
                                  'W:0.5,R:fxdemo,W:0.5,CMD:effect TE_TELEPORT,W:4,R,Q'], 0),
                       ('fxplay', ['-game', '{out}/fxmod', '--autotest', 'castle-config:/fxdemo.dem', '{out}/fxplay',
                                   '--demo', 'W:3,S,Q'], 0)],
             check_fxmod, [], prepare=prepare_fxmod, dark=('fxnet',)),
    Scenario('exttex', [('tex', ['-game', '{out}/texmod', '--autotest', 'e1m1', '{out}/tex', '--demo', 'W:0.5,S,Q'], 0)],
             check_exttex, [], prepare=prepare_exttex, frame_checks=frames_exttex),
    # Host console: the listen server's host lists the players, kicks a bot,
    # sets the frag limit, adds a bot, kicks the client and changes the map;
    # the client is told and cannot run host commands itself
    Scenario('hostcmd', [('khost', ['--autotest', 'host:e1m1', '{out}/khost', '--demo',
                                    'W:6,CMD:status,CMD:kick Raven,CMD:fraglimit 5,CMD:addbot,W:6,CMD:kick Scout,W:1,'
                                    'CMD:status,CMD:map start,W:4,S,CMD:status,Q', '-port', '26012', '-bots', '2'], 0),
                         ('kclient', ['-name', 'Scout', '--autotest', 'connect:127.0.0.1:26012', '{out}/kclient',
                                      '--demo', 'W:5,SAY:/kick Wolf,W:4,SB,W:8,S,Q'], 2)],
             check_hostcmd, [], dark=('khost', 'kclient')),
    # Deathmatch rules: a time limit of 12 s ends E1M1, a press leaves the
    # intermission and the rotation (e1m1,start) picks the next map; the
    # client follows
    # The host presses fire a few times: the progs leave a deathmatch
    # intermission only 5 s after it starts, later on a slow machine
    Scenario('dmrules', [('dhost', ['-timelimit', '0.2', '-maps', 'e1m1,start', '--autotest', 'host:e1m1',
                                    '{out}/dhost', '--demo', 'W:16,S,X,W:2,X,W:2,X,W:2,X,W:5,S,Q', '-port', '26007',
                                    '-bots', '1'],
                          0),
                         ('dclient', ['--autotest', 'connect:127.0.0.1:26007', '{out}/dclient', '--demo',
                                      'W:4,SB,W:22,S,Q'], 2)],
             check_dmrules, [], dark=('dhost', 'dclient')),
    # Demo playback controls: seek forward, back (the demo plays again
    # from the start, landing on the same spot), pause, twice the speed
    Scenario('demoplay', [('play', ['--autotest', 'demo1.dem', '{out}/play', '--demo',
                                    'W:2,S,DK:30,W:0.1,S,DK:10,W:0.1,S,DK:30,W:0.1,S,DP,W:1,S,DP,DS:2,W:3,S,DS:1,'
                                    'DK:-5,W:0.1,S,Q'], 0)],
             check_demoplay, []),
    # Save and Load Game in the menu (the virtual gamepad walks it): slot 8
    # saved with a thumbnail, the player teleported away, slot 8 loaded
    # back from the newest-first list; then a game started from load:8
    Scenario('saves', [('menusave', ['--autotest', 'e1m1', '{out}/menusave', '--demo', SAVES_DEMO], 0),
                       ('startload', ['--autotest', 'load:8', '{out}/startload', '--demo', 'W:0.5,S,Q'], 12)],
             check_saves, []),
    # Controller glyphs: a PlayStation, a Nintendo and an Xbox pad by name
    # (the virtual pad), each walking the menu with its own confirm and back
    # buttons (Nintendo's A is east) and closing it without jumping
    Scenario('pads', [('ps', ['--autotest', 'e1m1', '{out}/ps', '--demo',
                              pad_demo('Sony Interactive Entertainment Wireless Controller', 'south', 'east')], 0),
                      ('switch', ['--autotest', 'e1m1', '{out}/switch', '--demo',
                                  pad_demo('Nintendo Switch Pro Controller', 'east', 'south')], 0),
                      ('xbox', ['--autotest', 'e1m1', '{out}/xbox', '--demo',
                                pad_demo('Xbox Wireless Controller', 'south', 'east')], 0)],
             check_pads, []),
    # Localization: German from the command line (the menu and the map
    # browser hints), Italian from the console after an English start
    Scenario('language', [('de', ['-lang', 'de', '--autotest', 'e1m1', '{out}/de', '--demo',
                                  'W:0.5,PN:Xbox Wireless Controller,GB:start,W:0.5,S,GB:down,W:0.3,GB:down,W:0.3,'
                                  'GB:down,W:0.3,GB:south,W:0.5,S,Q'], 0),
                          ('it', ['--autotest', 'e1m1', '{out}/it', '--demo',
                                  'W:0.5,CMD:lang it,PN:Xbox Wireless Controller,GB:start,W:0.5,S,Q'], 0),
                          ('ro', ['-lang', 'ro', '--autotest', 'e1m1', '{out}/ro', '--demo',
                                  'W:0.5,PN:Xbox Wireless Controller,GB:start,W:0.5,S,Q'], 0)],
             check_language, []),
    # Split-screen coop: a second local player on the listen server with the
    # (virtual) gamepad, side by side and one above the other; the stick
    # walks and turns only the second player, the keyboard script only the
    # first, the trigger fires the second player's weapon
    Scenario('splitscreen', [('sides', ['-splitscreen', '--autotest', 'host:e1m1', '{out}/sides', '--demo',
                                        'W:4,NC,S,GL:0;1,W:2,GL:0;0,GR:1;0,W:0.5,GR:0;0,W:0.5,NC,S,Q',
                                        '-port', '26360'], 0),
                             # The browser's way: the listen server and both
                             # clients on in-process loopback sockets
                             ('loop', ['-netloopback', '-splitscreen', '--autotest', 'host:e1m1', '{out}/loop',
                                       '--demo', 'W:4,S,GL:0;1,W:2,GL:0;0,W:0.5,NC,S,Q'], 0),
                             # Four players from the start (three virtual pads)
                             ('four', ['-splitplayers', '4', '--autotest', 'host:e1m1', '{out}/four', '--demo',
                                       'PADS:3,W:4,S,PAD:1,GL:0;1,W:2,GL:0;0,PAD:2,GR:1;0,W:0.5,GR:0;0,W:0.3,NC,S,Q',
                                       '-port', '26362'], 0),
                             # Two players, a third pad presses Start and joins
                             ('join', ['-splitscreen', '--autotest', 'host:e1m1', '{out}/join', '--demo',
                                       'PADS:3,W:4,S,PAD:2,GB:start,W:2,S,GL:0;1,W:1.5,GL:0;0,W:0.3,NC,S,Q',
                                       '-port', '26363'], 0),
                             ('stacked', ['-splitscreen', 'stacked', '--autotest', 'host:e1m1', '{out}/stacked',
                                          '--demo', 'W:4,S,V:1;0;0,W:1,V:0;0;0,GT:1,W:0.6,GT:0,W:0.5,S,Q',
                                          '-port', '26361'], 0)],
             check_split, [], frame_checks=split_frames),
    # Performance budgets: the PVS counts at fixed spots on four maps against
    # tests/budgets.json (--update rewrites it), frame times in budgets.json
    # of the output directory; one map after the other, so the frame times
    # are not shared with another process
    Scenario('budgets', [(name, ['--autotest', name, '{out}/' + name, '--demo', budget_demo(spots)], 20 * i)
                         for i, (name, spots) in enumerate(BUDGET_SPOTS.items())],
             check_budgets, []),
]

def image_checks(out_dir, scenario, update):
    result = []
    shots = sorted(f[:-4] for f in os.listdir(out_dir)
                   if f.endswith('.png') and not f.endswith('_compare.png')
                   and any(f.startswith(prefix + '_') for prefix, _, _ in scenario.runs))
    for shot in shots:
        if any(shot.startswith(prefix + '_') for prefix in scenario.dark):
            continue
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


def is_network(scenario):
    return any(a.startswith(('host:', 'connect:')) for _, run_args, _ in scenario.runs for a in run_args)


def play(args, out_dir, scenario):
    logs = run_scenario(args.exe, out_dir, scenario)
    results = scenario.checks(logs) + image_checks(out_dir, scenario, args.update)
    if scenario.frame_checks is not None:
        results += scenario.frame_checks(out_dir)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--exe', default=os.path.join(ROOT, 'castle-quake1' + ('.exe' if os.name == 'nt' else '')))
    parser.add_argument('--out', default=os.path.join(ROOT, 'castle-engine-output', 'scenarios'))
    parser.add_argument('--only', action='append', help='run only this scenario (repeatable)')
    parser.add_argument('--update', action='store_true', help='write the screenshots as the new references')
    args = parser.parse_args()
    qtest.UPDATE = args.update

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
        results = play(args, out_dir, scenario)
        # A game over the network depends on timing: one more try before it
        # counts as failed, and the output says so
        if is_network(scenario) and not all(ok for ok, _ in results):
            for ok, description in results:
                if not ok:
                    print('  retry after: %s' % description)
            shutil.rmtree(out_dir, ignore_errors=True)
            os.makedirs(out_dir)
            results = play(args, out_dir, scenario)
        for ok, description in results:
            print('  %s %s' % ('ok  ' if ok else 'FAIL', description))
            if not ok:
                failures += 1
        print('  (%.0f s)' % (time.time() - started), flush=True)
    print('%d failure(s)' % failures)
    return min(failures, 100)

if __name__ == '__main__':
    sys.exit(main())
