#!/usr/bin/env python3
"""cook_foliage.py: turns the Sketchfab conifers and grass in
assets_src/sketchfab into nitro-velocity's trees and grass. fetch_assets.py
runs it; by hand:

    python3 tools/cook_foliage.py

Writes assets/foliage/:

  trees.glb  the Coniferous Forest Assets Pack's fir, pine and noble fir,
             each standing on the origin in meters, as nodes named
             "<tree> <lod> bark" and "<tree> <lod> leaves" for three levels
             of detail: 0 the model as it is; 1 its needles with the trunk
             as a 12-sided cone (the branches' bark left out: the needles
             hide them); 2 the biggest half of its needle cards on a
             6-sided cone. Materials "Bark" and "Leaves" (one each: the
             pack's trees share their textures), turned from
             specular-glossiness into metallic-roughness.
  grass.glb  the Realistic Grass 06 scan cut into four clumps ("grass 0…3"),
             each on the origin, about 0.6 m across and 0.35 m high, and a
             fifth of each's tallest blades for far off ("grass 0 far"…),
             in material "Grass" (its blade texture stretched to fill the
             scan's cards, so it lasts at a distance).

Pure Python, like cook.py (whose reading and baking it uses).
"""
import json, math, os, struct, sys, zlib
from array import array

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cook

OUT = os.path.join(cook.GAME, 'assets', 'foliage')

TREES = [('fir', 'firtree_0'), ('pine', 'pinetree_1'), ('noblefir', 'noblefirtree_2')]

# ---------------------------------------------------------------- meshes

class Mesh:
    def __init__(s):
        s.pos, s.nrm, s.uv, s.idx = [], [], [], []

    def vert(s, p, n, uv):
        s.pos += p; s.nrm += n; s.uv += uv
        return len(s.pos) // 3 - 1

    def tris(s):
        return len(s.idx) // 3

def from_pieces(pieces, shift, scale, keep=None):
    """The pieces' triangles (keep(piece, t) picks some) moved by -shift
    and scaled, as one mesh."""
    m = Mesh()
    for p in pieces:
        remap = {}
        for t in range(0, len(p.idx) - 2, 3):
            if keep and not keep(p, t): continue
            for v in p.idx[t:t + 3]:
                k = remap.get(v)
                if k is None:
                    x, y, z = p.pos[3 * v:3 * v + 3]
                    n = p.nrm[3 * v:3 * v + 3] if p.nrm else [0, 1, 0]
                    uv = p.uv0[2 * v:2 * v + 2] if p.uv0 else [0, 0]
                    k = m.vert([(x - shift[0]) * scale, (y - shift[1]) * scale, (z - shift[2]) * scale], n, uv)
                    remap[v] = k
                m.idx.append(k)
    return m

def cone(base_r, top_r, height, sides):
    """A trunk: a tapered tube, its bark wrapped round once every 1.5 m up."""
    m = Mesh()
    rings = 4
    for j in range(rings + 1):
        f = j / rings
        y = height * f
        r = base_r + (top_r - base_r) * f
        for i in range(sides + 1):
            a = 2 * math.pi * i / sides
            c, s = math.cos(a), math.sin(a)
            m.vert([c * r, y, s * r], [c, (base_r - top_r) / height, s], [i / sides, y / 1.5])
    w = sides + 1
    for j in range(rings):
        for i in range(sides):
            a, b, c, d = j * w + i, j * w + i + 1, (j + 1) * w + i, (j + 1) * w + i + 1
            m.idx += [a, c, b, b, c, d]
    return m

def components(p):
    """Each connected run of triangles (a needle card) in a piece: lists of
    triangle starts."""
    parent = list(range(len(p.pos) // 3))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]; a = parent[a]
        return a
    for t in range(0, len(p.idx) - 2, 3):
        a, b, c = (find(v) for v in p.idx[t:t + 3])
        parent[b] = a; parent[c] = a
    groups = {}
    for t in range(0, len(p.idx) - 2, 3):
        groups.setdefault(find(p.idx[t]), []).append(t)
    return list(groups.values())

def area(p, ts):
    s = 0.0
    for t in ts:
        a, b, c = (p.pos[3 * v:3 * v + 3] for v in p.idx[t:t + 3])
        u = [b[k] - a[k] for k in range(3)]; w = [c[k] - a[k] for k in range(3)]
        x = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]]
        s += math.sqrt(sum(v * v for v in x)) / 2
    return s

# ---------------------------------------------------------------- PNG

