"""Checks of the network scenarios: deathmatch, coop, bots, spectators, chat, host commands, split-screen."""

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


def check_lan(logs):
    result = common_checks(logs, 'lhost') + common_checks(logs, 'lfind')
    find, host = logs['lfind'], logs['lhost']
    found = re.findall(r'LAN: found (\S+):(\d+): (\S+) \(([^)]*)\), (\d+)/(\d+), (\w+)', find)
    result.append((len(found) == 1 and found[0][1] == '26002' and found[0][2] == 'e1m1' and found[0][6] == 'deathmatch'
                   and found[0][4] == '1' and found[0][5] == '8',
                   'the search finds the host once: e1m1, 1 of 8 players, deathmatch (%s)'
                   % '; '.join(':'.join(f[:3]) for f in found)))
    result.append(('LAN: 1 games found' in find, 'the search ends after its time'))
    result.append(('Joining the LAN game' in find and 'Client 2 connected' in host,
                   'lan_join joins the game it found'))
    v = DEMO_SHOT_RE.findall(find)
    result.append((re.search(r'Saved screenshot to ".*lfind_1\.png" \(signon 4', find) is not None,
                   'the joined client plays (signon 4)'))
    return result


def check_spectate(logs):
    result = common_checks(logs, 'shost') + common_checks(logs, 'spec')
    host, spec = logs['shost'], logs['spec']
    result.append((re.search(r'Client \d+ connected from \S+ as a spectator, following \d+', host) is not None,
                   'the spectator joins without a player of its own'))
    result.append((re.search(r'Spectator \d+ follows \d+', host) is not None, 'fire follows the next player'))
    shots = SPEC_RE.findall(spec)
    result.append((len(shots) == 3, 'every screenshot logs the spectator (%d)' % len(shots)))
    if len(shots) == 3:
        a, b, c = shots
        result.append((a[1] != '' and b[1] != '' and a[1] != b[1],
                       'it follows one player, then another (entities %s and %s)' % (a[1], b[1])))
        moved = dist(tuple(float(x) for x in b[2:5]), tuple(float(x) for x in c[2:5]))
        result.append((c[0] == 'flying freely' and moved > 100,
                       'jump lets it fly freely, away from the player (%.0f units)' % moved))
    result.append(('signon 4' in spec, 'the spectator gets the game (signon 4)'))
    return result


def check_coopbots(logs):
    log = logs['cbhost']
    result = common_checks(logs, 'cbhost')
    result.append(('Bot "Wolf" joined' in log and 'Bot "Raven" joined' in log, 'two bots join the coop game'))
    lines = [l for l in log.splitlines() if l.startswith('Bots: Wolf')]
    last = COOPBOT_RE.findall(lines[-1]) if lines else []
    result.append((len(last) == 2 and all(b[6] == 'player3' for b in last),
                   'the bots follow the human player (%s)' % ', '.join('%s: %s' % (b[0], b[6] or '-') for b in last)))
    result.append((len(last) == 2 and all(b[5] != '' and int(b[5]) < 1500 for b in last),
                   'and stay with him (%s units)' % ', '.join(b[5] or '-' for b in last)))
    fights = re.findall(r'Bot "\w+" fights (monster_\w+)', log)
    result.append((len(fights) > 0, 'they fight the monsters (%s)' % ', '.join(sorted(set(fights)))))
    m = re.findall(r'coop: (\d+) of (\d+) monsters killed', log)
    result.append((bool(m) and int(m[-1][0]) >= 2, 'they kill monsters while the player stands still (%s)'
                   % (' of '.join(m[-1]) if m else '-')))
    shot = re.search(r'Saved screenshot to ".*cbhost_1\.png" \(signon 4, health (-?\d+)', log)
    result.append((shot is not None and int(shot.group(1)) > 0,
                   'the player they go with stays alive (health %s)' % (shot.group(1) if shot else '-')))
    return result


