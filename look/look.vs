// Package look is how nitro-velocity draws: a summer sky from an HDR
// probe lighting everything (its sun casting the shadows), the track in
// chunks (asphalt with a rubbered line, kerbs, lines, the wall and its
// band, the steel barrier, the checkered line), the grass, a grandstand
// full of people, the start gantry and its lights, boards, trees and the
// hills; and the cars, each in its paint, on soft contact shadows.
package look

import (
    "fs"
    "image/draw"
    "image/hdr"
    "math"
    "math/geom"
    "math/noise"
    "mesh"
    "nitro-velocity/race"
    "nitro-velocity/track"
    "physics/vehicle"
    "render/forward"
    "render/particle"
    "scene/gltf"
    "time"
)

/// Look draws a race.
public final class Look {
    public let Renderer: forward.Renderer
    public let Sky: forward.Environment
    public var Light: forward.Light
    /// How bright the frame is (the sky's light and the sun together).
    public var Exposure: float32 = 0.9
    /// Fog per meter: the haze that sets the hills back.
    public var Fog: float32 = 0.00045
    /// The post stack the frame goes through: bloom off the brake lights,
    /// the start lights and sun glints on the paint, an exposure that
    /// follows the view, a warm summer grade, FXAA. nil draws without it.
    public var Post: forward.Post? = summerPost()
    /// How far from the camera shadows reach, meters.
    public var ShadowDistance: float32 = 300
    /// What your car's paint, chrome and glass reflect: the track, the
    /// gantry, the trees and the others round it, one face of six drawn
    /// a frame. nil: the sky alone.
    public var Reflections: forward.Probe? = nil
    /// Every car's model, in the order of the race's Cars.
    public let Cars: [CarModel]
    /// How long loading took, ms: the sky, the cars, the rest.
    public private(set) var Timings: [int64] = []
    var still: [forward.Item] = []
    var lenses: [forward.Model] = []
    var lensDark = forward.Material()
    /// Each kind of tree's needles and bark, at each level of detail.
    var treeModels: [[forward.Model]] = []
    var treeMaterial = forward.Material()
    var barkModels: [[forward.Model]] = []
    var barkMaterial = forward.Material()
    var groves: [grove] = []
    /// Each grass clump near, and far off (a fifth of its blades).
    var grassModels: [forward.Model] = []
    var grassFar: [forward.Model] = []
    var grassMaterial = forward.Material()
    var grassGroves: [grove] = []
    var blob: forward.Model? = nil
    var blobMaterial = forward.Material()
    var flame: forward.Model? = nil
    var puff: forward.Model? = nil
    var puffTex: forward.Texture? = nil
    let circuit: track.Track
    /// Trees drawn last frame at each level of detail; items drawn.
    public private(set) var TreesDrawn: [int] = [0, 0, 0]
    public private(set) var ItemsDrawn = 0
    /// What to leave out (for timing): "cars", "trees", "still".
    public var Skip: [string] = []

    /// A look at a track, with what's in `assets` (the sky, textures, the
    /// cars' models) and `data` (the trees' species); `cars` are the cars
    /// races will have.
    public init(_ t: track.Track, cars: [race.CarInfo], assets: fs.Path, data: fs.Path, gpu: bool = true) throws {
        circuit = t
        var t0 = time.Instant.Now()
        Renderer = try forward.Renderer(gpu: gpu, shadow: 2048)
        Reflections = Renderer.Probe(size: 128)
        Reflections!.FacesPerFrame = 1
        Reflections!.MinSize = 0.1
        // The sky: a summer afternoon, turned so the sun is behind your left
        // shoulder down the main straight.
        // Cooked once (finding the sun and blurring the reflections takes a
        // while), then read back each time.
        let cooked = assets / "sky/sky_4k.cooked"
        var env: forward.Environment
        if fs.Exists(cooked), let e = try? forward.Environment.Decode(try fs.ReadFile(cooked)) {
            env = e
        } else {
            let sky = try hdr.Decode(try fs.ReadFile(assets / "sky/sky_4k.hdr"))
            env = forward.Environment(sky, ground: geom.Vec3(0.05, 0.085, 0.03))
            try? fs.WriteFile(cooked, env.Encode())
        }
        let want = math.Atan2(float32(0.55), float32(-0.8))
        let has = math.Atan2(env.SunDirection.X, env.SunDirection.Z)
        env.Yaw = want - has
        Sky = env
        Light = env.Lighting(exposure: 0.9)
        Timings.append(t0.Elapsed().AsMilliseconds())

        t0 = time.Instant.Now()
        let plate = Renderer.Upload(plateTexture())
        var models: [CarModel] = []
        for c in cars { models.append(try CarModel(Renderer, path: assets / c.Model, plate: plate)) }
        Cars = models
        Timings.append(t0.Elapsed().AsMilliseconds())
        t0 = time.Instant.Now()
        try load(t, assets: assets, data: data)
        Timings.append(t0.Elapsed().AsMilliseconds())
    }