def png_read(d):
    """A PNG's width, height, color type and unfiltered pixels."""
    w,h,bd,ct=struct.unpack('>IIBB',d[16:26]); o=8; idat=b''; plte=None; trns=None
    while o<len(d):
        ln=struct.unpack('>I',d[o:o+4])[0]; t=d[o+4:o+8]
        if t==b'IDAT': idat+=d[o+8:o+8+ln]
        if t==b'PLTE': plte=d[o+8:o+8+ln]
        o+=12+ln
    bpp={6:4,2:3,0:1,3:1,4:2}[ct]; raw=zlib.decompress(idat); stride=w*bpp; out=bytearray(); prev=bytearray(stride); i=0
    for y in range(h):
        f=raw[i]; i+=1; line=bytearray(raw[i:i+stride]); i+=stride
        if f:
            for x in range(stride):
                a=line[x-bpp] if x>=bpp else 0; up=prev[x]; c=prev[x-bpp] if x>=bpp else 0
                if f==1: line[x]=(line[x]+a)&255
                elif f==2: line[x]=(line[x]+up)&255
                elif f==3: line[x]=(line[x]+(a+up)//2)&255
                elif f==4:
                    p=a+up-c; pa,pb,pc=abs(p-a),abs(p-up),abs(p-c)
                    line[x]=(line[x]+(a if pa<=pb and pa<=pc else up if pb<=pc else c))&255
        out+=line; prev=line
    return w,h,ct,bytes(out)
def png_rgba(w,h,px):
    """RGBA pixels as a PNG."""
    raw=b''.join(b'\x00'+px[y*w*4:(y+1)*w*4] for y in range(h))
    def chunk(t,d): return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw,9))+chunk(b'IEND',b'')

def fatten(d, u0=0.32, u1=0.70):
    """The grass blade texture made to last at a distance. The scan's cards
    map u0…u1 of it, but the blade is a thin stripe in the middle, so the
    smaller mip levels the renderer makes fade it to nothing: the blade is
    stretched sideways to fill u0…u1 (each card then is a blade), and its
    color spread into what's still clear (so edges don't darken)."""
    w, h, ct, px = png_read(d)
    cols = [x for x in range(w) if any(px[(y * w + x) * 4 + 3] > 100 for y in range(0, h, 4))]
    g0, g1 = min(cols), max(cols) + 1
    s0, s1 = int(u0 * w), int(u1 * w) + 1
    out = bytearray(w * h * 4)
    for y in range(h):
        row = y * w * 4
        for x in range(s0, s1):
            sx = g0 + (x - s0) * (g1 - g0) // (s1 - s0)
            out[row + x * 4:row + x * 4 + 4] = px[row + sx * 4:row + sx * 4 + 4]
    # Color into what's clear, from the nearest opaque pixel in the row.
    for y in range(h):
        row = y * w * 4
        last = None
        for x in list(range(w)) + list(range(w - 1, -1, -1)):
            i = row + x * 4
            if out[i + 3] > 100: last = out[i:i + 3]
            elif last is not None and out[i + 3] < 8: out[i:i + 3] = last
    return png_rgba(w, h, bytes(out))

# ---------------------------------------------------------------- writing