def check_netrecord(logs):
    result = common_checks(logs, 'rhost') + common_checks(logs, 'rclient') + common_checks(logs, 'rplay')
    c, p = logs['rclient'], logs['rplay']
    m = re.search(r'Recording the network game to "netdemo" \((\d+) signon blocks\)', c)
    result.append((m is not None and int(m.group(1)) > 0,
                   'a recording started mid-game begins with the level\'s signon (%s blocks)' % (m.group(1) if m else '-')))
    m = re.search(r'Recorded the network game to "castle-config:/netdemo.dem": (\d+) blocks', c)
    result.append((m is not None and int(m.group(1)) > 50, 'the recording is saved (%s blocks)' % (m.group(1) if m else '-')))
    m = re.search(r'Demo "castle-config:/netdemo.dem": ([\d.]+) s', p)
    result.append((m is not None and float(m.group(1)) > 3, 'it plays back as a demo (%s s)' % (m.group(1) if m else '-')))
    shots = DEMO_SHOT_RE.findall(p)
    views = re.findall(r'View entity \d+ at (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) \(protocol 15\)', p)
    # Before the walk (the recording's first second) and after it; a
    # deathmatch spawn can face a wall, so any clear move counts
    result.append((len(views) == 2 and dist(tuple(map(float, views[0])), tuple(map(float, views[1]))) > 32,
                   'the recorded player walks in the playback (%s)' % ' -> '.join(' '.join(v) for v in views)))
    ammo = re.findall(r'Saved screenshot to ".*rplay_\d\.png" \(signon 4, health -?\d+, ammo (\d+)', p)
    result.append((len(ammo) == 2 and int(ammo[1]) < int(ammo[0]), 'and fires (ammo %s)' % ' -> '.join(ammo)))
    return result


def check_chat(logs):
    result = common_checks(logs, 'chost') + common_checks(logs, 'cclient')
    h, c = logs['chost'], logs['cclient']
    m = re.search(r'Chat: (\w+): hello there', h)
    result.append((m is not None, 'the server gets the client\'s chat (%s)' % (m.group(1) if m else '-')))
    who = m.group(1) if m else 'player'
    result.append(((who + ': hello there') in c.split('Chat:')[-1] and re.search(r'Demo: \w+: hello there', c) is not None,
                   'the client gets it back'))
    result.append((re.search(r'Demo: \w+: hello there', h) is not None, 'the host\'s player gets it'))
    result.append((re.search(r'Demo: \w+: gg', c) is not None, 'and the host\'s answer reaches the client'))
    waits = re.findall(r'LogWatch: found "([^"]*)" after ([\d.]+) s', h + c)
    result.append((len(waits) == 3 and 'LogWatch: gave up' not in h + c,
                   'both scripts wait for log lines, not seconds (%s)' % ', '.join('%s %s s' % w for w in waits)))
    return result


def check_names(logs):
    result = common_checks(logs, 'nhost') + common_checks(logs, 'nclient')
    h, c = logs['nhost'], logs['nclient']
    result.append(('Client 1 is "Ranger", colors 4 12' in h, 'the host\'s player has its -name and -color'))
    result.append(('Client 2 is "Scout", colors 13 3' in h, 'the client\'s name and colors reach the server'))
    m = re.search(r'Scoreboard: (.*)', c)
    board = m.group(1) if m else ''
    result.append(('Ranger 0' in board and 'Scout 0 (you' in board, 'the scoreboard shows both names (%s)' % board))
    result.append(('Skin 0 of "player" in colors 4 12' in c, 'the client draws the host\'s player in its colors'))
    result.append(('Skin 0 of "player" in colors 13 3' in h, 'the host draws the client\'s player in its colors'))
    return result


