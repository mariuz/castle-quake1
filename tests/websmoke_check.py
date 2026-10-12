#!/usr/bin/env python3
"""Checks the web smoke test screenshots show the game, not a black or
blank canvas: python3 tests/websmoke_check.py <out dir>"""

import os
import sys

from PIL import Image, ImageStat

out_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
failed = False
for name in ('websmoke_1.png', 'websmoke_2.png'):
    path = os.path.join(out_dir, name)
    if not os.path.exists(path):
        print('FAIL %s is missing' % name)
        failed = True
        continue
    image = Image.open(path).convert('RGB')
    # The 3D view of the canvas, above the status bar
    w, h = image.size
    view = image.crop((0, 0, w, h * 3 // 4))
    stat = ImageStat.Stat(view)
    brightness = sum(stat.mean) / 3
    spread = sum(stat.stddev) / 3
    ok = brightness > 8 and spread > 8
    print('%s %s (brightness %.1f, spread %.1f)' % ('ok  ' if ok else 'FAIL', name, brightness, spread))
    failed = failed or not ok
sys.exit(1 if failed else 0)