class Out:
    def __init__(s, src, srcbin):
        s.src, s.srcbin = src, srcbin
        s.data = bytearray(); s.views = []; s.accessors = []; s.meshes = []; s.nodes = []
        s.images = {}; s.textures = []; s.materials = []

    def view(s, b, target=None):
        while len(s.data) % 4: s.data.append(0)
        v = {'buffer': 0, 'byteOffset': len(s.data), 'byteLength': len(b)}
        if target: v['target'] = target
        s.data += b; s.views.append(v)
        return len(s.views) - 1

    def acc(s, vals, comp, typ, target, minmax=False):
        b = array({5126: 'f', 5125: 'I', 5123: 'H'}[comp], vals).tobytes()
        a = {'bufferView': s.view(b, target), 'componentType': comp, 'count': len(vals) // cook.WIDTH[typ], 'type': typ}
        if minmax:
            w = cook.WIDTH[typ]
            a['min'] = [min(vals[j::w]) for j in range(w)]; a['max'] = [max(vals[j::w]) for j in range(w)]
        s.accessors.append(a)
        return len(s.accessors) - 1

    def texture(s, src_tex, change=None):
        """A texture of the source's, its image carried over once (through
        change, when given)."""
        img = s.src['textures'][src_tex]['source']
        if img not in s.images:
            im = s.src['images'][img]
            bv = s.src['bufferViews'][im['bufferView']]; o = bv.get('byteOffset', 0)
            data = s.srcbin[o:o + bv['byteLength']]
            if change: data = change(data)
            s.images[img] = (len(s.images), {'bufferView': s.view(data), 'mimeType': im.get('mimeType', 'image/png')})
        s.textures.append({'source': s.images[img][0], 'sampler': 0})
        return len(s.textures) - 1

    def material(s, name, src_mat, alpha=None, cutoff=0.5, rough=None, change=None):
        """A source specular-glossiness material as metallic-roughness."""
        m = s.src['materials'][src_mat]
        sg = m.get('extensions', {}).get('KHR_materials_pbrSpecularGlossiness', {})
        pbr = {'baseColorFactor': sg.get('diffuseFactor', [1, 1, 1, 1]), 'metallicFactor': 0.0,
               'roughnessFactor': rough if rough is not None else 1 - sg.get('glossinessFactor', 0.5)}
        if 'diffuseTexture' in sg: pbr['baseColorTexture'] = {'index': s.texture(sg['diffuseTexture']['index'], change)}
        out = {'name': name, 'pbrMetallicRoughness': pbr, 'doubleSided': True}
        if 'normalTexture' in m: out['normalTexture'] = {'index': s.texture(m['normalTexture']['index'])}
        if alpha: out['alphaMode'] = alpha
        if alpha == 'MASK': out['alphaCutoff'] = cutoff
        s.materials.append(out)
        return len(s.materials) - 1

    def node(s, name, mesh, mat):
        if not mesh.idx: return
        prim = {'attributes': {'POSITION': s.acc(mesh.pos, 5126, 'VEC3', 34962, True),
                               'NORMAL': s.acc(mesh.nrm, 5126, 'VEC3', 34962),
                               'TEXCOORD_0': s.acc(mesh.uv, 5126, 'VEC2', 34962)},
                'indices': s.acc(mesh.idx, 5123 if len(mesh.pos) // 3 < 65536 else 5125, 'SCALAR', 34963),
                'material': mat, 'mode': 4}
        s.meshes.append({'name': name, 'primitives': [prim]})
        s.nodes.append({'name': name, 'mesh': len(s.meshes) - 1})

    def write(s, path):
        images = [im for _, im in sorted(s.images.values(), key=lambda x: x[0])]
        out = {'asset': {'version': '2.0', 'generator': 'nitro-velocity cook_foliage.py'}, 'scene': 0,
               'scenes': [{'nodes': list(range(len(s.nodes)))}], 'nodes': s.nodes, 'meshes': s.meshes,
               'materials': s.materials, 'textures': s.textures, 'images': images,
               'samplers': [{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497}],
               'accessors': s.accessors, 'bufferViews': s.views, 'buffers': [{'byteLength': 0}]}
        while len(s.data) % 4: s.data.append(0)
        out['buffers'][0]['byteLength'] = len(s.data)
        j = json.dumps(out, separators=(',', ':')).encode()
        while len(j) % 4: j += b' '
        with open(path, 'wb') as f:
            f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(j) + 8 + len(s.data)))
            f.write(struct.pack('<II', len(j), 0x4E4F534A)); f.write(j)
            f.write(struct.pack('<II', len(s.data), 0x004E4942)); f.write(s.data)

# ---------------------------------------------------------------- the cook

