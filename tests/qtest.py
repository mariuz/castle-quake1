"""Shared helpers of the test scripts (scenarios.py, community_maps.py and
the checks_*.py modules): where things are, starting the game headless,
the log lines the checks read, and the image comparison."""

import json
import os
import re
import shutil
import struct
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

def game_command(exe, args):
    command = [exe] + args
    if sys.platform.startswith('linux') and not os.environ.get('DISPLAY'):
        command = ['xvfb-run', '-a', '-s', '-screen 0 800x600x24'] + command
    return command


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


MAPBROWSER_PORT = 26340

DEMO_SHOT_RE = re.compile(r'Saved screenshot to ".*?" \(signon \d+, health -?\d+, ammo \d+, frags -?\d+, '
                          r'time ([\d.]+)\)')

PHOTO_RE = re.compile(r'Photo saved to "(.*?)": (\d+)x(\d+), fov (\d+), (\w+)')

SEEK_RE = re.compile(r'Demo seek from ([\d.]+) to ([\d.]+) \((from the start|forward)\): at ([\d.]+), time ([\d.]+), '
                     r'view entity at (-?[\d.]+) (-?[\d.]+) (-?[\d.]+)')

SPEC_RE = re.compile(r'Spectator: (following entity (\d+)|flying freely), eye at (-?[\d.]+) (-?[\d.]+) (-?[\d.]+)')

COOPBOT_RE = re.compile(r'(\w+) (-?\d+) frags \(health (-?\d+), (\d+) units, goal ([^,)]*)(?:, fighting [^,)]*)?'
                        r'(?:, (\d+) units from (\w+))?\)')

def pad_demo(name, confirm, back):
    # Open the menu with Start, walk to the map browser, confirm, go back,
    # close the menu with back, then a screenshot standing (not jumping)
    return ','.join(['W:0.5,S,PN:' + name + ',GB:start,W:0.5'] + ['GB:down,W:0.3'] * 3 +
                    ['GB:%s,W:0.5,GB:%s,W:0.5,GB:%s,W:0.6,S,Q' % (confirm, back, back)])


def dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5


SPLIT_RE = re.compile(r'Player 2: view entity (\d+) at (\S+) (\S+) (\S+), yaw (-?\d+), health (-?\d+), '
                      r'ammo (\d+), weapon \d+, signon \d+, viewports (\d+)x(\d+) and (\d+)x(\d+)')

PLAYER_RE = re.compile(r'Player (\d): view entity \d+ at (-?[\d.]+) (-?[\d.]+) (-?[\d.]+), yaw (-?\d+), .*'
                       r'viewports (\d+)x(\d+) and (\d+)x(\d+)')

def players(log):
    """{player: [(position, yaw, first view size, own view size) per screenshot]}"""
    result = {}
    for m in PLAYER_RE.findall(log):
        result.setdefault(int(m[0]), []).append(((float(m[1]), float(m[2]), float(m[3])), int(m[4]),
                                                (int(m[5]), int(m[6])), (int(m[7]), int(m[8]))))
    return result


PVS_COMPARE_RE = re.compile(r'PVS compare: (\d+) of \d+ pixels differ \((\d+) alone\)')

def pvs_clean(log):
    """Every NC compare in the log changed no pixel but lone ones (a crack one
    pixel wide between two faces shows what lies behind it, drawn or culled;
    a wrongly culled object differs in pixels next to each other)"""
    compares = PVS_COMPARE_RE.findall(log)
    return bool(compares) and all(differ == alone for differ, alone in compares)


def bsp_texture_names(data):
    """The miptex names of a BSP29 / BSP2 map"""
    off, _ = struct.unpack('<ii', data[4 + 2 * 8:4 + 2 * 8 + 8])
    count = struct.unpack('<i', data[off:off + 4])[0]
    names = []
    for i in range(count):
        o = struct.unpack('<i', data[off + 4 + 4 * i:off + 8 + 4 * i])[0]
        if o >= 0:
            names.append(data[off + o:off + o + 16].split(b'\0')[0].decode('latin-1'))
    return names


DEMO_VIEW_RE = re.compile(r'View entity \d+ at (\S+) (\S+) (\S+) \(protocol (\d+)\)')

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


RANDOM_RE = re.compile(r'Random map (\d+): (\d+) rooms \((\d+) reachable\).*?start ([-\d]+ [-\d]+ [-\d]+), '
                       r'exit ([-\d]+ [-\d]+ [-\d]+)')

# Open the menu (its touch button), Save Game > Slot 8, back, teleport,
# Load Game > the newest (slot 8)
SAVES_DEMO = ','.join(['W:0.5,Y,V:1;0;0,W:1,V:0;0;0,W:0.5,S,TD:4;0.97;0.95,W:0.3,TU:4,W:0.3'] +
                      ['GB:down,W:0.3'] * 4 + ['GB:south,W:0.5'] + ['GB:down,W:0.3'] * 7 +
                      ['GB:south,W:0.5,GB:east,W:0.3,M:200,W:0.2,S,CMD:saves'] + ['GB:down,W:0.3'] * 5 +
                      ['GB:south,W:0.5,GB:south,W:1,S,Q'])

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