    // load builds everything but the sky and the car: the track, what's
    // round it, the trees, the shadows under cars and the nitro flames.
    // (Apart from init: a closure over self in an init is refused by
    // vsc's verifier, vsc_TODO #80.)
    func load(_ t: track.Track, assets: fs.Path, data: fs.Path) throws {
        let names = ["asphalt_color.jpg", "asphalt_normal.jpg", "asphalt_rough.jpg", "grass_color.jpg", "grass_normal.jpg",
                     "concrete_color.jpg", "concrete_normal.jpg"]
        var files: [[uint8]] = []
        for n in names { files.append((try? fs.ReadFile(assets / "textures" / n)) ?? []) }
        let decoded = decodeAll(files)
        var tex: [forward.Texture?] = []
        for img in decoded { tex.append(img.map { Renderer.Upload($0) }) }

        // The track.
        let parts = track.Build(t)
        var asphalt = forward.Material()
        asphalt.Base = tex[0]
        asphalt.Normal = tex[1]
        asphalt.NormalStrength = 1.25
        asphalt.MetalRough = tex[2]
        asphalt.Roughness = 0.86
        asphalt.Color = geom.Vec4(0.62, 0.62, 0.64, 1)
        asphalt.VertexPaint = true
        asphalt.Macro = 0.45
        asphalt.MacroColor = geom.Vec3(0.92, 0.90, 0.88)
        asphalt.Detail = 1.0
        var paint = forward.Material()
        paint.Color = geom.Vec4(0.88, 0.88, 0.85, 1)
        paint.Normal = tex[1]
        paint.NormalStrength = 0.45
        paint.Roughness = 0.48
        var kerb = forward.Material()
        kerb.Base = Renderer.Upload(kerbTexture())
        kerb.Normal = tex[6]
        kerb.NormalStrength = 0.55
        kerb.Roughness = 0.42
        kerb.Detail = 0.6
        var finish = forward.Material()
        finish.Base = Renderer.Upload(checker())
        finish.Normal = tex[1]
        finish.NormalStrength = 0.4
        finish.Roughness = 0.52
        var concrete = forward.Material()
        concrete.Base = tex[5]
        concrete.Normal = tex[6]
        concrete.NormalStrength = 1.15
        concrete.Roughness = 0.82
        concrete.Color = geom.Vec4(0.95, 0.95, 0.93, 1)
        concrete.Macro = 0.35
        concrete.Detail = 0.85
        var striped = forward.Material()
        striped.Base = Renderer.Upload(band())
        striped.Normal = tex[6]
        striped.NormalStrength = 0.45
        striped.Roughness = 0.38
        striped.Detail = 0.5
        var steel = forward.Material()
        steel.Color = geom.Vec4(0.78, 0.8, 0.82, 1)
        steel.Metallic = 1
        steel.Roughness = 0.32
        var dark = forward.Material()
        dark.Color = geom.Vec4(0.08, 0.085, 0.09, 1)
        dark.Metallic = 0.6
        dark.Roughness = 0.45
        var grassMat = forward.Material()
        grassMat.Base = tex[3]
        grassMat.Normal = tex[4]
        grassMat.NormalStrength = 1.1
        grassMat.Roughness = 0.92
        // A deep, slightly olive green (the texture is bright), varied
        // over the field: the repeats hidden, drier patches.
        grassMat.Color = geom.Vec4(0.4, 0.5, 0.28, 1)
        grassMat.VertexPaint = true
        grassMat.Macro = 1
        grassMat.Detail = 0.7
        var hillside = grassMat
        hillside.Normal = tex[4]
        hillside.NormalStrength = 0.7
        hillside.Detail = 0.4
        hillside.DoubleSided = true

        // What lies flat on the ground casts no shadow worth drawing.
        func add(_ m: mesh.Mesh, _ mat: forward.Material, flat: bool = false, inProbe: bool = true) throws {
            if m.VertexCount == 0 { return }
            var it = forward.Item(try Renderer.Upload(m), mat)
            if flat {
                it.Shadow = .none
                it.InProbes = inProbe
            }
            let b = m.Bounds()
            it.Center = (b.Min + b.Max) * 0.5
            it.Radius = (b.Max - b.Min).Length() * 0.5 + 0.5
            still.append(it)
        }
        for m in parts.Asphalt { try add(rubbered(t, m), asphalt, flat: true, inProbe: true) }
        for m in parts.Lines { try add(m, paint, flat: true, inProbe: true) }
        for m in parts.Kerbs { try add(m, kerb, flat: true, inProbe: true) }
        try add(parts.Finish, finish, flat: true, inProbe: true)
        try add(parts.Grid, paint, flat: true, inProbe: false)
        for m in parts.Wall { try add(m, concrete) }
        for m in parts.WallBand { try add(m, striped) }
        for m in parts.Rails { try add(m, steel) }
        for m in parts.Posts { try add(m, dark) }

        // 3D heightfield terrain and trackside scenery.
        let field = buildTerrain(t)
        let (origin, _) = t.At(0)
        let frame = geom.Translation(origin) * geom.RotationY(t.Yaw(0))
        let sc = buildScenery(t, field)
        for m in sc.Terrain { try add(mown(m), grassMat, flat: true, inProbe: false) }

        // Where the grass meets the track: worn to earth and grit, darkest
        // at the edge, ragged going out.
        var verge = forward.Material()
        verge.Base = tex[3]
        verge.Blend = tex[0]
        verge.Mix = 0.5
        verge.Normal = tex[4]
        verge.Color = geom.Vec4(0.48, 0.38, 0.26, 1)
        verge.Roughness = 0.95
        verge.Alpha = .blend
        verge.VertexPaint = true
        verge.Detail = 0.6
        for m in parts.Verge { try add(worn(t, m), verge, flat: true, inProbe: false) }

        var fenceMat = forward.Material()
        fenceMat.Base = Renderer.Upload(catchFenceTexture())
        fenceMat.Alpha = .mask
        fenceMat.Cutoff = 0.38
        fenceMat.SoftEdges = false
        fenceMat.DoubleSided = true
        fenceMat.Metallic = 0.5
        fenceMat.Roughness = 0.45
        try add(sc.Steel.Transformed(by: frame), steel)
        try add(sc.Housing.Transformed(by: frame), dark)
        for fm in sc.Fence { try add(fm, fenceMat, flat: true, inProbe: false) }
        for pm in sc.WorldSteel { try add(pm, steel, flat: true, inProbe: false) }
        try add(sc.Hills, hillside, flat: true, inProbe: false)
        var signs: [forward.Texture] = []
        let accents = [draw.Color(255, 60, 20, 255), draw.Color(40, 170, 255, 255), draw.Color(255, 200, 0, 255),
                       draw.Color(230, 30, 90, 255), draw.Color(60, 220, 120, 255)]
        for (i, w) in signWords.enumerated() { signs.append(Renderer.Upload(banner(w, accent: accents[i % accents.count]))) }
        // The stand's and the gantry's signs are in the straight's frame;
        // the boards are in the world already.
        var placedSigns: [(mesh.Mesh, int)] = []
        for (m, k) in sc.Signs { placedSigns.append((m.Transformed(by: frame), k)) }
        placedSigns += boards(t)
        for (m, k) in placedSigns {
            var sign = forward.Material()
            sign.Base = signs[k % signs.count]
            sign.Roughness = 0.4
            try add(m, sign)
        }
        let brakeTex = [Renderer.Upload(brakeBoard("150")), Renderer.Upload(brakeBoard("100")), Renderer.Upload(brakeBoard("50"))]
        for (m, k) in sc.BrakeBoards {
            var bm = forward.Material()
            bm.Base = brakeTex[k % brakeTex.count]
            bm.Roughness = 0.42
            bm.DoubleSided = true
            try add(m, bm)
        }
        for l in sc.Lenses { lenses.append(try Renderer.Upload(l.Transformed(by: frame))) }
        lensDark.Color = geom.Vec4(0.05, 0.02, 0.02, 1)
        lensDark.Roughness = 0.15

        // Trees: the Coniferous Forest Assets Pack's fir, pine and noble fir
        // (assets/foliage/trees.glb), three levels of detail each.
        let woodsKit = try foliage(assets / "foliage/trees.glb")
        let kinds = ["fir", "pine", "noblefir"]
        for k in kinds {
            var leaves: [forward.Model] = []
            var barks: [forward.Model] = []
            for lod in 0..<3 {
                leaves.append(try Renderer.Upload(woodsKit.Meshes["\(k) \(lod) leaves"] ?? mesh.Mesh()))
                barks.append(try Renderer.Upload(woodsKit.Meshes["\(k) \(lod) bark"] ?? mesh.Mesh()))
            }
            treeModels.append(leaves)
            barkModels.append(barks)
        }
        treeMaterial = woodsKit.Materials["Leaves"] ?? forward.Material()
        treeMaterial.Foliage = true
        treeMaterial.SoftEdges = false
        treeMaterial.DoubleSided = true
        barkMaterial = woodsKit.Materials["Bark"] ?? forward.Material()
        let woods = plant(t, field, kinds: kinds.count)
        for (k, places) in woods.Places.enumerated() {
            // By 60 m tile, so each grove is near or far as a whole.
            var tiles: [int: [geom.Mat4]] = [:]
            for p in places {
                let key = int((p.C3.X + 3000) / 60) * 1000 + int((p.C3.Z + 3000) / 60)
                var list = tiles[key] ?? [geom.Mat4]()
                list.append(p)
                tiles[key] = list
            }
            for key in tiles.keys.sorted() {
                let set = Renderer.Instances(tiles[key]!)
                groves.append(grove(model: k, set: set))
            }
        }

        // Grass: four clumps cut from the Realistic Grass 06 scan
        // (assets/foliage/grass.glb), along the verges.
        let grassKit = try foliage(assets / "foliage/grass.glb")
        for k in 0..<4 {
            if let m = grassKit.Meshes["grass \(k)"], let f = grassKit.Meshes["grass \(k) far"] {
                grassModels.append(try Renderer.Upload(m))
                grassFar.append(try Renderer.Upload(f))
            }
        }
        grassMaterial = grassKit.Materials["Grass"] ?? forward.Material()
        grassMaterial.Foliage = true
        grassMaterial.SoftEdges = false
        grassMaterial.DoubleSided = true
        let meadow = plantGrass(t, field, kinds: grassModels.count)
        for (k, places) in meadow.Places.enumerated() {
            var tiles: [int: [geom.Mat4]] = [:]
            for p in places {
                let key = int((p.C3.X + 3000) / 60) * 1000 + int((p.C3.Z + 3000) / 60)
                var list = tiles[key] ?? [geom.Mat4]()
                list.append(p)
                tiles[key] = list
            }
            for key in tiles.keys.sorted() {
                let set = Renderer.Instances(tiles[key]!)
                grassGroves.append(grove(model: k, set: set))
            }
        }

        // A car's contact shadow, shock-diamond nitro plume, and tire smoke puff.
        var b = mesh.Quad(geom.Vec3(1.25, 0.03, -2.6), geom.Vec3(-1.25, 0.03, -2.6), geom.Vec3(-1.25, 0.03, 2.3), geom.Vec3(1.25, 0.03, 2.3))
        b.Normals = [geom.Vec3.UnitY, geom.Vec3.UnitY, geom.Vec3.UnitY, geom.Vec3.UnitY]
        blob = try Renderer.Upload(b)
        blobMaterial.Base = Renderer.Upload(shadowBlob())
        blobMaterial.Color = geom.Vec4(0, 0, 0, 0.72)
        blobMaterial.Alpha = .blend
        blobMaterial.Roughness = 1
        flame = try Renderer.Upload(particle.ShockPlume())
        puff = try Renderer.Upload(particle.SmokePuff())
        puffTex = Renderer.Upload(particle.SoftPuff())
    }

