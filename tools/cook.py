#!/usr/bin/env python3
"""cook.py: turns the Sketchfab cars in assets_src/sketchfab into
nitro-velocity's cars. fetch_assets.py runs it; by hand:

    python3 tools/cook.py [car ...]

Each source GLB is baked into the shape look.CarModel reads (the shape
Khronos' Car Concept had): meters, facing +Z, +Y up, +X the car's left, the
ground at y = 0 and the origin halfway between the axles; the body as one
node; the cabin as nodes named "Interior…"; each wheel a node "Wheel FL/FR/
RL/RR" at its hub, its rim, tire and disc under it, and its caliper under it
named "…BrakePad…" (it steers but doesn't roll). Wheels are split out by
triangle (some cars have all four in one mesh), by which corner they're in.
Materials are renamed to what look matches on: "Paint 1 …" the body's paint,
"Brakelight", and see-through ones left as glass. It writes
assets/cars/<id>/car.glb and, for race,
data/cars.json: each car's name, model, credit, and its build measured off
the model (hubs, tire radii, body size).

Pure Python (no numpy), so it runs anywhere: a car takes a few seconds.
"""
import json, math, os, struct, sys
from array import array

GAME = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SRC = os.path.join(GAME, 'assets_src', 'sketchfab')

# What each car is and how to read it. Patterns are lowercase substrings of
# a part's node or material name ("node:" or "mat:" picks one).
CARS = [
    dict(id='porsche-gt3rs', src='porsche_gt3rs', name='Porsche 911 GT3 RS', year=2023,
         uid='e738eae819c34d19a31dd066c45e0f3d', author='BlackSnow02', license='CC BY 4.0',
         length=4.57, front='+z', mass=1450, power=1.03, drive='rear', bias=-0.2,
         wheel=['mat:wheels_chrome_1', 'mat:gt3rs_black', 'mat:scene_-_root.002', 'mat:amdb11_'],
         caliper=['mat:amdb11_caliper'],
         paint=['mat:twixer_992_carpaint.003'],
         brakelight=['mat:twixer_992_brakelight_1.002'],
         interior=['mat:_id0', 'mat:leather', 'mat:carpet', 'mat:seat', 'mat:gauges', 'mat:int_chrome', 'mat:stitch',
                   'mat:fabric', 'mat:speakers', 'mat:dash_clock', 'mat:gps', 'mat:interior_d', 'node:seat', 'node:dash',
                   'node:pedal', 'node:shifter', 'node:steer', 'node:doorpanel', 'node:stalk'],
         drop=[]),
    dict(id='nissan-gtr', src='nissan_gtr', name='Nissan GT-R (R35)', year=2017,
         uid='7b142ea3376e4811a326256c59bbc7a2', author='BlackSnow02', license='CC BY 4.0',
         length=4.71, front='+z', mass=1560, power=1.1, drive='all', bias=-0.08,
         wheel=['mat:r35_wheel_05a', 'mat:scene_-_root.002', 'mat:amdb11_'],
         caliper=['mat:amdb11_caliper'],
         paint=['mat:r35_paint'],
         brakelight=[],
         interior=['mat:r35_interior', 'mat:r35_leather', 'mat:r35_steeringwheel', 'mat:r35_gauges', 'mat:r35_carpet',
                   'mat:r35_cloth', 'mat:r35_display', 'mat:r35_screen', 'mat:gtr_interior', 'node:seat', 'node:dash',
                   'node:pedal', 'node:steer', 'node:parkingbrake'],
         drop=['mat:meo_turbo', 'node:r35_transmission', 'node:r35_transfercase', 'node:r35_tierod', 'node:r35_driveshaft',
               'node:r35_swaybar', 'node:r35_subframe', 'node:r35_spring', 'node:r35_shock', 'node:r35_lowerarm',
               'node:r35_halfshaft', 'node:r35_diff', 'node:r35_upperarm', 'node:r35_engine', 'node:r35_exhaust_manifold']),
    dict(id='audi-r8', src='audi_r8', name='Audi R8 V10', year=2020,
         uid='e17e438f076f4427a58d93aa779edaed', author='realwallon', license='CC BY 4.0',
         length=4.43, front='+z', mass=1550, power=1.09, drive='all', bias=-0.15,
         wheel=['mat:tire', 'mat:wheel', 'mat:calipers', 'node:circle.003_rim', 'node:circle.004_rim'],
         caliper=['mat:calipers'],
         paint=['mat:body'],
         brakelight=['mat:red_lights'],
         interior=['node:seat', 'node:steering', 'node:dash', 'node:interior', 'node:pedal'],
         drop=[]),
    dict(id='ferrari-sf90', src='ferrari_sf90', name='Ferrari SF90 XX Stradale', year=2023,
         uid='2c80c667232544649328cf3589921bcd', author='ddiaz-design', license='CC BY 4.0',
         length=4.85, front='+z', mass=1520, power=1.1, drive='all', bias=-0.15,
         wheel=['mat:wheel1a', 'mat:calliper'],
         caliper=['mat:calliper'],
         paint=['mat:2024paint_material'],
         brakelight=['mat:red_glass'],
         interior=['mat:interiora', 'mat:interiortilling', 'mat:windowinside'],
         drop=[]),
    dict(id='toyota-supra', src='toyota_supra', name='Toyota GR Supra GT300', year=2020,
         uid='1666c35171b649a8a927da53bdadf228', author='heynic (www.vecarz.com)', license='CC BY 4.0',
         length=None, front='+z', mass=1480, power=1.03, drive='rear', bias=-0.12,
         wheel=['mat:rims_chromes', 'mat:19_-_default'], cylinder=True,
         caliper=[],
         paint=[],
         brakelight=[],
         interior=['mat:int_'],
         drop=[]),
]

