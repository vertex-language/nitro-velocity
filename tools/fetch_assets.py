#!/usr/bin/env python3
"""fetch_assets.py: fetches what nitro-velocity didn't make and cooks it.

    python3 tools/fetch_assets.py                     # download, check, cook
    python3 tools/fetch_assets.py --from ../assets_src  # originals from a folder

The originals (Poly Haven, ambientCG and Sketchfab; ASSETS.md has their
credits and licenses) go into assets_src/, each checked against its
SHA-256 below; one that doesn't match is an error. They are then cooked
into assets/: the textures with `sips`, the cars with cook.py, the trees
and grass with cook_foliage.py, and the results checked too (a mismatch
there is only a warning: another macOS's `sips` may encode a little
differently). Files already in place and matching are left alone, so a
second run does nothing.

Sketchfab wants an account: set SKETCHFAB_TOKEN to your API token (from
sketchfab.com/settings/password). Poly Haven and ambientCG need nothing.

--from DIR takes originals from DIR (laid out as assets_src/ is) before
downloading, for when you already have them.
"""
import hashlib, io, json, os, shutil, subprocess, sys, urllib.request, zipfile

GAME = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
SRC = os.path.join(GAME, 'assets_src')
UA = {'User-Agent': 'nitro-velocity fetch_assets.py'}

PH = 'https://dl.polyhaven.org/file/ph-assets/'
GRASS_ZIP = 'https://ambientcg.com/get?file=Grass004_2K-JPG.zip'

# The originals: path under assets_src/, SHA-256, and where it comes from
# (a URL, ('zip', url) for a file inside an archive, or ('sketchfab', uid)).
SOURCES = [
    ('polyhaven/asphalt_track/asphalt_track_diff_2k.png',
     '591788ceca6d5dc44d00d85f9935dbf016aa0769269b07731ecef16e5a08da05',
     PH + 'Textures/png/2k/asphalt_track/asphalt_track_diff_2k.png'),
    ('polyhaven/asphalt_track/asphalt_track_nor_gl_2k.png',
     'd01cb5e4bf17e579c056c44e2d3713085d427253fd36a78dec48c2b674ab1c78',
     PH + 'Textures/png/2k/asphalt_track/asphalt_track_nor_gl_2k.png'),
    ('polyhaven/asphalt_track/asphalt_track_rough_2k.png',
     '30e2c59e8dbe0669a2873f1087e708e0c7a72740e5a1385555ce7cc18596f77f',
     PH + 'Textures/png/2k/asphalt_track/asphalt_track_rough_2k.png'),
    ('polyhaven/concrete_floor_02/concrete_floor_02_diff_2k.png',
     'c438815b55874b9bbab5befa559c9ef2b635f674ebf9415c7341f6865156b03b',
     PH + 'Textures/png/2k/concrete_floor_02/concrete_floor_02_diff_2k.png'),
    ('polyhaven/concrete_floor_02/concrete_floor_02_nor_gl_2k.png',
     '0b13102bbf79daef40b7230c20aaca402620b618e043413f1ff677c47acc2861',
     PH + 'Textures/png/2k/concrete_floor_02/concrete_floor_02_nor_gl_2k.png'),
    ('polyhaven/hdri/kloofendal_48d_partly_cloudy_puresky_4k.hdr',
     '3061c00a16ecae748e84fd6c44c04804f539c118bb66325db858bad87b11bf88',
     PH + 'HDRIs/hdr/4k/kloofendal_48d_partly_cloudy_puresky_4k.hdr'),
    ('ambientcg/Grass004/Grass004_2K-JPG_Color.jpg',
     '735b141c8f1972e70a45879424f1238fea9f887324173097785f4ac36e67e9a3',
     ('zip', GRASS_ZIP)),
    ('ambientcg/Grass004/Grass004_2K-JPG_NormalGL.jpg',
     '15ccad231764049d6581a52076d02bb6b627df77895cb0508e4017d8a4877fef',
     ('zip', GRASS_ZIP)),
    ('sketchfab/porsche_gt3rs/porsche_gt3rs.glb',
     'e1cf7d3e04aaaf27cfec6363de5f6427b87c997993f9de0f54ec5549b68b8f96',
     ('sketchfab', 'e738eae819c34d19a31dd066c45e0f3d')),
    ('sketchfab/nissan_gtr/nissan_gtr.glb',
     '9bc77282280549b58ec4b26e4c2afc69cc8c9165051144096cda0ba98e41c8ae',
     ('sketchfab', '7b142ea3376e4811a326256c59bbc7a2')),
    ('sketchfab/audi_r8/audi_r8.glb',
     'aef2b67c383b9cd8c772e7f2775566f50fe130d35006ae362039324859424b9e',
     ('sketchfab', 'e17e438f076f4427a58d93aa779edaed')),
    ('sketchfab/ferrari_sf90/ferrari_sf90.glb',
     '424082aabdaaa354441919f9e9bdf85864bb8eff427b7c8400da06927a561870',
     ('sketchfab', '2c80c667232544649328cf3589921bcd')),
    ('sketchfab/toyota_supra/toyota_supra.glb',
     '530443d1fb3ff71a9d4c275ff37320542058ff3b5f1ebd5a4bbd3d97206969ea',
     ('sketchfab', '1666c35171b649a8a927da53bdadf228')),
    ('sketchfab/conifer_pack/conifer_pack.glb',
     '48c1e34111e280750d5100f0a0c8c2352b0de16d09542c1dae787da0d7548250',
     ('sketchfab', '240ce9cf0ad3474f809a59f9446e63cd')),
    ('sketchfab/grass06/grass06.glb',
     '4758777e1722b94efb4fd235bece8bb4930a0329311c1b32095517b2f4dc9c94',
     ('sketchfab', 'b5956b7d4d1f4ff6ae1dd1320dab0d12')),
]

