#!/usr/bin/env python3
"""Rewrite a BSP29 map in the BSP2 and 2PSB formats and pack the results.

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


def convert(data, kind):
    """kind: 'BSP2' (float node / leaf bounds) or '2PSB' (short bounds)"""
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

    out[LUMP_EDGES] = b''.join(struct.pack('<2I', *e) for e in records(data, *lumps[LUMP_EDGES], '<2H'))
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