def frames_names(out_dir):
    """The client looks at the host's player: a red shirt (4) and yellow
    pants (12) in the middle of the screen."""
    path = os.path.join(out_dir, 'nclient_1.png')
    if not os.path.exists(path):
        return [(False, 'nclient_1.png exists')]
    img = Image.open(path).convert('RGB')
    w, h = img.size
    red = yellow = 0
    for y in range(int(h * 0.3), int(h * 0.75)):
        for x in range(int(w * 0.4), int(w * 0.6)):
            r, g, b = img.getpixel((x, y))
            if r > 50 and g < 0.25 * r and b < 0.25 * r:
                red += 1
            elif r > 50 and g > 0.6 * r and b < 0.15 * r:
                yellow += 1
    # The player covers about 4 % of the box in each color; the walls none
    area = (w * 0.2) * (h * 0.45)
    return [(red > area * 0.01, 'a red shirt in the middle (%d pixels)' % red),
            (yellow > area * 0.01, 'yellow pants in the middle (%d pixels)' % yellow)]


def check_teamplay(logs):
    result = common_checks(logs, 'thost') + common_checks(logs, 'tclient')
    h, c = logs['thost'], logs['tclient']
    result.append(('teamplay 1' in ''.join(re.findall(r'Rules: .*', h)), 'the host plays teamplay 1'))
    # The client's scoreboard: two teams, the humans in their own colors
    m = re.search(r'Scoreboard: (.*)', c)
    board = m.group(1) if m else ''
    teams = {}
    for t in re.sub(r' \(you, ping \d+ ms\)', '', board).split('; '):
        tm = re.match(r'(\w[\w ]*) team -?\d+: (.*)', t)
        if tm:
            teams[tm.group(1)] = [re.match(r'(\w+)', p).group(1) for p in tm.group(2).split(', ')]
    result.append((set(teams) == {'Red', 'Blue'}, 'the scoreboard has a red and a blue team (%s)' % board))
    result.append(('Ranger' in teams.get('Red', []) and 'Scout' in teams.get('Blue', []),
                   'the players are in the teams of their pants'))
    sizes = sorted(len(v) for v in teams.values())
    result.append((len(sizes) == 2 and sizes[1] - sizes[0] <= 1 and sum(sizes) == 5,
                   'the bots even the teams (%s)' % sizes))
    # After the last change of teams, a bot fights only the other team
    team_of = {n: t for t, names in teams.items() for n in names}
    after = h.split('joins team')[-1]
    fights = re.findall(r'Bot "(\w+)" fights (\w+)', after)
    friendly = [f for f in fights if f[1] in team_of and team_of.get(f[0]) == team_of[f[1]]]
    result.append((not friendly, 'no bot fights its own team (%d fights, %s)' % (len(fights), friendly)))
    return result


def check_hostcmd(logs):
    result = common_checks(logs, 'khost') + common_checks(logs, 'kclient')
    h, c = logs['khost'], logs['kclient']
    status = re.findall(r'Host: status: (.*)', h)
    result.append((len(status) == 3 and 'Raven' in status[0] and 'Scout' in status[0],
                   'status lists the bots and the client (%s)' % (status[0] if status else '-')))
    result.append(('Host: kick Raven: Kicked Raven' in h and 'Bot "Raven" left' in h, 'the host kicks a bot'))
    result.append(('Host: fraglimit 5: fraglimit 5' in h and 'Host: addbot: 1 bots added' in h,
                   'the host sets the frag limit and adds a bot'))
    result.append(('Demo: Raven was kicked by the host' in c and 'Demo: The host sets fraglimit to 5' in c,
                   'the client is told'))
    result.append(('Host command "kick Wolf" refused: not the host' in c and 'Bot "Wolf" left' not in h,
                   'a client cannot run host commands'))
    result.append(('Host: kick Scout: Kicked Scout' in h and 'Connection ended' in c,
                   'the host kicks the client, whose connection ends'))
    result.append((len(status) == 3 and 'Scout' not in status[1] and 'Scout' not in status[2],
                   'the kicked player leaves the game (%s)' % (status[1] if len(status) > 1 else '-')))
    result.append(('Host: map start: Level changed to start' in h and 'Loaded map "maps/start.bsp"' in h,
                   'the host changes the level'))
    return result


