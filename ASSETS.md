# Assets

What nitro-velocity uses that it didn't make. Sources and licenses.
`tools/fetch_assets.py` downloads the originals into `assets_src/`, checks
each against its SHA-256, and cooks them into `assets/` (neither is in git):

```bash
SKETCHFAB_TOKEN=... python3 tools/fetch_assets.py
```

The token is your Sketchfab API token (sketchfab.com/settings/password);
Poly Haven and ambientCG need none.

## The cars

| File | From | License |
| :--- | :--- | :--- |
| `assets/cars/porsche-gt3rs/car.glb` | Sketchfab, [Porsche 911 GT3 RS](https://sketchfab.com/3d-models/e738eae819c34d19a31dd066c45e0f3d) by BlackSnow02 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `assets/cars/nissan-gtr/car.glb` | Sketchfab, [Nissan GT-R (R35)](https://sketchfab.com/3d-models/7b142ea3376e4811a326256c59bbc7a2) by BlackSnow02 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `assets/cars/audi-r8/car.glb` | Sketchfab, [Audi R8 V10](https://sketchfab.com/3d-models/e17e438f076f4427a58d93aa779edaed) by realwallon | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `assets/cars/ferrari-sf90/car.glb` | Sketchfab, [Ferrari SF90 XX Stradale](https://sketchfab.com/3d-models/2c80c667232544649328cf3589921bcd) by ddiaz-design | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `assets/cars/toyota-supra/car.glb` | Sketchfab, [Toyota GR Supra GT300](https://sketchfab.com/3d-models/1666c35171b649a8a927da53bdadf228) by heynic (www.vecarz.com) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Downloaded through Sketchfab's API (the GLB of each); the originals go in
`assets_src/sketchfab/`. `tools/cook.py` bakes each
into what `look.CarModel` reads: meters, facing +Z, the ground at y = 0,
the body, the cabin ("Interior") and the four wheels as their own nodes
(split out by triangle where a model has all four in one mesh), calipers
apart so they steer without rolling, the paint renamed "Paint 1 …" so the
field's colors go over it, brake lights lit, invisible and hidden
mechanical parts left out. It also writes `data/cars.json`: each car's
name, model, credit, and the build race makes from it (hubs, tire radii,
body box, weight, power, drive). Run it again after changing a car:

```bash
python3 tools/cook.py
```

These are fan-made models of real cars: the makers' names, badges and
liveries on them are their trademarks, fine to race here but not to sell.

## The trees and grass

| File | From | License |
| :--- | :--- | :--- |
| `assets/foliage/trees.glb` | Sketchfab, [Coniferous Forest Assets Pack](https://sketchfab.com/3d-models/240ce9cf0ad3474f809a59f9446e63cd) by dariiiii (its fir, pine and noble fir) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `assets/foliage/grass.glb` | Sketchfab, [Realistics grass 06](https://sketchfab.com/3d-models/b5956b7d4d1f4ff6ae1dd1320dab0d12) by POLYSCAN3D | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

The originals go in `assets_src/sketchfab/`;
`tools/cook_foliage.py` turns them into these: their
specular-glossiness materials into metallic-roughness; each tree standing
on the origin with three levels of detail (as modeled; its needles on a
12-sided trunk; the bigger half of its needles on a 6-sided trunk); the
grass scan cut into four clumps, each with a far version of a fifth of
its blades, and its blade texture stretched to fill the scan's cards (as
it comes, the blade is a thin stripe the renderer's mip levels fade to
nothing a few meters off). They sway in the renderer's wind like any
instanced foliage.

## The world

| File | From | License |
| :--- | :--- | :--- |
| `assets/sky/sky_4k.hdr` | Poly Haven, [Kloofendal 48d Partly Cloudy (Pure Sky)](https://polyhaven.com/a/kloofendal_48d_partly_cloudy_puresky), 4K HDR. Greg Zaal; sky edits Jarod Guest | CC0 |
| `assets/textures/asphalt_color.jpg`, `asphalt_normal.jpg`, `asphalt_rough.jpg` | Poly Haven, [Asphalt Track](https://polyhaven.com/a/asphalt_track) (2K PNG, diffuse, GL normal, roughness), Dimitrios Savva | CC0 |
| `assets/textures/concrete_color.jpg`, `concrete_normal.jpg` | Poly Haven, [Concrete Floor 02](https://polyhaven.com/a/concrete_floor_02) (2K PNG), Rob Tuytel | CC0 |
| `assets/textures/grass_color.jpg`, `grass_normal.jpg` | ambientCG, [Grass004](https://ambientcg.com/view?id=Grass004) (2K JPG, color and GL normal) | CC0 |

The textures were cooked with `sips` from the originals (JPEG, quality
90; asphalt color and normal and grass color 2048², the rest 1024²): JPEG goes through the
system's decoder, which is much faster than decoding PNG in Vertex.

`assets/sky/sky_4k.cooked` is made by the game the first time it runs
(finding the sun in the sky, blurring a reflection for every roughness,
projecting its light: about 20 s), and read back every time after (about
0.1 s). Delete it after changing the sky.

## Made by code

The kerbs, the finish line's checker, the wall's band, the crowd, the
signs and the plate (`look/textures.vs`), the grandstand, the gantry, the
barriers and the hills (`look/scenery.vs`, `track/meshes.vs`), and every
sound (`sound/sound.vs`: engines, tires, wind, nitro, crowd, knocks,
beeps, fanfare).