# The textures: output, source, size (sips, JPEG quality 90).
TEXTURES = [
    ('asphalt_color.jpg', 'polyhaven/asphalt_track/asphalt_track_diff_2k.png', 2048),
    ('asphalt_normal.jpg', 'polyhaven/asphalt_track/asphalt_track_nor_gl_2k.png', 2048),
    ('asphalt_rough.jpg', 'polyhaven/asphalt_track/asphalt_track_rough_2k.png', 1024),
    ('concrete_color.jpg', 'polyhaven/concrete_floor_02/concrete_floor_02_diff_2k.png', 1024),
    ('concrete_normal.jpg', 'polyhaven/concrete_floor_02/concrete_floor_02_nor_gl_2k.png', 1024),
    ('grass_color.jpg', 'ambientcg/Grass004/Grass004_2K-JPG_Color.jpg', 2048),
    ('grass_normal.jpg', 'ambientcg/Grass004/Grass004_2K-JPG_NormalGL.jpg', 1024),
]

# What cooking makes, under assets/, and its SHA-256.
COOKED = {
    'textures/asphalt_color.jpg': 'ebf474d10ba0f46600dc46fea9ae355dc4e720396103c6477034899dc612a815',
    'textures/asphalt_normal.jpg': 'e97e58d654f0d5eb4d17c8a08419c738c3a8b9cdac4f3e485ad9a5a52e9556bf',
    'textures/asphalt_rough.jpg': '738f9384b0a9b201359008cf63b6dee0e79773766d39ca4c79a80c078ab60957',
    'textures/concrete_color.jpg': '8e72c47c1d9d8953441e90c9381edbb16b3ce872d80ff6fb27d815a4fa56fb2d',
    'textures/concrete_normal.jpg': '1b182530a017c9c936c75bc89c844b39208bf08ce4d08082f9c71d5390644158',
    'textures/grass_color.jpg': '9d5fd4cfece26a04ceb83bd3de39085f65df0a39f431d59f84b94cc2e1f35de0',
    'textures/grass_normal.jpg': '3a3d41093ee5d666eb85d5c3468c13d8cd27f58633be45b7f0022b2a77e781f0',
    'sky/sky_4k.hdr': '3061c00a16ecae748e84fd6c44c04804f539c118bb66325db858bad87b11bf88',
    'cars/porsche-gt3rs/car.glb': '7c975ef3745323ccea2231ce36ab60edbeab11fceb98341d519643f57e9dc571',
    'cars/nissan-gtr/car.glb': '688f2f59f4d4a1d74d398e57abba0bf9cee8ae1b7f87fa585b0f2f7ed7d1a088',
    'cars/audi-r8/car.glb': 'e23d418f12dfbd5f4ea746e808c1eb0fcbd8986c77b1e4ccf7fb44f58c26dbef',
    'cars/ferrari-sf90/car.glb': '47190a02782430f0e7472909af6fee0e9ae0c3de7bd999af9ade447a40c904f5',
    'cars/toyota-supra/car.glb': '7fd465ef29580121b829a7e55d8cf1feebe42920900d272c0f5e57a9e4b67551',
    'foliage/trees.glb': 'b00cd61f857fe59b60fbf8d312f6c284971cad1a3105d928d05d2100c30cc3d7',
    'foliage/grass.glb': 'dd9eee96797c03cb7ccfd6724edb51ebeb3fa2abfe248d1da19ab070845e5199',
}