    /// Frame draws the race from a camera and reads the frame back.
    public func Frame(_ r: race.Race, _ camera: forward.Camera, width: int, height: int) -> [uint8] {
        let (items, scene, camera) = prepare(r, camera, width: width, height: height)
        return Renderer.Frame(camera, items, scene)
    }

    /// Render draws the race from a camera and leaves the frame on the GPU
    /// (Renderer.Color), for a window's layer to present.
    public func Render(_ r: race.Race, _ camera: forward.Camera, width: int, height: int) {
        let (items, scene, camera) = prepare(r, camera, width: width, height: height)
        Renderer.Render(camera, items, scene)
    }

    // prepare is a frame's items and scene.
    func prepare(_ r: race.Race, _ camera: forward.Camera, width: int, height: int) -> ([forward.Item], forward.Scene, forward.Camera) {
        Renderer.Resize(width: width, height: height)
        let aspect = float32(width) / float32(max(1, height))
        var items = Skip.contains("still") ? [] : still
        if !Skip.contains("trees") { items += trees(camera, aspect: aspect) }
        // The start lights: red one by one, then all green for a moment.
        let (lit, green) = r.Lights
        for (i, m) in lenses.enumerated() {
            let light = i / 2
            var mat = lensDark
            if green && r.Clock < 2.5 {
                mat.Emissive = geom.Vec3(0.05, 2.2, 0.35)
            } else if !green && light < lit {
                mat.Emissive = geom.Vec3(2.6, 0.03, 0.02)
            }
            items.append(forward.Item(m, mat))
        }
        for x in r.Order where !Skip.contains("cars") {
            let car = x.Car
            if !camera.Sees(car.Position, radius: 3.5, aspect: aspect) { continue }
            let d = (car.Position - camera.Eye).Length()
            let detail = d < 16 ? 0 : (d < 45 ? 1 : 2)
            let braking = x.Controls.Brake > 0.05 && car.ForwardSpeed > 0.5
            let model = Cars[max(0, min(Cars.count - 1, x.Model))]
            var parts = model.Items(car, Paints[x.Paint % Paints.count], braking: braking, detail: detail)
            if x === r.Player, let pr = Reflections {
                pr.Position = car.Position + geom.Vec3(0, 0.6, 0)
                for k in 0..<parts.count { parts[k].Probe = pr }
            }
            items += parts
            guard let b = blob else { continue }
            var shade = forward.Item(b, blobMaterial, at: geom.Translation(geom.Vec3(car.Position.X, 0, car.Position.Z)) * geom.RotationY(car.Yaw))
            shade.Center = car.Position
            shade.Radius = 3
            items.append(shade)
            if x.Boosting { items += flames(car, r.Clock) }
            var maxSkid: float32 = 0
            for w in car.Wheels { maxSkid = math.Max(maxSkid, w.Skid) }
            if d < 75 && (maxSkid > 0.25 || x.Boosting) {
                items += tireSmoke(car, r.Clock, skid: maxSkid, boosting: x.Boosting)
            }
        }
        ItemsDrawn = items.count
        var scene = forward.Scene()
        scene.Background = .sky
        scene.Environment = Sky
        var l = Light
        l.Exposure = Exposure
        scene.Lighting = l
        scene.Fog = Fog
        // Shadows out to the far side of the circuit, in four cascades:
        // the cars sharp, the trees and the gantry casting too.
        scene.ShadowDistance = ShadowDistance
        scene.Cascades = 4
        scene.ShadowStagger = true
        scene.ContactStrength = 0
        scene.Wind = 0.6
        scene.Time = r.Clock
        if var p = Post {
            if let me = r.Player {
                let speedFactor = math.Clamp((math.Abs(me.Car.ForwardSpeed) - 24.0) / 36.0, 0, 1)
                let boostFactor: float32 = me.Boosting ? 1.0 : 0.0
                p.SpeedBlur = speedFactor * 0.28 + boostFactor * 0.55
                p.ChromaticAberration = speedFactor * 0.18 + boostFactor * 0.65
            }
            scene.Post = p
        } else {
            scene.Post = nil
        }
        if let pr = Reflections, r.Player != nil { scene.Probes = [pr] }
        return (items, scene, camera)
    }