def check_dmrules(logs):
    result = common_checks(logs, 'dhost') + common_checks(logs, 'dclient')
    h, c = logs['dhost'], logs['dclient']
    result.append(('Rules: fraglimit 0, timelimit 0.2 minutes, maps e1m1,start' in h, 'the host has the rules'))
    m = re.search(r'Map rotation: "(\w+)" after "e1m1" \(the progs asked for "(\w+)"\)', h)
    result.append((m is not None and m.group(1) == 'start',
                   'the time limit ends E1M1 and the rotation picks the next map (%s, not %s)'
                   % (m.group(1), m.group(2)) if m else 'the time limit ends E1M1 and the rotation picks the next map'))
    result.append(('Level change to "start"' in h, 'the server changes the level'))
    result.append(('Loaded map "maps/start.bsp"' in c.split('Level "the Slipgate Complex"')[-1],
                   'the client follows to the next map'))
    m = re.search(r'Scoreboard: (.*)', c)
    board = m.group(1) if m else ''
    entries = re.findall(r'(\w+) (-?\d+)( \(you, ping (\d+) ms\))?', board)
    frags = [int(e[1]) for e in entries]
    result.append((len(entries) == 3 and frags == sorted(frags, reverse=True) and 'Wolf' in board and
                   sum(1 for e in entries if e[2]) == 1,
                   'the scoreboard lists the host, the bot and the client by frags (%s)' % board))
    result.append((re.search(r'Scoreboard at the intermission: .*Wolf', h) is not None,
                   'the deathmatch intermission shows the scoreboard'))
    return result