def run(exe, args, log_path):
    """Play the game with args, its output into log_path; the exit code (or 'timeout') and the log"""
    with open(log_path, 'w') as log:
        try:
            code = subprocess.run(game_command(exe, args), stdout=log, stderr=subprocess.STDOUT, cwd=ROOT,
                                  timeout=PROCESS_TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    with open(log_path, errors='replace') as f:
        return code, f.read()


def pak_file(pak_path, name):
    """The bytes of a file in a .pak, None without it"""
    with open(pak_path, 'rb') as f:
        magic, offset, length = struct.unpack('<4sii', f.read(12))
        if magic != b'PACK':
            return None
        f.seek(offset)
        directory = f.read(length)
        for i in range(0, length, 64):
            entry = directory[i:i + 56].split(b'\0')[0].decode('latin1').lower()
            if entry == name:
                pos, size = struct.unpack_from('<ii', directory, i + 56)
                f.seek(pos)
                return f.read(size)
    return None


def md3_bytes(surfaces, frames=2):
    """A small MD3 model: each surface is (texture, [(x, y, z, s, t), ...],
    [(a, b, c), ...]); the frames after the first move the vertices up by
    8 units each"""
    def name(text, size):
        return text.encode('latin1').ljust(size, b'\0')[:size]
    body = b''
    for texture, verts, tris in surfaces:
        shaders = name(texture, 64) + struct.pack('<i', 0)
        triangles = b''.join(struct.pack('<3i', *t) for t in tris)
        st = b''.join(struct.pack('<2f', v[3], v[4]) for v in verts)
        xyz = b''.join(struct.pack('<4h', round(v[0] * 64), round(v[1] * 64), round((v[2] + 8 * f) * 64), 0)
                       for f in range(frames) for v in verts)
        ofs_tris = 108
        ofs_shaders = ofs_tris + len(triangles)
        ofs_st = ofs_shaders + len(shaders)
        ofs_xyz = ofs_st + len(st)
        ofs_end = ofs_xyz + len(xyz)
        body += (b'IDP3' + name('surface', 64) + struct.pack('<10i', 0, frames, 1, len(verts), len(tris), ofs_tris,
                                                             ofs_shaders, ofs_st, ofs_xyz, ofs_end) +
                 triangles + shaders + st + xyz)
    frame_data = b''.join(struct.pack('<10f', -16, -16, -24, 16, 16, 32, 0, 0, 0, 40) + name('frame%d' % f, 16)
                          for f in range(frames))
    ofs_frames = 108
    ofs_surfaces = ofs_frames + len(frame_data)
    header = (b'IDP3' + struct.pack('<i', 15) + name('test', 64) +
              struct.pack('<9i', 0, frames, 0, len(surfaces), 0, ofs_frames, ofs_surfaces, ofs_surfaces,
                          ofs_surfaces + len(body)))
    return header + frame_data + body


def iqm_bytes(meshes, lift=8.0):
    """A small IQM model with two joints, "root" at the origin and "top" 16
    units above it, and one animation "wave" of two frames whose second
    lifts the top joint by lift units. Each mesh is (texture,
    [(x, y, z, s, t, joint), ...], [(a, b, c), ...]): a vertex follows the
    one joint it names."""
    text = b'\0root\0top\0wave\0'
    names = {'root': 1, 'top': 6, 'wave': 10}
    mesh_data, positions, texcoords, indexes, weights, triangles = b'', b'', b'', b'', b'', b''
    first_vertex = first_triangle = 0
    for texture, verts, tris in meshes:
        material = len(text)
        text += texture.encode('latin1') + b'\0'
        mesh_data += struct.pack('<6I', 0, material, first_vertex, len(verts), first_triangle, len(tris))
        for x, y, z, s, t, joint in verts:
            positions += struct.pack('<3f', x, y, z)
            texcoords += struct.pack('<2f', s, t)
            indexes += bytes([joint, 0, 0, 0])
            weights += bytes([255, 0, 0, 0])
        triangles += b''.join(struct.pack('<3I', a + first_vertex, b + first_vertex, c + first_vertex)
                              for a, b, c in tris)
        first_vertex += len(verts)
        first_triangle += len(tris)
    text += b'\0' * (-len(text) % 4)
    identity = (0.0, 0.0, 0.0, 1.0)
    joints = (struct.pack('<Ii3f4f3f', names['root'], -1, 0, 0, 0, *identity, 1, 1, 1) +
              struct.pack('<Ii3f4f3f', names['top'], 0, 0, 0, 16, *identity, 1, 1, 1))
    # ten channels a pose: translate, rotate, scale; only the top joint's
    # height (channel 2) changes with the frames
    poses = (struct.pack('<iI10f10f', -1, 0, 0, 0, 0, *identity, 1, 1, 1, *([0.0] * 10)) +
             struct.pack('<iI10f10f', 0, 1 << 2, 0, 0, 16, *identity, 1, 1, 1,
                         0, 0, lift / 65535, 0, 0, 0, 0, 0, 0, 0))
    anims = struct.pack('<3IfI', names['wave'], 0, 2, 10.0, 0)
    frames = struct.pack('<2H', 0, 65535)
    blocks = [text, mesh_data, None, positions, texcoords, indexes, weights, triangles, joints, poses, anims, frames]
    offsets = []
    position = 124
    for i, block in enumerate(blocks):
        size = 4 * 20 if block is None else len(block)
        offsets.append(position)
        position += size + (-size % 4)
    arrays = (struct.pack('<5I', 0, 0, 7, 3, offsets[3]) + struct.pack('<5I', 1, 0, 7, 2, offsets[4]) +
              struct.pack('<5I', 4, 0, 1, 4, offsets[5]) + struct.pack('<5I', 5, 0, 1, 4, offsets[6]))
    blocks[2] = arrays
    header = b'INTERQUAKEMODEL\0' + struct.pack(
        '<27I', 2, position, 0, len(text), offsets[0], len(meshes), offsets[1], 4, first_vertex, offsets[2],
        first_triangle, offsets[7], 0, 2, offsets[8], 2, offsets[9], 1, offsets[10], 2, 1, offsets[11], 0, 0, 0, 0, 0)
    return header + b''.join(block + b'\0' * (-len(block) % 4) for block in blocks)

