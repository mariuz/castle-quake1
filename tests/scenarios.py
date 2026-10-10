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
    def __init__(self, name, runs, checks, references, threshold=DEFAULT_THRESHOLD):
        self.name = name
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
        for ok, description in results:
            print('  %s %s' % ('ok  ' if ok else 'FAIL', description))
            if not ok:
                failures += 1
        print('  (%.0f s)' % (time.time() - started), flush=True)
    print('%d failure(s)' % failures)
    return min(failures, 100)


if __name__ == '__main__':
    sys.exit(main())