    // trees is the woods' and verge grass tufts' instance sets in view, each
    // at the detail its distance calls for.
    func trees(_ camera: forward.Camera, aspect: float32) -> [forward.Item] {
        var out: [forward.Item] = []
        var counts = [0, 0, 0]
        for g in groves {
            let base = forward.Item(treeModels[g.model][0], treeMaterial, instances: g.set)
            if !camera.Sees(base.Center, radius: base.Radius, aspect: aspect) { continue }
            let d = math.Max(0, (g.set.Center - camera.Eye).Length() - g.set.Radius)
            let lod = d < 35 ? 0 : (d < 140 ? 1 : 2)
            var it = forward.Item(treeModels[g.model][lod], treeMaterial, instances: g.set)
            it.Center = base.Center
            it.Radius = base.Radius
            out.append(it)
            var bark = forward.Item(barkModels[g.model][lod], barkMaterial, instances: g.set)
            bark.Center = base.Center
            bark.Radius = base.Radius
            out.append(bark)
            counts[lod] += g.set.Count
        }
        for g in grassGroves {
            let d = math.Max(0, (g.set.Center - camera.Eye).Length() - g.set.Radius)
            if d > 90 { continue }
            var it = forward.Item(d < 25 ? grassModels[g.model] : grassFar[g.model], grassMaterial, instances: g.set)
            if !camera.Sees(it.Center, radius: it.Radius, aspect: aspect) { continue }
            it.Shadow = .none
            it.InProbes = false
            out.append(it)
        }
        TreesDrawn = counts
        return out
    }