def check_split(logs):
    result = common_checks(logs, 'sides') + common_checks(logs, 'stacked')
    for prefix in ('sides', 'stacked', 'loop', 'four', 'join'):
        log = logs[prefix]
        result.append(('Split-screen: player 2 joins' in log, '%s: the second player joins the listen server' % prefix))
    log = logs['sides']
    p1 = [tuple(float(x) for x in m[:3]) for m in DEMO_VIEW_RE.findall(log)]
    p2 = SPLIT_RE.findall(log)
    result.append((len(p1) == 2 and len(p2) == 2, 'sides: both players are logged at each screenshot'))
    if len(p1) == 2 and len(p2) == 2:
        a = [tuple(float(x) for x in m[1:4]) for m in p2]
        result.append((p2[0][0] != '1' and dist(a[0], p1[0]) > 32, 'two player entities at different spawn spots'))
        result.append((dist(a[0], a[1]) > 200, 'the gamepad walks the second player (%.0f units)' % dist(a[0], a[1])))
        result.append((dist(p1[0], p1[1]) < 8, 'the first player stays (%.0f units)' % dist(p1[0], p1[1])))
        result.append((p2[0][4] != p2[1][4], 'the right stick turns the second player (yaw %s -> %s)'
                       % (p2[0][4], p2[1][4])))
        w1, h1, w2, h2 = (int(x) for x in p2[0][7:11])
        result.append((w1 == w2 and h1 == h2 and w1 * 2 > h1, 'side by side: two views of %dx%d' % (w1, h1)))
    compares = [(c[0],) + c[2:] for c in re.findall(r'PVS compare: (\d+) of \d+ pixels differ \((\d+) alone\), '
                                                   r'leaves (-?\d+) and (-?\d+), clusters (\d+)/(\d+)', log)]
    alone = re.findall(r'PVS compare: \d+ of \d+ pixels differ \((\d+) alone\)', log)
    result.append((len(compares) == 2 and pvs_clean(log),
                   'sides: culling changes no pixel of either view but lone ones in cracks (%s)'
                   % ', '.join('%s, %s alone' % (c[0], a) for c, a in zip(compares, alone))))
    result.append((len(compares) == 2 and all(int(c[3]) < int(c[4]) for c in compares),
                   'sides: the world is culled to what the two cameras can see (%s)'
                   % ', '.join('%s/%s' % (c[3], c[4]) for c in compares)))
    result.append((len(compares) == 2 and compares[1][1] != compares[1][2],
                   'sides: the players are in different leaves after walking (%s)'
                   % (' and '.join(compares[1][1:3]) if len(compares) == 2 else '')))
    log = logs['loop']
    result += common_checks(logs, 'loop')
    result.append(('Loopback socket on port 26000' in log and log.count('Loopback socket on port 400') == 2 and
                   log.count('QuakeNet: Connected') == 2, 'loop: the server and both clients use loopback sockets'))
    p2 = SPLIT_RE.findall(log)
    result.append((len(p2) == 2 and dist(tuple(float(x) for x in p2[0][1:4]), tuple(float(x) for x in p2[1][1:4])) > 200,
                   'loop: the second player walks over the loopback'))
    result.append(('PVS compare:' in log and pvs_clean(log), 'loop: culling changes no pixel'))
    # Four players in a 2 x 2 grid: pad 1 walks player 3, pad 2 turns player 4
    log = logs['four']
    result += common_checks(logs, 'four')
    pl = players(log)
    result.append(('Split-screen: player 4 joins' in log and sorted(pl) == [2, 3, 4] and
                   all(len(v) == 2 for v in pl.values()), 'four: players 2, 3 and 4 join and are logged'))
    if sorted(pl) == [2, 3, 4] and all(len(v) == 2 for v in pl.values()):
        result.append((dist(pl[3][0][0], pl[3][1][0]) > 200 and dist(pl[2][0][0], pl[2][1][0]) < 8 and
                       dist(pl[4][0][0], pl[4][1][0]) < 8, 'four: the second pad walks only player 3 (%.0f units)'
                       % dist(pl[3][0][0], pl[3][1][0])))
        result.append((pl[4][0][1] != pl[4][1][1] and pl[3][0][1] == pl[3][1][1],
                       'four: the third pad turns only player 4 (yaw %d -> %d)' % (pl[4][0][1], pl[4][1][1])))
        sizes = set(v[0][3] for v in pl.values()) | set(v[0][2] for v in pl.values())
        result.append((len(sizes) == 1, 'four: four views of the same size (%s)' % sizes))
    result.append((re.search(r'PVS compare: .*, 4 views', log) is not None and pvs_clean(log),
                   'four: culling changes no pixel of the four views'))
    # A third pad's Start adds player 3 to a two-player game
    log = logs['join']
    result += common_checks(logs, 'join')
    pl = players(log)
    result.append(('pressed Start: player 3' in log and 'player 3 joins on port' in log and
                   '(one on top, two below)' in log, 'join: Start on a free pad adds player 3'))
    result.append((3 in pl and dist(pl[3][0][0], pl[3][-1][0]) > 200 if 3 in pl else False,
                   'join: the new player walks with its pad'))
    if 3 in pl:
        first, own = pl[3][-1][2], pl[3][-1][3]
        result.append((first[0] == 2 * own[0] and first[1] == own[1],
                       'join: player 1 on top, two below (%dx%d and %dx%d)' % (first + own)))
    result.append((re.search(r'PVS compare: .*, 3 views', log) is not None and pvs_clean(log),
                   'join: culling changes no pixel of the three views'))
    log = logs['stacked']
    p1 = [tuple(float(x) for x in m[:3]) for m in DEMO_VIEW_RE.findall(log)]
    p2 = SPLIT_RE.findall(log)
    result.append((len(p1) == 2 and len(p2) == 2, 'stacked: both players are logged at each screenshot'))
    if len(p1) == 2 and len(p2) == 2:
        a = [tuple(float(x) for x in m[1:4]) for m in p2]
        result.append((dist(p1[0], p1[1]) > 100 and dist(a[0], a[1]) < 8,
                       'the keyboard walks only the first player (%.0f and %.0f units)'
                       % (dist(p1[0], p1[1]), dist(a[0], a[1]))))
        result.append((int(p2[1][6]) < int(p2[0][6]), 'the trigger fires the second player\'s weapon (ammo %s -> %s)'
                       % (p2[0][6], p2[1][6])))
        shots = re.findall(r'\(signon \d+, health -?\d+, ammo (\d+)', log)
        result.append((len(shots) == 2 and shots[0] == shots[1], 'the first player does not fire'))
        w1, h1, w2, h2 = (int(x) for x in p2[0][7:11])
        result.append((w1 == w2 and h1 == h2 and w1 > h1 * 2, 'one above the other: two views of %dx%d' % (w1, h1)))
    return result


