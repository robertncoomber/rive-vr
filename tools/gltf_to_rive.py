#!/usr/bin/env python3
"""Converts a single-mesh glTF binary (.glb) into Rive-loadable data.

Rive has no 3D importer, so geometry ships as base64 strings in Luau utility
modules (split into chunks) and textures ship as image assets.

Outputs into <out_dir>:
  mesh_chunk_<n>.luau  modules returning { data = <base64 string> }
  mesh_info.json       vertex/index counts, bounds, chunk count
  <slot>.png|jpg       the material's textures (baseColor, metalRough,
                       normal, emissive, occlusion), resized to --tex-size

Vertex layout (32 bytes): position f32x3, normal f32x3, uv f32x2.
Indices are uint16 (the mesh must have < 65536 vertices).
The first node that references the mesh supplies its transform.

Usage: gltf_to_rive.py model.glb out_dir [--tex-size 1024] [--chunk-kb 96]
"""

import argparse
import base64
import json
import math
import os
import struct
import subprocess
import sys

COMPONENT_FORMAT = {5120: 'b', 5121: 'B', 5122: 'h', 5123: 'H', 5125: 'I', 5126: 'f'}
TYPE_COUNT = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}


def read_glb(path):
    data = open(path, 'rb').read()
    magic, version, _length = struct.unpack_from('<III', data, 0)
    if magic != 0x46546C67 or version != 2:
        sys.exit('not a glTF 2.0 binary')
    offset = 12
    gltf, binary = None, b''
    while offset < len(data):
        chunk_len, chunk_type = struct.unpack_from('<II', data, offset)
        chunk = data[offset + 8: offset + 8 + chunk_len]
        if chunk_type == 0x4E4F534A:
            gltf = json.loads(chunk)
        elif chunk_type == 0x004E4942:
            binary = chunk
        offset += 8 + chunk_len
    return gltf, binary


def read_accessor(gltf, binary, index):
    acc = gltf['accessors'][index]
    view = gltf['bufferViews'][acc['bufferView']]
    fmt = COMPONENT_FORMAT[acc['componentType']]
    count = TYPE_COUNT[acc['type']]
    size = struct.calcsize(fmt)
    stride = view.get('byteStride', size * count)
    base = view.get('byteOffset', 0) + acc.get('byteOffset', 0)
    out = []
    for i in range(acc['count']):
        values = struct.unpack_from('<' + fmt * count, binary, base + i * stride)
        out.append(values if count > 1 else values[0])
    return out


def quat_matrix(q):
    x, y, z, w = q
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ]


def node_transform(node):
    """Returns (3x3 linear part, translation) for one node (TRS or matrix)."""
    if 'matrix' in node:
        m = node['matrix']  # column-major
        return [[m[0], m[4], m[8]], [m[1], m[5], m[9]], [m[2], m[6], m[10]]], m[12:15]
    r = quat_matrix(node.get('rotation', [0, 0, 0, 1]))
    s = node.get('scale', [1, 1, 1])
    lin = [[r[i][j] * s[j] for j in range(3)] for i in range(3)]
    return lin, node.get('translation', [0, 0, 0])


def apply(lin, t, v):
    return [sum(lin[i][j] * v[j] for j in range(3)) + t[i] for i in range(3)]


def normalize(v):
    n = math.sqrt(sum(c * c for c in v)) or 1.0
    return [c / n for c in v]


def export_textures(gltf, binary, material, out_dir, size):
    pbr = material.get('pbrMetallicRoughness', {})
    slots = {
        'baseColor': pbr.get('baseColorTexture'),
        'metalRough': pbr.get('metallicRoughnessTexture'),
        'normal': material.get('normalTexture'),
        'emissive': material.get('emissiveTexture'),
        'occlusion': material.get('occlusionTexture'),
    }
    written = {}
    for slot, ref in slots.items():
        if ref is None:
            continue
        image = gltf['images'][gltf['textures'][ref['index']]['source']]
        view = gltf['bufferViews'][image['bufferView']]
        start = view.get('byteOffset', 0)
        ext = 'png' if image.get('mimeType') == 'image/png' else 'jpg'
        path = os.path.join(out_dir, f'{slot}.{ext}')
        with open(path, 'wb') as f:
            f.write(binary[start:start + view['byteLength']])
        subprocess.run(['sips', '-z', str(size), str(size), path],
                       check=True, capture_output=True)
        written[slot] = os.path.basename(path)
    return written


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('glb')
    parser.add_argument('out_dir')
    parser.add_argument('--tex-size', type=int, default=1024)
    parser.add_argument('--chunk-kb', type=int, default=96)
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    gltf, binary = read_glb(args.glb)
    mesh_index = 0
    prim = gltf['meshes'][mesh_index]['primitives'][0]
    node = next((n for n in gltf.get('nodes', []) if n.get('mesh') == mesh_index), {})
    lin, t = node_transform(node)

    attrs = prim['attributes']
    positions = [apply(lin, t, p) for p in read_accessor(gltf, binary, attrs['POSITION'])]
    normals = [normalize(apply(lin, [0, 0, 0], n))
               for n in read_accessor(gltf, binary, attrs['NORMAL'])]
    uvs = read_accessor(gltf, binary, attrs['TEXCOORD_0'])
    indices = read_accessor(gltf, binary, prim['indices'])
    if len(positions) >= 65536:
        sys.exit('mesh has too many vertices for uint16 indices')

    blob = bytearray()
    for p, n, uv in zip(positions, normals, uvs):
        blob += struct.pack('<8f', *p, *n, *uv)
    vertex_bytes = len(blob)
    blob += struct.pack(f'<{len(indices)}H', *indices)
    if len(blob) % 4:
        blob += b'\0' * (4 - len(blob) % 4)

    encoded = base64.b64encode(bytes(blob)).decode('ascii')
    chunk_chars = args.chunk_kb * 1024 // 4 * 4
    chunks = [encoded[i:i + chunk_chars] for i in range(0, len(encoded), chunk_chars)]
    for i, chunk in enumerate(chunks, 1):
        with open(os.path.join(args.out_dir, f'mesh_chunk_{i}.luau'), 'w') as f:
            f.write(f"-- Generated by tools/gltf_to_rive.py: base64 mesh data, part {i} of {len(chunks)}.\n")
            # Rive modules must return a table or function, not a bare string.
            f.write(f'return {{ data = "{chunk}" }}\n')

    lo = [min(p[i] for p in positions) for i in range(3)]
    hi = [max(p[i] for p in positions) for i in range(3)]
    material = gltf['materials'][prim.get('material', 0)]
    info = {
        'source': os.path.basename(args.glb),
        'vertexCount': len(positions),
        'indexCount': len(indices),
        'vertexBytes': vertex_bytes,
        'totalBytes': len(blob),
        'chunks': len(chunks),
        'boundsMin': lo,
        'boundsMax': hi,
        'textures': export_textures(gltf, binary, material, args.out_dir, args.tex_size),
        'emissiveFactor': material.get('emissiveFactor', [0, 0, 0]),
    }
    with open(os.path.join(args.out_dir, 'mesh_info.json'), 'w') as f:
        json.dump(info, f, indent=2)
    print(json.dumps(info, indent=2))


if __name__ == '__main__':
    main()