# ---------------------------------------------------------------- matrices

def eye():
    return [[1.0 if i == j else 0.0 for j in range(4)] for i in range(4)]

def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

def of_node(n):
    if 'matrix' in n:
        c = n['matrix']
        return [[c[j * 4 + i] for j in range(4)] for i in range(4)]
    T, R, S = eye(), eye(), eye()
    if 'translation' in n:
        for i in range(3): T[i][3] = n['translation'][i]
    if 'rotation' in n:
        x, y, z, w = n['rotation']
        r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
             [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
             [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
        for i in range(3):
            for j in range(3): R[i][j] = r[i][j]
    if 'scale' in n:
        for i in range(3): S[i][i] = n['scale'][i]
    return mul(mul(T, R), S)

def inv3(m):
    a, b, c = m[0][:3]; d, e, f = m[1][:3]; g, h, i = m[2][:3]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    if abs(det) < 1e-30: return eye(), det
    k = 1 / det
    return [[(e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k],
            [(f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k],
            [(d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k]], det

# ---------------------------------------------------------------- reading

def read_glb(path):
    b = open(path, 'rb').read()
    if struct.unpack_from('<I', b, 0)[0] != 0x46546C67: raise ValueError(path + ': not a GLB')
    off, js, bin_ = 12, None, b''
    while off < len(b):
        ln, ty = struct.unpack_from('<II', b, off); off += 8
        if ty == 0x4E4F534A: js = json.loads(b[off:off + ln])
        elif ty == 0x004E4942: bin_ = b[off:off + ln]
        off += ln
    return js, bin_

COMP = {5120: ('b', 1), 5121: ('B', 1), 5122: ('h', 2), 5123: ('H', 2), 5125: ('I', 4), 5126: ('f', 4)}
WIDTH = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}
NORM = {5120: 127.0, 5121: 255.0, 5122: 32767.0, 5123: 65535.0}

def accessor(js, bin_, i):
    """An accessor as a flat list of floats (or ints for indices)."""
    a = js['accessors'][i]
    code, size = COMP[a['componentType']]
    n, w = a['count'], WIDTH[a['type']]
    if 'bufferView' not in a:
        out = [0.0] * (n * w)
    else:
        bv = js['bufferViews'][a['bufferView']]
        start = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
        stride = bv.get('byteStride', 0) or size * w
        if stride == size * w:
            out = array(code, bin_[start:start + n * w * size]).tolist()
        else:
            out = []
            for k in range(n):
                out.extend(struct.unpack_from('<' + code * w, bin_, start + k * stride))
    if a.get('normalized') and a['componentType'] in NORM:
        s = NORM[a['componentType']]
        out = [max(-1.0, v / s) for v in out]
    if 'sparse' in a:
        raise ValueError('sparse accessors not handled')
    return out, w

class Piece:
    """One primitive, its triangles baked into the source's world frame."""
    def __init__(s, node, mat, pos, nrm, tan, uv0, uv1, idx):
        s.node, s.mat, s.pos, s.nrm, s.tan, s.uv0, s.uv1, s.idx = node, mat, pos, nrm, tan, uv0, uv1, idx

def pieces(js, bin_):
    nodes = js['nodes']
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get('children', []): parent[c] = i
    world = {}
    def W(i):
        if i not in world:
            m = of_node(nodes[i]); p = parent.get(i)
            world[i] = mul(W(p), m) if p is not None else m
        return world[i]
    # Only what the scene shows.
    shown = set()
    def walk(i):
        shown.add(i)
        for c in nodes[i].get('children', []): walk(c)
    for r in js['scenes'][js.get('scene', 0)]['nodes']: walk(r)
    out = []
    for i, n in enumerate(nodes):
        if 'mesh' not in n or i not in shown: continue
        M = W(i)
        N, det = inv3(M)
        flip = det < 0
        name = (n.get('name') or '') + ' ' + (js['meshes'][n['mesh']].get('name') or '')
        for p in js['meshes'][n['mesh']]['primitives']:
            if p.get('mode', 4) != 4: continue
            at = p['attributes']
            pos, _ = accessor(js, bin_, at['POSITION'])
            nv = len(pos) // 3
            idx = accessor(js, bin_, p['indices'])[0] if 'indices' in p else list(range(nv))
            idx = [int(v) for v in idx]
            if flip:
                for t in range(0, len(idx) - 2, 3): idx[t + 1], idx[t + 2] = idx[t + 2], idx[t + 1]
            P = []
            for k in range(nv):
                x, y, z = pos[3 * k:3 * k + 3]
                P += [M[0][0] * x + M[0][1] * y + M[0][2] * z + M[0][3],
                      M[1][0] * x + M[1][1] * y + M[1][2] * z + M[1][3],
                      M[2][0] * x + M[2][1] * y + M[2][2] * z + M[2][3]]
            Nn = None
            if 'NORMAL' in at:
                nr, _ = accessor(js, bin_, at['NORMAL'])
                Nn = []
                for k in range(nv):
                    x, y, z = nr[3 * k:3 * k + 3]
                    # Normals by the inverse transpose.
                    a = N[0][0] * x + N[1][0] * y + N[2][0] * z
                    b = N[0][1] * x + N[1][1] * y + N[2][1] * z
                    c = N[0][2] * x + N[1][2] * y + N[2][2] * z
                    l = math.sqrt(a * a + b * b + c * c) or 1
                    Nn += [a / l, b / l, c / l]
            T = None
            if 'TANGENT' in at:
                tg, _ = accessor(js, bin_, at['TANGENT'])
                T = []
                for k in range(nv):
                    x, y, z, w = tg[4 * k:4 * k + 4]
                    a = M[0][0] * x + M[0][1] * y + M[0][2] * z
                    b = M[1][0] * x + M[1][1] * y + M[1][2] * z
                    c = M[2][0] * x + M[2][1] * y + M[2][2] * z
                    l = math.sqrt(a * a + b * b + c * c) or 1
                    T += [a / l, b / l, c / l, -w if flip else w]
            uv0 = accessor(js, bin_, at['TEXCOORD_0'])[0] if 'TEXCOORD_0' in at else None
            uv1 = accessor(js, bin_, at['TEXCOORD_1'])[0] if 'TEXCOORD_1' in at else None
            out.append(Piece(name.lower(), p.get('material', -1), P, Nn, T, uv0, uv1, idx))
    return out

def matches(pats, piece, matname):
    for p in pats:
        if p.startswith('mat:'):
            if p[4:] in matname: return True
        elif p.startswith('node:'):
            if p[5:] in piece.node: return True
        elif p in matname or p in piece.node:
            return True
    return False

# ---------------------------------------------------------------- materials

ROUGH_NAMES = ['plastic', 'rubber', 'leather', 'fabric', 'carpet', 'cloth', 'trim', 'seat', 'stitch', 'speaker',
               'matte', 'pure_black', 'tire', 'tyre', 'interior', 'chassis']

def fix_material(m, role):
    """A source material put right for the game; role is paint, brakelight,
    glass, mask, or None. Returns False to leave its triangles out."""
    name = (m.get('name') or '').lower()
    pbr = m.setdefault('pbrMetallicRoughness', {})
    col = pbr.get('baseColorFactor', [1, 1, 1, 1])
    textured = 'baseColorTexture' in pbr
    blend = m.get('alphaMode') == 'BLEND'
    ext = m.get('extensions', {})
    ext.pop('KHR_materials_specular', None)
    if blend and col[3] < 0.05 and not textured and role != 'brakelight':
        return False
    if role == 'paint':
        m['name'] = 'Paint 1 ' + m.get('name', '')
        pbr['metallicFactor'] = 0.55
        pbr['roughnessFactor'] = 0.32
        return True
    if role == 'brakelight':
        m['name'] = 'Brakelight'
        m['alphaMode'] = 'OPAQUE'
        ext.pop('KHR_materials_transmission', None)
        pbr['baseColorFactor'] = [0.35, 0.01, 0.01, 1]
        pbr['metallicFactor'] = 0
        pbr['roughnessFactor'] = 0.2
        m['emissiveFactor'] = [0.45, 0.01, 0.005]
        ext.pop('KHR_materials_emissive_strength', None)
        return True
    if blend:
        glass = 'glass' in name or 'window' in name or not textured or col[3] < 0.5
        if not glass:
            m['alphaMode'] = 'MASK'
            m['alphaCutoff'] = 0.5
        return True
    # Exported plastics and rubbers often come out as mirror-smooth metal.
    if any(k in name for k in ROUGH_NAMES) and not textured:
        pbr['metallicFactor'] = 0.0
        pbr['roughnessFactor'] = max(pbr.get('roughnessFactor', 1), 0.55)
    elif pbr.get('metallicFactor', 1) >= 0.99 and pbr.get('roughnessFactor', 1) <= 0.01 and max(col[:3]) < 0.12 and not textured:
        # Black "metal" at zero roughness: gloss black plastic.
        pbr['metallicFactor'] = 0.0
        pbr['roughnessFactor'] = 0.3
    return True

# ---------------------------------------------------------------- the cook

class Group:
    """Triangles headed for one output node: indices into a piece, by material."""
    def __init__(s):
        s.tris = {}   # material -> list of (piece, i0, i1, i2)

    def add(s, mat, piece, a, b, c):
        s.tris.setdefault(mat, []).append((piece, a, b, c))

def cook(car):
    src = os.path.join(SRC, car['src'], car['src'] + '.glb')
    js, bin_ = read_glb(src)
    mats = js.get('materials', [])
    matname = lambda i: (mats[i].get('name') or '').lower() if 0 <= i < len(mats) else ''
    ps = [p for p in pieces(js, bin_) if not matches(car['drop'], p, matname(p.mat))]
    flipz = car['front'] == '-z'

    def P(p, v):
        x, y, z = p.pos[3 * v:3 * v + 3]
        return (-x, y, -z) if flipz else (x, y, z)

    # The wheels' corners: where the wheel-ish geometry is, split down the
    # middle both ways.
    wheelish = [p for p in ps if matches(car['wheel'], p, matname(p.mat))]
    if not wheelish: raise ValueError(car['id'] + ': no wheels matched')
    lo = [1e9] * 3; hi = [-1e9] * 3
    for p in wheelish:
        for v in range(len(p.pos) // 3):
            q = P(p, v)
            for k in range(3): lo[k] = min(lo[k], q[k]); hi[k] = max(hi[k], q[k])
    cx, cz = (lo[0] + hi[0]) / 2, (lo[2] + hi[2]) / 2

    def corner(x, z):
        # vehicle.Car's order: front left, front right, rear left, rear right (+X left).
        return (0 if z > cz else 2) + (0 if x > cx else 1)

    # Each corner's rolling geometry's box: the hub at its middle, the tire's
    # radius half its height.
    box = [[[1e9] * 3, [-1e9] * 3] for _ in range(4)]
    calip = lambda p: matches(car['caliper'], p, matname(p.mat))
    for p in wheelish:
        if calip(p): continue
        for t in range(0, len(p.idx) - 2, 3):
            a, b, c = (P(p, p.idx[t + j]) for j in range(3))
            k = corner((a[0] + b[0] + c[0]) / 3, (a[2] + b[2] + c[2]) / 3)
            for q in (a, b, c):
                for j in range(3):
                    box[k][0][j] = min(box[k][0][j], q[j]); box[k][1][j] = max(box[k][1][j], q[j])
    hubs = [[(b[0][j] + b[1][j]) / 2 for j in range(3)] for b in box]
    radii = [(b[1][1] - b[0][1]) / 2 for b in box]
    widths = [(b[1][0] - b[0][0]) for b in box]

    # Optionally, anything else wholly inside a wheel's cylinder is wheel too
    # (tires that share a material with the body).
    def inwheel(q):
        for k in range(4):
            h = hubs[k]
            if abs(q[0] - h[0]) <= widths[k] / 2 + 0.01 * radii[k] and \
               (q[1] - h[1]) ** 2 + (q[2] - h[2]) ** 2 <= (radii[k] * 1.03) ** 2:
                return k
        return -1

    # Sort every triangle: body, cabin, a wheel's rolling part or its caliper.
    body, cabin = Group(), Group()
    rolling = [Group() for _ in range(4)]
    fixed = [Group() for _ in range(4)]
    for p in ps:
        mn = matname(p.mat)
        is_wheel = matches(car['wheel'], p, mn)
        is_cal = is_wheel and calip(p)
        is_in = matches(car['interior'], p, mn)
        for t in range(0, len(p.idx) - 2, 3):
            i0, i1, i2 = p.idx[t], p.idx[t + 1], p.idx[t + 2]
            a, b, c = P(p, i0), P(p, i1), P(p, i2)
            if is_wheel:
                k = corner((a[0] + b[0] + c[0]) / 3, (a[2] + b[2] + c[2]) / 3)
                (fixed if is_cal else rolling)[k].add(p.mat, p, i0, i1, i2)
                continue
            if car.get('cylinder') and not is_in:
                ka, kb, kc = inwheel(a), inwheel(b), inwheel(c)
                if ka >= 0 and ka == kb == kc:
                    rolling[ka].add(p.mat, p, i0, i1, i2)
                    continue
            (cabin if is_in else body).add(p.mat, p, i0, i1, i2)

    # Ground at the tires' bottoms; the origin between the axles; meters.
    ground = min(h[1] - r for h, r in zip(hubs, radii))
    ox = sum(h[0] for h in hubs) / 4
    oz = sum(h[2] for h in hubs) / 4
    blo = [1e9] * 3; bhi = [-1e9] * 3
    for g in [body, cabin] + rolling + fixed:
        for tris in g.tris.values():
            for (p, a, b, c) in tris:
                for v in (a, b, c):
                    q = P(p, v)
                    for j in range(3): blo[j] = min(blo[j], q[j]); bhi[j] = max(bhi[j], q[j])
    scale = car['length'] / (bhi[2] - blo[2]) if car.get('length') else 1.0
    if not car.get('length') and (bhi[2] - blo[2]) > 8:
        raise ValueError(car['id'] + ': %.1f long; give it a length' % (bhi[2] - blo[2]))

    def G(q):
        return ((q[0] - ox) * scale, (q[1] - ground) * scale, (q[2] - oz) * scale)

    hubsG = [G(h) for h in hubs]
    radiiG = [r * scale for r in radii]
    bloG, bhiG = G(blo), G(bhi)

    # Materials: copied, put right, renamed.
    roles = {}
    for i in range(len(mats)):
        n = matname(i)
        fake = Piece('', i, [], None, None, None, None, [])
        if car['paint'] and matches(car['paint'], fake, n): roles[i] = 'paint'
        elif car['brakelight'] and matches(car['brakelight'], fake, n): roles[i] = 'brakelight'
    keep = {i: fix_material(mats[i], roles.get(i)) for i in range(len(mats))}

    # Write it.
    out = GLB(js, bin_)
    out.flipz = flipz
    nodes = []
    def emit(name, group, translation=None, sub=None):
        prims = []
        for mat in sorted(group.tris):
            if mat >= 0 and not keep.get(mat, True): continue
            prims.append(out.primitive(group.tris[mat], mat, G, P, sub))
        if not prims: return None
        out.js_meshes.append({'name': name, 'primitives': prims})
        n = {'name': name, 'mesh': len(out.js_meshes) - 1}
        if translation: n['translation'] = translation
        nodes.append(n)
        return len(nodes) - 1

    roots = []
    r = emit('Body', body)
    if r is not None: roots.append(r)
    r = emit('Interior', cabin)
    if r is not None: roots.append(r)
    for k, tag in enumerate(['FL', 'FR', 'RL', 'RR']):
        h = hubsG[k]
        kids = []
        r = emit('Rim ' + tag, rolling[k], sub=h)
        if r is not None: kids.append(r)
        r = emit('BrakePad ' + tag, fixed[k], sub=h)
        if r is not None: kids.append(r)
        nodes.append({'name': 'Wheel ' + tag, 'translation': list(h), 'children': kids})
        roots.append(len(nodes) - 1)
    dst_dir = os.path.join(GAME, 'assets', 'cars', car['id'])
    os.makedirs(dst_dir, exist_ok=True)
    tris = out.write(os.path.join(dst_dir, 'car.glb'), nodes, roots)

    return dict(id=car['id'], name=car['name'], year=car['year'], model='cars/%s/car.glb' % car['id'],
                credit='%s by %s, https://sketchfab.com/3d-models/%s, %s' % (car['name'], car['author'], car['uid'], car['license']),
                mass=car['mass'], power=car['power'], drive=car['drive'], bias=car['bias'],
                hubs=[[round(v, 4) for v in h] for h in hubsG], radii=[round(v, 4) for v in radiiG],
                min=[round(v, 3) for v in bloG], max=[round(v, 3) for v in bhiG], triangles=tris)

class GLB:
    """The cooked file: the source's materials, textures and images, new meshes."""
    def __init__(s, js, bin_):
        s.src = js
        s.srcbin = bin_
        s.data = bytearray()
        s.views = []
        s.accessors = []
        s.js_meshes = []

    def view(s, b, target=None):
        while len(s.data) % 4: s.data.append(0)
        v = {'buffer': 0, 'byteOffset': len(s.data), 'byteLength': len(b)}
        if target: v['target'] = target
        s.data += b
        s.views.append(v)
        return len(s.views) - 1

    def acc(s, vals, comp, typ, target, minmax=False):
        code = {5126: 'f', 5125: 'I', 5123: 'H'}[comp]
        b = array(code, vals).tobytes()
        a = {'bufferView': s.view(b, target), 'componentType': comp, 'count': len(vals) // WIDTH[typ], 'type': typ}
        if minmax:
            w = WIDTH[typ]
            a['min'] = [min(vals[j::w]) for j in range(w)]
            a['max'] = [max(vals[j::w]) for j in range(w)]
        s.accessors.append(a)
        return len(s.accessors) - 1

    def primitive(s, tris, mat, G, P, sub):
        # Vertices re-indexed per (piece, vertex).
        remap = {}
        pos, nrm, tan, uv0, uv1, idx = [], [], [], [], [], []
        has_t = all(p.tan is not None for (p, _, _, _) in tris)
        has_uv1 = all(p.uv1 is not None for (p, _, _, _) in tris)
        for (p, a, b, c) in tris:
            for v in (a, b, c):
                key = (id(p), v)
                k = remap.get(key)
                if k is None:
                    k = len(remap)
                    remap[key] = k
                    q = G(P(p, v))
                    if sub: q = (q[0] - sub[0], q[1] - sub[1], q[2] - sub[2])
                    pos += q
                    if p.nrm is not None:
                        x, y, z = p.nrm[3 * v:3 * v + 3]
                        nrm += [-x, y, -z] if s.flipz else [x, y, z]
                    else:
                        nrm += [0, 1, 0]
                    if has_t:
                        x, y, z, w = p.tan[4 * v:4 * v + 4]
                        tan += [-x, y, -z, w] if s.flipz else [x, y, z, w]
                    uv0 += p.uv0[2 * v:2 * v + 2] if p.uv0 is not None else [0, 0]
                    if has_uv1: uv1 += p.uv1[2 * v:2 * v + 2]
                idx.append(k)
        attrs = {'POSITION': s.acc(pos, 5126, 'VEC3', 34962, True), 'NORMAL': s.acc(nrm, 5126, 'VEC3', 34962),
                 'TEXCOORD_0': s.acc(uv0, 5126, 'VEC2', 34962)}
        if has_t: attrs['TANGENT'] = s.acc(tan, 5126, 'VEC4', 34962)
        if has_uv1: attrs['TEXCOORD_1'] = s.acc(uv1, 5126, 'VEC2', 34962)
        comp = 5123 if len(remap) < 65536 else 5125
        prim = {'attributes': attrs, 'indices': s.acc(idx, comp, 'SCALAR', 34963), 'mode': 4}
        s.tri_count = getattr(s, 'tri_count', 0) + len(idx) // 3
        if mat >= 0: prim['material'] = mat
        return prim

    def write(s, path, nodes, roots):
        js = s.src
        # Images carried over from the source's buffer.
        images = []
        for im in js.get('images', []):
            im = dict(im)
            if 'bufferView' in im:
                bv = js['bufferViews'][im['bufferView']]
                o = bv.get('byteOffset', 0)
                im['bufferView'] = s.view(s.srcbin[o:o + bv['byteLength']])
            images.append(im)
        out = {'asset': {'version': '2.0', 'generator': 'nitro-velocity cook.py'},
               'scene': 0, 'scenes': [{'nodes': roots}], 'nodes': nodes, 'meshes': s.js_meshes,
               'materials': js.get('materials', []), 'textures': js.get('textures', []), 'images': images,
               'samplers': js.get('samplers', []), 'accessors': s.accessors, 'bufferViews': s.views,
               'buffers': [{'byteLength': 0}]}
        used = set()
        for m in out['materials']:
            used.update(k for k in m.get('extensions', {}))
        if used: out['extensionsUsed'] = sorted(used)
        for k in ('textures', 'images', 'samplers'):
            if not out[k]: del out[k]
        while len(s.data) % 4: s.data.append(0)
        out['buffers'][0]['byteLength'] = len(s.data)
        j = json.dumps(out, separators=(',', ':')).encode()
        while len(j) % 4: j += b' '
        with open(path, 'wb') as f:
            f.write(struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(j) + 8 + len(s.data)))
            f.write(struct.pack('<II', len(j), 0x4E4F534A)); f.write(j)
            f.write(struct.pack('<II', len(s.data), 0x004E4942)); f.write(s.data)
        return s.tri_count

def main():
    want = sys.argv[1:]
    path = os.path.join(GAME, 'data', 'cars.json')
    old = {}
    if os.path.exists(path):
        for c in json.load(open(path)).get('cars', []): old[c['id']] = c
    done = []
    for car in CARS:
        if want and car['id'] not in want and car['src'] not in want:
            if car['id'] in old: done.append(old[car['id']])
            continue
        c = cook(car)
        print('%-15s %7d triangles, %.2f m long, wheelbase %.2f m, track %.2f m, tires %.3f/%.3f m' % (
            c['id'], c['triangles'], c['max'][2] - c['min'][2], c['hubs'][0][2] - c['hubs'][2][2],
            c['hubs'][0][0] - c['hubs'][1][0], c['radii'][0], c['radii'][2]))
        done.append(c)
    with open(path, 'w') as f:
        json.dump({'cars': done}, f, indent=2)
        f.write('\n')

if __name__ == '__main__':
    main()