def split_frames(out_dir):
    """The two halves of a screenshot show different views once player 2 walked off"""
    from PIL import Image, ImageChops, ImageStat
    result = []
    for name, box in (('sides_2.png', 'lr'), ('stacked_2.png', 'tb')):
        path = os.path.join(out_dir, name)
        if not os.path.exists(path):
            result.append((False, '%s exists' % name))
            continue
        img = Image.open(path).convert('RGB')
        w, h = img.size
        if box == 'lr':
            a, b = img.crop((0, 0, w // 2, h)), img.crop((w - w // 2, 0, w, h))
        else:
            a, b = img.crop((0, 0, w, h // 2)), img.crop((0, h - h // 2, w, h))
        diff = sum(ImageStat.Stat(ImageChops.difference(a, b)).mean) / 3
        result.append((diff > 8, '%s: the two views differ (mean difference %.1f)' % (name, diff)))
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


def check_bots(logs):
    result = common_checks(logs, 'bhost') + common_checks(logs, 'bclient')
    h = logs['bhost']
    m = re.search(r'Navigation of "e1m1": (\d+) spots, (\d+) links', h)
    result.append((m is not None and int(m.group(1)) > 1000, 'E1M1 has bot navigation (%s spots)' %
                   (m.group(1) if m else 0)))
    joined = re.findall(r'Bot "(\w+)" joined as client', h)
    result.append((len(joined) == 3, 'three bots join (%s)' % ', '.join(joined)))
    result.append((re.search(r'Client \d+ connected', h) is not None, 'a network client joins with the bots'))
    lines = re.findall(r'Bots: (\w+ -?\d+ frags.*)', h)
    last = lines[-1] if lines else ''
    moved = [float(x) for x in re.findall(r'([\d.]+) units', last)]
    result.append((len(moved) == 3 and min(moved) > 1000, 'every bot walks the map (%s units)' %
                   ', '.join('%.0f' % x for x in moved)))
    frags = sum(int(x) for line in lines for x in re.findall(r'(-?\d+) frags', line))
    # A fight starting is logged; frags depend on who hits whom in the time
    # (both games with three bots count: under load one may see no fight)
    fights = len(re.findall(r'Bot "\w+" fights ', logs['bhost'] + logs.get('bloop', '')))
    result.append((frags != 0 or fights > 0 or 'fighting' in ' '.join(lines),
                   'the bots fight (%d fights, %d frags in the logs)' % (fights, frags)))
    shots = NET_SHOT_RE.findall(logs['bclient'])
    result.append((len(shots) == 1 and shots[0][0] == '4', 'the client plays with the bots'))
    # The browser's way: the listen server on loopback sockets, its own
    # player joining in-process
    h = logs['bloop']
    result += common_checks(logs, 'bloop')
    result.append(('Loopback socket on port 26000' in h and len(re.findall(r'Bot "(\w+)" joined', h)) == 3,
                   'bloop: three bots join a loopback listen server'))
    lines = re.findall(r'Bots: (\w+ -?\d+ frags.*)', h)
    moved = [float(x) for x in re.findall(r'([\d.]+) units', lines[-1] if lines else '')]
    # 22 s, and a bot killed starts counting again: only that each one moves
    result.append((len(moved) == 3 and min(moved) > 300, 'bloop: the bots walk the map (%s units)' %
                   ', '.join('%.0f' % x for x in moved)))
    shots = NET_SHOT_RE.findall(h)
    result.append((len(shots) == 1 and shots[0][0] == '4', 'bloop: the host plays with them over the loopback'))
    return result
