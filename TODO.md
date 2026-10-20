# TODO — Nitro Velocity (Visual Roadmap)

What's next for `nitro-velocity`, ordered by visual impact and package
reusability. Following [`proposed_graphics_v3.md`](../proposed_graphics_v3.md),
every general capability lives in a reusable `vs-package` (`render/*`,
`flora/*`, `mesh/*`, `scene/*`, `physics/*`, `media/*`, `image/*`) so
`character-sim`, `npc-sim`, and `vcraft` gain from the same
work, while `nitro-velocity` stays a thin program over packages.

---

## 0. What's Done (Foundation & Visual Upgrades)

- [x] **Core game loop & spine**: Sunny Oval (1.2 km), five cars, three
      laps, standing start under the gantry lights, synthesized audio
      (`media/mix`, `media/device`), HUD and frosted-glass results.
- [x] **P6, GPU window layer (`gpu.Layer`)**: scene presented directly on
      the GPU (`run.Window(…, present:)`), HUD uploaded by dirty rects,
      results backdrop frosted on the GPU. 60 fps at 2560×1440 Retina.
- [x] **Native Retina resolution**: full window pixel resolution with
      `--scale` override.
- [x] **HDR render target & post stack (`forward.Post`)**: linear float
      frame, thresholded bloom pyramid, auto-exposure, ACES tonemapping,
      warm summer grade (`look.summerPost`), vignette, FXAA.
- [x] **Cascaded shadow maps (`forward.Scene.ShadowDistance`)**: four
      2048² cascades out to 300 m, texel-snapped bounding spheres,
      bilinear 4×4 tent PCF, merged shadow proxy per car (`Item.Shadow =
      .only`), camera-aware staggered far-cascade updates.
- [x] **Screen-space ambient occlusion (`Post.Occlusion`)**: half-res
      depth SAO with bilateral depth-aware blur, attenuating only the
      sky/ambient share (`shareOf` in alpha).
- [x] **Local reflection probe for the player car (`forward.Probe`)**:
      128² cubemap updated 1–6 faces/frame, converted to sharp + blurred
      lat-long maps, composited over the HDR environment by coverage.
- [x] **Grass macro variation & worn verge (`Material.Macro`, `Meshes.Verge`)**:
      dual-scale rotated UV noise, dry patches toward `MacroColor`, and
      vertex-alpha blended earthy verge strips along the aprons.

---

## 1. Immediate Visual Bugs & Artifacts (Fixed)

- [x] **Fix outside wall Z-fighting (`track/meshes.vs`)**: `Wall` (`0` to
      `height - 0.3` with a sloped Jersey-barrier foot) and `WallBand`
      (`height - 0.3` to `height` + top cap) are cleanly partitioned with
      zero coplanar overlap, eliminating wall Z-fighting at 100–400 m.
- [x] **Fix chalky grazing-angle foliage washout (`render/forward/shaders.vs`)**:
      clamped grazing-angle dielectric Fresnel on `foliage > 0.5` and
      added warm backlit subsurface transmission (`dot(v, -l)`), plus
      camera-aware `ShadowStagger` cascade invalidation when the camera
      jumps or moves across cascade bounds.
- [x] **Fix crushed pitch-black tires & rims (`look/car.vs`)**: corrected
      near-zero glTF material albedos (`Rim1`, `Rim2`, `Disc`, `Brake`,
      `Tiretread`, `Tireside`, `material2`), giving wheels bright
      machined alloy spokes across all LODs, visible steel rotors, red
      calipers, and vulcanized charcoal rubber tires.
- [x] **Fix hollow rival cabins at `d >= 16 m` (`look/car.vs`)**: kept
      cabin interior meshes up to `d < 45 m` (`detail <= 1`) and switched
      `Glass` to opaque dark tinted cockpit glass at `detail >= 2`.

---

## 2. Sky, Sun, Clouds & Atmosphere (`render/forward`, `render/sky`, `render/volume`)

- [x] **True HDR sky backdrop & blazing solar disc (`render/forward/shaders.vs`)**:
      added an analytical HDR solar disc + Mie forward-scattering corona
      in `skyFragment` even when an `Environment` map is bound (`hasEnv > 0.5`).
- [x] **Directional aerial perspective & height fog (`render/forward/shaders.vs`)**:
      altitude-dependent height fog + directional Rayleigh/Mie
      in-scattering (warm golden haze toward `sunDir`, cool blue-grey
      atmospheric depth looking away).
- [x] **Moving world-space cloud shadows (`render/forward/shaders.vs`)**:
      procedural drifting world-space cumulus cloud shadows modulating
      direct sunlight across the track, trees, and hills.
- [ ] **Sun shafts / crepuscular rays & subtle lens flare (`render/forward/post.vs`)**:
      radial light shafts / screen-space sun flare when the sun passes
      behind the gantry or treeline.

---

## 3. Ground, Track Surface & Surrounding Terrain (`mesh/height`, `flora/grass`, `track`)

- [x] **Real 3D terrain under and around the track (`mesh/height` + `look/scenery.vs`)**:
      replaced the flat `Y = -0.012` grass plane with a continuous 3D
      `mesh/height.Field` terrain chunk grid (`height.Chunk`) conformal to
      the track ribbon, with trackside embankments, infield mounds, and
      seamless outer hills.