def sha256(path):
    if not os.path.exists(path): return None
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''): h.update(block)
    return h.hexdigest()

def get(url, headers={}):
    with urllib.request.urlopen(urllib.request.Request(url, headers={**UA, **headers})) as r:
        return r.read()

def sketchfab(uid):
    token = os.environ.get('SKETCHFAB_TOKEN')
    if not token:
        sys.exit('fetch_assets: the Sketchfab models need SKETCHFAB_TOKEN set to your API token '
                 '(sketchfab.com/settings/password), or --from a folder that has them')
    info = json.loads(get('https://api.sketchfab.com/v3/models/%s/download' % uid,
                          {'Authorization': 'Token ' + token}))
    if 'glb' not in info: sys.exit('fetch_assets: Sketchfab offers no GLB of %s' % uid)
    return get(info['glb']['url'])

zips = {}

def fetch(path, want, where, local):
    dst = os.path.join(SRC, path)
    if sha256(dst) == want: return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if local and sha256(os.path.join(local, path)) == want:
        shutil.copyfile(os.path.join(local, path), dst)
        print('copied     ' + path)
        return
    print('fetching   ' + path)
    if isinstance(where, str):
        data = get(where)
    elif where[0] == 'zip':
        if where[1] not in zips: zips[where[1]] = zipfile.ZipFile(io.BytesIO(get(where[1])))
        data = zips[where[1]].read(os.path.basename(path))
    else:
        data = sketchfab(where[1])
    if hashlib.sha256(data).hexdigest() != want:
        sys.exit('fetch_assets: %s is not the file it should be (its source changed?)' % path)
    with open(dst + '.part', 'wb') as f: f.write(data)
    os.replace(dst + '.part', dst)

def ok(out):
    return sha256(os.path.join(GAME, 'assets', out)) == COOKED[out]

def cook():
    os.makedirs(os.path.join(GAME, 'assets', 'textures'), exist_ok=True)
    for out, src, size in TEXTURES:
        if ok('textures/' + out): continue
        print('cooking    textures/' + out)
        subprocess.run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '90', '-z', str(size), str(size),
                        os.path.join(SRC, src), '--out', os.path.join(GAME, 'assets', 'textures', out)],
                       check=True, stdout=subprocess.DEVNULL)
    if not ok('sky/sky_4k.hdr'):
        print('copying    sky/sky_4k.hdr')
        os.makedirs(os.path.join(GAME, 'assets', 'sky'), exist_ok=True)
        shutil.copyfile(os.path.join(SRC, 'polyhaven/hdri/kloofendal_48d_partly_cloudy_puresky_4k.hdr'),
                        os.path.join(GAME, 'assets', 'sky', 'sky_4k.hdr'))
    tools = os.path.dirname(os.path.abspath(__file__))
    if not all(ok(o) for o in COOKED if o.startswith('cars/')):
        print('cooking    cars')
        subprocess.run([sys.executable, os.path.join(tools, 'cook.py')], check=True, cwd=GAME)
    if not all(ok(o) for o in COOKED if o.startswith('foliage/')):
        print('cooking    foliage')
        subprocess.run([sys.executable, os.path.join(tools, 'cook_foliage.py')], check=True, cwd=GAME)

def main():
    args = sys.argv[1:]
    local = None
    if args[:1] == ['--from'] and len(args) == 2:
        local = os.path.abspath(args[1])
    elif args:
        sys.exit(__doc__.split('\n\n')[1])
    for path, want, where in SOURCES: fetch(path, want, where, local)
    cook()
    off = [o for o in COOKED if not ok(o)]
    for o in off: print('warning: assets/%s is not the expected file (another macOS or Python?)' % o)
    print('assets ready' + (' (%d differ)' % len(off) if off else ''))

if __name__ == '__main__':
    main()