    // flames are a boosting car's exhaust: a multi-fin shock-diamond plasma
    // plume with an incandescent core out of each pipe under the rear bumper.
    func flames(_ car: vehicle.Car, _ t: float32) -> [forward.Item] {
        var out: [forward.Item] = []
        guard let flame = flame else { return out }
        for x in [float32(-0.3), 0.3] {
            let flicker = 0.78 + 0.22 * math.Sin(t * 67 + x * 9) * math.Cos(t * 43 + x * 3)
            let roll = t * 19 + x * 5
            for (width, length, glow, alpha) in [(float32(0.088), float32(0.92), geom.Vec3(0.32, 0.78, 3.2), float32(0.42)),
                                                 (float32(0.042), float32(0.56), geom.Vec3(2.2, 2.5, 3.6), float32(0.75))] {
                let place = car.Matrix * geom.Translation(geom.Vec3(x, 0.36, -1.97)) * geom.RotationZ(roll) * geom.Scale(geom.Vec3(width, width, length * flicker))
                var m = forward.Material()
                m.Color = geom.Vec4(0.12, 0.35, 0.95, alpha)
                m.Emissive = glow * flicker
                m.VertexPaint = true
                m.Alpha = .blend
                m.DoubleSided = true
                var it = forward.Item(flame, m, at: place)
                it.Shadow = .none
                it.InProbes = false
                it.Center = car.Position
                it.Radius = 4
                out.append(it)
            }
        }
        return out
    }