def trees():
    js, b = cook.read_glb(os.path.join(cook.SRC, 'conifer_pack', 'conifer_pack.glb'))
    ps = cook.pieces(js, b)
    mats = js['materials']
    parent = {}
    for i, n in enumerate(js['nodes']):
        for c in n.get('children', []): parent[c] = i
    out = Out(js, b)
    bark_src = next(i for i, m in enumerate(mats) if m['name'] == 'BarkMat')
    leaf_src = next(i for i, m in enumerate(mats) if m['name'] == 'BranchMat')
    bark = out.material('Bark', bark_src, rough=0.92)
    leaves = out.material('Leaves', leaf_src, alpha='MASK', cutoff=0.4, rough=0.8)
    # Which tree each piece is of: by its node's parent's name.
    names = {}
    for i, n in enumerate(js['nodes']):
        if 'mesh' in n:
            names[(n.get('name') or '').lower()] = (js['nodes'][parent[i]].get('name') or '').lower()
    for tag, node in TREES:
        mine = [p for p in ps if names.get(p.node.split(' ')[0]) == node]
        barks = [p for p in mine if mats[p.mat]['name'].startswith('Bark')]
        cards = [p for p in mine if mats[p.mat]['name'].startswith('Branch')]
        # Stands on the trunk's foot.
        lo_y = min(min(p.pos[1::3]) for p in barks)
        foot = [(p.pos[3 * v], p.pos[3 * v + 2]) for p in barks for v in range(len(p.pos) // 3) if p.pos[3 * v + 1] < lo_y + 0.4]
        cx = sum(x for x, _ in foot) / len(foot); cz = sum(z for _, z in foot) / len(foot)
        shift = (cx, lo_y, cz)
        height = max(max(p.pos[1::3]) for p in mine) - lo_y
        # The trunk's radius at its foot, from where most of the bark there is.
        rs = sorted(math.hypot(x - cx, z - cz) for x, z in foot)
        r0 = rs[len(rs) * 3 // 4]
        out.node('%s 0 bark' % tag, from_pieces(barks, shift, 1), bark)
        out.node('%s 0 leaves' % tag, from_pieces(cards, shift, 1), leaves)
        out.node('%s 1 bark' % tag, cone(r0, r0 * 0.15, height * 0.82, 12), bark)
        out.node('%s 1 leaves' % tag, from_pieces(cards, shift, 1), leaves)
        # The biggest half of the needle cards (by area) far off.
        keep = set()
        for p in cards:
            groups = sorted(components(p), key=lambda g: -area(p, g))
            for g in groups[:max(1, len(groups) // 2)]:
                for t in g: keep.add((id(p), t))
        far = from_pieces(cards, shift, 1, keep=lambda p, t: (id(p), t) in keep)
        out.node('%s 2 bark' % tag, cone(r0, r0 * 0.15, height * 0.7, 6), bark)
        out.node('%s 2 leaves' % tag, far, leaves)
        n0 = sum(len(p.idx) // 3 for p in mine)
        print('%-9s %.1f m tall, trunk %.2f m across; triangles %d, %d, %d' % (
            tag, height, 2 * r0, n0, from_pieces(cards, shift, 1).tris() + cone(r0, 0, 1, 12).tris(), far.tris() + cone(r0, 0, 1, 6).tris()))
    out.write(os.path.join(OUT, 'trees.glb'))

def grass():
    js, b = cook.read_glb(os.path.join(cook.SRC, 'grass06', 'grass06.glb'))
    ps = cook.pieces(js, b)
    out = Out(js, b)
    mat = out.material('Grass', 0, alpha='MASK', cutoff=0.4, rough=0.85, change=fatten)
    p = ps[0]
    xs, zs, ys = p.pos[0::3], p.pos[2::3], p.pos[1::3]
    cx, cz = (min(xs) + max(xs)) / 2, (min(zs) + max(zs)) / 2
    ground = sorted(ys)[len(ys) // 20]
    top = max(ys)
    scale = 0.35 / (top - ground)
    # Four clumps: the scan's quarters, each moved onto the origin.
    for k in range(4):
        qx = 1 if k & 1 else -1; qz = 1 if k & 2 else -1
        def keep(pp, t, qx=qx, qz=qz):
            v = pp.idx[t:t + 3]
            mx = sum(pp.pos[3 * i] for i in v) / 3 - cx; mz = sum(pp.pos[3 * i + 2] for i in v) / 3 - cz
            return (mx > 0) == (qx > 0) and (mz > 0) == (qz > 0)
        part = from_pieces([p], (0, 0, 0), 1, keep=keep)
        # Centered on its own middle, standing on the ground.
        px, pz = part.pos[0::3], part.pos[2::3]
        mx, mz = (min(px) + max(px)) / 2, (min(pz) + max(pz)) / 2
        m = Mesh()
        for i in range(len(part.pos) // 3):
            x, y, z = part.pos[3 * i:3 * i + 3]
            m.vert([(x - mx) * scale, max(-0.05, (y - ground) * scale), (z - mz) * scale], part.nrm[3 * i:3 * i + 3], part.uv[2 * i:2 * i + 2])
        m.idx = part.idx
        out.node('grass %d' % k, m, mat)
        # Far off: the biggest third of its blades.
        blades = components(m)
        tall = sorted(blades, key=lambda g: -max(m.pos[3 * v + 1] for t in g for v in m.idx[t:t + 3]))
        far = Mesh()
        far.pos, far.nrm, far.uv = m.pos, m.nrm, m.uv
        for g in tall[:max(1, len(tall) // 5)]:
            for t in g: far.idx += m.idx[t:t + 3]
        out.node('grass %d far' % k, far, mat)
        print('grass %d    %.2f m across, %d triangles (%d far: %d blades of %d)' % (k, (max(px) - min(px)) * scale, m.tris(), far.tris(), max(1, len(tall) // 5), len(tall)))
    out.write(os.path.join(OUT, 'grass.glb'))

if __name__ == '__main__':
    os.makedirs(OUT, exist_ok=True)
    trees()
    grass()
