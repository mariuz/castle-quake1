#!/usr/bin/env python3
"""Rewrite a BSP29 map in the BSP2 and 2PSB formats and pack the results
(and the .lit / worldspawn helpers of the colored light and fog tests).

The bundled paks have no BSP2 map, so the tests convert one: the same
level in the larger formats must load and render exactly like the
original.

    python3 tests/bsp2convert.py e1m1 <out dir> [pak ...]

writes <out dir>/pak0.pak with maps/<map>_bsp2.bsp and maps/<map>_2psb.bsp,
to load with -game <out dir>.
"""

import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PAKS = [os.path.join(ROOT, 'data', 'paks', name)
                for name in ('pak0.pak', 'pak1.pak', 'quake1_demo.pak')]

LUMP_NODES, LUMP_FACES, LUMP_CLIPNODES, LUMP_LEAVES, LUMP_MARKSURFACES, LUMP_EDGES = 5, 7, 9, 10, 11, 12
LUMP_VERTICES = 3


def read_pak_file(paks, name):
    for path in paks:
        if not os.path.exists(path):
            continue
        with open(path, 'rb') as f:
            magic, offset, length = struct.unpack('<4sii', f.read(12))
            f.seek(offset)
            for _ in range(length // 64):
                entry, pos, size = struct.unpack('<56sii', f.read(64))
                if entry.split(b'\0')[0].decode('latin1') == name:
                    f.seek(pos)
                    return f.read(size)
    return None


def records(data, offset, length, fmt):
    size = struct.calcsize(fmt)
    return [struct.unpack_from(fmt, data, offset + i * size) for i in range(length // size)]


def convert(data, kind, vertex_offset=0):
    """kind: 'BSP2' (float node / leaf bounds) or '2PSB' (short bounds);
    vertex_offset unused vertices go before the map's own, so every edge
    names a vertex above that number (BSP2 maps of more than 65535
    vertices)"""
    version = struct.unpack_from('<i', data, 0)[0]
    if version != 29:
        raise ValueError('not a BSP29 map (version %d)' % version)
    lumps = [struct.unpack_from('<ii', data, 4 + i * 8) for i in range(15)]
    out = {}

    nodes = records(data, *lumps[LUMP_NODES], '<i2H6h2H')
    node_count = len(nodes)
    buf = b''
    for plane, c0, c1, *rest in nodes:
        bounds, first, num = rest[:6], rest[6], rest[7]
        children = [c if c < node_count else c - 65536 for c in (c0, c1)]
        if kind == 'BSP2':
            buf += struct.pack('<i2i6f2I', plane, *children, *[float(b) for b in bounds], first, num)
        else:
            buf += struct.pack('<i2i6h2I', plane, *children, *bounds, first, num)
    out[LUMP_NODES] = buf

    buf = b''
    for contents, visofs, *rest in records(data, *lumps[LUMP_LEAVES], '<ii6h2H4B'):
        bounds, first, num, ambient = rest[:6], rest[6], rest[7], rest[8:]
        if kind == 'BSP2':
            buf += struct.pack('<ii6f2I4B', contents, visofs, *[float(b) for b in bounds], first, num, *ambient)
        else:
            buf += struct.pack('<ii6h2I4B', contents, visofs, *bounds, first, num, *ambient)
    out[LUMP_LEAVES] = buf

    clipnodes = records(data, *lumps[LUMP_CLIPNODES], '<i2H')
    buf = b''
    for plane, c0, c1 in clipnodes:
        children = [c if c < len(clipnodes) else c - 65536 for c in (c0, c1)]
        buf += struct.pack('<i2i', plane, *children)
    out[LUMP_CLIPNODES] = buf

    out[LUMP_EDGES] = b''.join(struct.pack('<2I', e[0] + vertex_offset, e[1] + vertex_offset)
                               for e in records(data, *lumps[LUMP_EDGES], '<2H'))
    if vertex_offset:
        offset, length = lumps[LUMP_VERTICES]
        out[LUMP_VERTICES] = struct.pack('<3f', 0, 0, 0) * vertex_offset + data[offset:offset + length]
    out[LUMP_MARKSURFACES] = b''.join(struct.pack('<I', *m)
                                      for m in records(data, *lumps[LUMP_MARKSURFACES], '<H'))
    buf = b''
    for plane, side, first_edge, num_edges, texinfo, s0, s1, s2, s3, lightofs in \
            records(data, *lumps[LUMP_FACES], '<Hhihh4Bi'):
        buf += struct.pack('<iiiii4Bi', plane, side, first_edge, num_edges, texinfo, s0, s1, s2, s3, lightofs)
    out[LUMP_FACES] = buf

    body = b''
    directory = []
    header_size = 4 + 15 * 8
    for i, (offset, length) in enumerate(lumps):
        chunk = out.get(i, data[offset:offset + length])
        directory.append((header_size + len(body), len(chunk)))
        body += chunk + b'\0' * (-len(chunk) % 4)
    header = kind.encode('ascii') + b''.join(struct.pack('<ii', *d) for d in directory)
    return header + body


def make_lit(data, tint=(1.0, 1.0, 1.0)):
    """A .lit (QLIT version 1) for a BSP29 map: its own lightmaps as RGB,
    each byte times tint (1, 1, 1 gives the gray light unchanged)."""
    offset, length = struct.unpack_from('<ii', data, 4 + 8 * 8)
    gray = data[offset:offset + length]
    rgb = bytearray(3 * len(gray))
    for i, v in enumerate(gray):
        rgb[3 * i] = min(255, int(v * tint[0] + 0.5))
        rgb[3 * i + 1] = min(255, int(v * tint[1] + 0.5))
        rgb[3 * i + 2] = min(255, int(v * tint[2] + 0.5))
    return b'QLIT' + struct.pack('<i', 1) + bytes(rgb)


def set_worldspawn_key(data, key, value):
    """The map with "key" "value" added to its worldspawn (the entity lump
    moved to the end of the file)."""
    offset, length = struct.unpack_from('<ii', data, 4)
    text = data[offset:offset + length].rstrip(b'\0')
    brace = text.index(b'{')
    text = text[:brace + 1] + b'\n"%s" "%s"' % (key.encode(), value.encode()) + text[brace + 1:] + b'\0'
    body = bytearray(data) + b'\0' * (-len(data) % 4)
    new_offset = len(body)
    body += text
    struct.pack_into('<ii', body, 4, new_offset, len(text))
    return bytes(body)


def translate(data, offset):
    """A BSP29 map moved by offset (x, y, z, whole units): vertices, planes,
    node, leaf and model bounds, texture offsets (so textures and lightmaps
    stay where they were) and the entity origins; the visibility and the
    lightmaps are unchanged."""
    import re
    version = struct.unpack_from('<i', data, 0)[0]
    if version != 29:
        raise ValueError('not a BSP29 map (version %d)' % version)
    ox, oy, oz = offset
    lumps = [struct.unpack_from('<ii', data, 4 + i * 8) for i in range(15)]
    out = bytearray(data)

    def each(lump, fmt):
        position, length = lumps[lump]
        size = struct.calcsize(fmt)
        for i in range(length // size):
            yield position + i * size, struct.unpack_from(fmt, data, position + i * size)

    for pos, (nx, ny, nz, dist, kind) in each(1, '<4fi'):          # planes
        struct.pack_into('<4fi', out, pos, nx, ny, nz, dist + nx * ox + ny * oy + nz * oz, kind)
    for pos, (x, y, z) in each(3, '<3f'):                          # vertices
        struct.pack_into('<3f', out, pos, x + ox, y + oy, z + oz)
    for pos, rec in each(5, '<i2H6h2H'):                           # nodes
        b = rec[3:9]
        struct.pack_into('<6h', out, pos + 8, b[0] + ox, b[1] + oy, b[2] + oz, b[3] + ox, b[4] + oy, b[5] + oz)
    for pos, rec in each(6, '<8f2i'):                              # texinfo
        s0, s1, s2, s3, t0, t1, t2, t3 = rec[:8]
        struct.pack_into('<8f', out, pos, s0, s1, s2, s3 - (s0 * ox + s1 * oy + s2 * oz),
                         t0, t1, t2, t3 - (t0 * ox + t1 * oy + t2 * oz))
    for pos, rec in each(10, '<ii6h2H4B'):                         # leaves
        b = rec[2:8]
        struct.pack_into('<6h', out, pos + 8, b[0] + ox, b[1] + oy, b[2] + oz, b[3] + ox, b[4] + oy, b[5] + oz)
    for pos, rec in each(14, '<9f7i'):                             # models (the brush entities keep origin 0)
        m = rec[:6]
        struct.pack_into('<6f', out, pos, m[0] + ox, m[1] + oy, m[2] + oz, m[3] + ox, m[4] + oy, m[5] + oz)

    position, length = lumps[0]
    text = data[position:position + length].rstrip(b'\0').decode('latin1')

    def move(m):
        x, y, z = (float(v) for v in m.group(1).split())
        return '"origin" "%g %g %g"' % (x + ox, y + oy, z + oz)
    text = re.sub(r'"origin"\s+"([^"]*)"', move, text)
    body = bytes(out) + b'\0' * (-len(out) % 4)
    entities = text.encode('latin1') + b'\0'
    result = bytearray(body + entities)
    struct.pack_into('<ii', result, 4, len(body), len(entities))
    return bytes(result)


def write_pak(path, files):
    directory = b''
    body = b''
    for name, data in files:
        directory += struct.pack('<56sii', name.encode('latin1'), 12 + len(body), len(data))
        body += data
    with open(path, 'wb') as f:
        f.write(struct.pack('<4sii', b'PACK', 12 + len(body), len(directory)))
        f.write(body)
        f.write(directory)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    name, out_dir = sys.argv[1], sys.argv[2]
    paks = sys.argv[3:] or DEFAULT_PAKS
    data = read_pak_file(paks, 'maps/%s.bsp' % name)
    if data is None:
        print('maps/%s.bsp not found' % name)
        return 1
    os.makedirs(out_dir, exist_ok=True)
    write_pak(os.path.join(out_dir, 'pak0.pak'),
              [('maps/%s_bsp2.bsp' % name, convert(data, 'BSP2')),
               ('maps/%s_2psb.bsp' % name, convert(data, '2PSB'))])
    print('wrote %s with maps/%s_bsp2.bsp and maps/%s_2psb.bsp' % (os.path.join(out_dir, 'pak0.pak'), name, name))
    return 0


if __name__ == '__main__':
    sys.exit(main())