    // tireSmoke emits soft, expanding volumetric smoke/vapor puffs behind the
    // rear tires when drifting (high slip) or under heavy nitro boost.
    func tireSmoke(_ car: vehicle.Car, _ t: float32, skid: float32, boosting: bool) -> [forward.Item] {
        var out: [forward.Item] = []
        guard let puff = puff, let puffTex = puffTex else { return out }
        let boostAdd: float32 = boosting ? 0.32 : 0
        let strength = math.Clamp((skid - 0.18) * 0.9 + boostAdd, 0, 0.85)
        if strength <= 0.02 { return out }
        for side in [float32(-0.74), 0.74] {
            for k in 0..<2 {
                let sideOff: float32 = side > 0 ? 0.25 : 0
                let raw = t * 3.8 + float32(k) * 0.5 + sideOff
                let phase = raw - math.Floor(raw)
                let dist: float32 = 1.65 + phase * 2.4
                let radius: float32 = 0.24 + phase * 0.55
                let lift: float32 = 0.16 + phase * 0.28
                let fade: float32 = (1 - phase) * (0.42 - float32(k) * 0.08)
                let alpha = strength * fade
                let place = car.Matrix * geom.Translation(geom.Vec3(side, lift, -dist)) * geom.RotationY(phase * 2.5 + side) * geom.Scale(geom.Vec3(radius, radius * 0.75, radius * 1.25))
                var m = forward.Material()
                m.Base = puffTex
                m.Color = boosting ? geom.Vec4(0.76, 0.82, 0.96, alpha) : geom.Vec4(0.85, 0.86, 0.88, alpha)
                m.VertexPaint = true
                m.Roughness = 0.98
                m.Alpha = .blend
                m.DoubleSided = true
                var it = forward.Item(puff, m, at: place)
                it.Shadow = .none
                it.InProbes = false
                it.Center = car.Position
                it.Radius = 5
                out.append(it)
            }
        }
        return out
    }
}