- [x] **Asphalt micro-detail, specular glints & racing-line wear (`render/forward`, `look/look.vs`)**:
      added `Material.Detail` close-up micro-aggregate normal perturbation
      and roughness variation in `render/forward/shaders.vs`, plus
      normal-mapped worn road paint (`Lines`, `Grid`, `Finish`).
- [x] **3D sculpted kerbs & rumble strips (`track/meshes.vs`, `look/textures.vs`)**:
      upgraded `kerb()` to a 7-column 3D sculpted FIA rumble profile with
      sawtooth serrations every `1.5 m`, concrete block seams, and rubber
      apex scuffing.
- [x] **3D grass blades & ground cover near the track (`flora/grass`)**:
      created reusable `flora/grass` package (`grass.Atlas`, `grass.Tuft`)
      scattering instanced 3D arched grass clumps along the inner and
      outer verges with wind sway and root-to-tip shading.

---

## 4. Trees, Foliage & Trackside Scenery (`flora/tree`, `look/scenery.vs`)

- [x] **Upgraded 3D conifer trees (`flora/tree/atlas.vs`, `flora/tree/grow.vs`)**:
      eliminated black mipmap borders in `tree.Atlas`, added secondary
      shoots and denser needles, baked 3D radial/vertical canopy ambient
      occlusion (`shadeCanopy`) into vertex colors, added an inner
      mottled foliage core, and replaced the 7-sided `LOD 2` cones with
      organic bough spray crowns.
- [x] **Removed unused grandstand/crowd & added motorsport trackside details (`look/scenery.vs`)**:
      removed the unused grandstand/crowd block per design direction;
      added curved-post alpha-masked FIA debris catch fencing above the
      outside concrete barrier, space-frame start gantry towers with
      light visors, and `150m`/`100m`/`50m` corner brake marker boards.
- [ ] **Deciduous tree species & octahedral impostors (`flora/tree`)**:
      broadleaf deciduous species (birch, oak, maple) and baked
      multi-angle octahedral impostor cards for ultra-far forest rings.

---

## 5. Cars, Reflections, Decals & VFX (`render/forward`, `render/particle`, `look`)

- [x] **Upgraded reflection probes & road reflections (`look/look.vs`)**:
      included `Asphalt`, `Lines`, `Kerbs`, and `Finish` in reflection
      probe captures (`inProbe: true`) so the player car reflects the
      road surface and kerbs rushing underneath.
- [x] **Particle effects (`render/particle`, `look/look.vs`)**:
      created reusable `render/particle` package (`ShockPlume`,
      `SmokePuff`, `SoftPuff`) for multi-fin shock-diamond nitro exhaust
      plumes and volumetric tire smoke/vapor puffs under slip or boost.
- [ ] **Track decals (`render/forward` or `track`)**:
      persistent dynamic tire skidmarks laid down along wheel paths when
      sliding/braking hard, plus pre-laid rubber/oil decals at turn-in
      and apex zones.
- [ ] **More cars & data-driven specs (`physics/vehicle`, `assets/cars/`)**:
      read `vehicle.Spec` from JSON and add 2–3 distinct open-source
      high-poly glTF sports/supercars with proper PBR clearcoat, brake
      calipers, interior, and glowing taillights.

---

## 6. Post-Processing, Anti-Aliasing & Speed (`render/forward`, `look/hud.vs`)

- [x] **High-speed radial motion blur & chromatic aberration (`render/forward/post.vs`, `look/look.vs`)**:
      added `Post.SpeedBlur` and `Post.ChromaticAberration` driven by car
      speed and nitro boost in `finalFragment`.
- [x] **Fast HUD & CPU draw loop (`look/hud.vs`)**:
      streamlined speedometer arc geometry so the full HUD renders in
      `1.6 ms` on CPU alongside GPU dirty-rect upload.
- [ ] **TAA (Temporal Anti-Aliasing) (`render/forward/post.vs`)**:
      sub-pixel Halton camera jitter + velocity/reprojection history buffer
      with variance neighbourhood clamping.
- [ ] **GTAO & contact shadows (`render/forward/post.vs`, `shaders.vs`)**:
      horizon-based ambient occlusion accumulated temporally through TAA,
      plus short screen-space contact shadows.
- [ ] **3D color-grading LUT (`render/forward/post.vs`, `image/color`)**:
      support a 16³ or 32³ color LUT (or AgX / filmic curve) for
      punchy contrast and highlight roll-off.

---

## 7. Gameplay, Physics, AI & Audio Polish

- [ ] **Vehicle physics (`physics/vehicle`)**: manual/sequential gearbox
      option, tire temperature & grip wear, visual panel damage &
      scratches.
- [ ] **Rival AI (`race/driver.vs`)**: difficulty presets, defensive line
      blocking, slipstream/drafting overtakes, occasional apex mistakes.
- [ ] **Audio (`media/spatial`, `sound`)**: wall slap-back reflections in
      turns, Doppler pitch shift on rivals, multi-layer RPM samples
      blended with synthesis.
- [ ] **Maps & Menus**:
      - **Map 2 (Grand Circuit)**: a closed road course with left/right
        esses, a hairpin, and elevation changes over `mesh/height`.
      - **Map 3 (Night Street Circuit)**: wet asphalt with screen-space
        reflections (`SSR`) and overhead streetlamps/neon.
      - **Garage & Pause UI (`.vsx`)**: car & paint picker using
        `ui/viewport`, camera/audio/difficulty settings.