// rubbered paints the asphalt: darker where the cars run (the middle of
// the road and the line through the turns), dustier at the edges, with
// patches.
func rubbered(_ t: track.Track, _ m: mesh.Mesh) -> mesh.Mesh {
    var out = m
    let n = noise.Simplex(seed: 17)
    var hint = -1
    out.Colors = []
    for p in m.Positions {
        let place = t.Locate(p, hint: hint)
        hint = place.Index
        let a = math.Abs(place.Lateral) / t.Edge
        let line = math.Exp(-(place.Lateral + 1.5) * (place.Lateral + 1.5) / 18)
        let patch = n.At(p.X * 0.05, p.Z * 0.05) * 0.06 + n.At(p.X * 0.3, p.Z * 0.3) * 0.03
        var k = 1 - 0.18 * line + patch
        if a > 1 { k *= 1.12 }
        out.Colors.append(geom.Vec4(k, k, k * 1.01, 1))
    }
    return out
}

// worn paints a verge: how worn (alpha) by how far out from the apron,
// out to a ragged width that wanders along the lap, wider on the turns
// where cars run wide; lighter and darker in clumps.
func worn(_ t: track.Track, _ m: mesh.Mesh) -> mesh.Mesh {
    var out = m
    let n = noise.Simplex(seed: 31)
    var hint = -1
    out.Colors = []
    let apron = t.Edge + t.Apron
    for p in m.Positions {
        let place = t.Locate(p, hint: hint)
        hint = place.Index
        let d = math.Abs(place.Lateral) - apron
        var width = 0.5 + 1.4 * (n.At(p.X * 0.09, p.Z * 0.09) * 0.5 + 0.5)
        if t.Kerbed(place.Index) { width *= 1.6 }
        let rag = n.At(p.X * 0.8, p.Z * 0.8)
        let a = math.Clamp(1 - d / width + rag * 0.25, 0, 1) * 0.9
        let k = 0.9 + 0.15 * n.At(p.X * 0.35 + 5, p.Z * 0.35)
        out.Colors.append(geom.Vec4(k, k, k, a))
    }
    return out
}

// mown paints grass: broad lighter and darker patches, and stripes from
// a mower near the track.
func mown(_ m: mesh.Mesh) -> mesh.Mesh {
    var out = m
    let n = noise.Simplex(seed: 23)
    out.Colors = []
    for p in m.Positions {
        let patch = n.At(p.X * 0.01, p.Z * 0.01) * 0.12 + n.At(p.X * 0.05, p.Z * 0.05) * 0.06
        let r = math.Sqrt(p.X * p.X + p.Z * p.Z)
        let stripe: float32 = int(math.Floor(p.X / 9)) % 2 == 0 ? 1.07 : 0.93
        let mow = math.Clamp(1 - (r - 350) / 150, 0, 1)
        let k = 1 + patch + (stripe - 1) * mow
        let dry = math.Clamp(n.At(p.X * 0.004 + 9, p.Z * 0.004) * 0.5 + 0.5, 0, 1) * 0.12
        out.Colors.append(geom.Vec4(k * (1 + dry), k, k * (1 - dry), 1))
    }
    return out
}

// cone is a flame's shape: a cone along -Z from the origin, a meter long.
func cone() -> mesh.Mesh {
    var m = mesh.Mesh()
    let sides = 10
    for i in 0...sides {
        let a = float32(i) / float32(sides) * 2 * float32(math.Pi)
        let c = math.Cos(a), s = math.Sin(a)
        m.Positions.append(geom.Vec3(c, s, 0))
        m.Normals.append(geom.Vec3(c, s, 0.3).Normalized())
        m.UVs.append(geom.Vec2(float32(i) / float32(sides), 0))
        m.Positions.append(geom.Vec3(0, 0, -1))
        m.Normals.append(geom.Vec3(c, s, 0.3).Normalized())
        m.UVs.append(geom.Vec2(float32(i) / float32(sides), 1))
    }
    for i in 0..<sides {
        let v = uint32(i * 2)
        m.Indices += [v, v + 1, v + 2]
    }
    return m
}

// grove is one tree model's instances in one tile.
// Foliage is a cooked foliage file (assets/foliage/*.glb, from
// assets_src/sketchfab/cook_foliage.py): each node's mesh and each
// material, by name.
final class Foliage {
    var Meshes: [string: mesh.Mesh] = [:]
    var Materials: [string: forward.Material] = [:]
}

extension Look {
    // foliage reads a cooked foliage file onto the renderer.
    func foliage(_ path: fs.Path) throws -> Foliage {
        let doc = try gltf.Load(path)
        let images = decodeAll(doc.Images.map { $0.Bytes })
        var textures: [forward.Texture?] = []
        for img in images { textures.append(img.map { Renderer.Upload($0) }) }
        func tex(_ i: int) -> forward.Texture? {
            if i < 0 || i >= doc.Textures.count { return nil }
            let k = doc.Textures[i].Image
            return k >= 0 && k < textures.count ? textures[k] : nil
        }
        let f = Foliage()
        for g in doc.Materials { f.Materials[g.Name] = material(g, tex) }
        for (i, n) in doc.Nodes.enumerated() where n.Mesh >= 0 {
            var m = mesh.Mesh()
            for prim in doc.Meshes[n.Mesh].Primitives { m.Append(prim.Mesh.Transformed(by: doc.WorldMatrix(i))) }
            f.Meshes[n.Name] = m
        }
        return f
    }
}

struct grove {
    let model: int
    let set: forward.Instances
}

// summerPost is the race's grade: a touch of contrast and warmth, the
// exposure free to open up under the trees and close down facing the sun.
func summerPost() -> forward.Post {
    var p = forward.Post()
    // Only real highlights bloom (brake and start lights, glints), not
    // the bright sky.
    p.Threshold = 1.6
    p.Bloom = 0.06
    // Exposure: the HDR probe's daylight is already set by Exposure; let
    // it move only a little round that.
    p.Key = 0.22
    p.MinExposure = 0.8
    p.MaxExposure = 1.35
    p.AdaptRate = 1.2
    p.Contrast = 1.1
    p.Saturation = 1.05
    p.Tint = geom.Vec3(1.02, 1.0, 0.98)
    p.Vignette = 0.25
    return p
}
