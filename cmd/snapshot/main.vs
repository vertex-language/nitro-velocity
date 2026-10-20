// snapshot draws nitro-velocity without a window, into screenshots/:
// your car close up in the sun, the grid under the lights from behind,
// the field through the first turn, the chase camera at speed, and into
// the sun across the trees, for their shadows.
//
// --car id puts you in that car; --each shoots every car close up
// (screenshots/car-<id>.png) and stops.
//
//     vsc run snapshot -- [width] [height] [--car id] [--each] [--no-ao] [--show-ao] [--no-reflections] [--probe] [--parts]
package main

import (
    "fs"
    "gpu/raster"
    "image"
    "image/png"
    "math"
    "math/geom"
    "nitro-velocity/look"
    "nitro-velocity/race"
    "nitro-velocity/track"
    "render/chase"
    "render/forward"
    "time"
)

func save(_ px: [uint8], _ w: int, _ h: int, _ name: string) {
    do {
        try fs.WriteFile(fs.Path("screenshots/\(name).png"), png.Encode(image.RGBA(width: w, height: h, pixels: px)))
        print("snapshot: wrote screenshots/\(name).png")
    } catch {
        print("snapshot: \(error)")
    }
}

func main() -> int32 {
    let args = CommandLine.arguments
    let w = args.count > 1 ? Int(args[1]) ?? 1280 : 1280
    let h = args.count > 2 ? Int(args[2]) ?? 720 : 720
    let t: track.Track
    let view: look.Look
    let cars: [race.CarInfo]
    do {
        t = try track.Track.Load(fs.Path("data/sunny-oval.json"))
        let t0 = time.Instant.Now()
        cars = try race.LoadCars(fs.Path("data/cars.json"))
        view = try look.Look(t, cars: cars, assets: fs.Path("assets"), data: fs.Path("data"))
        var tris: [int] = []
        for m in view.Cars { tris.append(m.Triangles) }
        print("snapshot: loaded in \(t0.Elapsed().AsMilliseconds()) ms (sky, cars, track: \(view.Timings) ms); the cars are \(tris) triangles")
    } catch {
        print("snapshot: \(error)")
        return 1
    }
    var mine = 0
    if let i = args.firstIndex(of: "--car"), i + 1 < args.count {
        for (k, c) in cars.enumerated() where c.Id == args[i + 1] { mine = k }
    }
    if args.contains("--parts") { for p in view.Cars[mine].Parts { print("  \(p)") } }
    // --no-ao: without ambient occlusion, to compare.
    if args.contains("--no-ao") { view.Post?.Occlusion = 0 }
    if args.contains("--show-ao") { view.Post?.ShowOcclusion = true }
    if args.contains("--no-reflections") { view.Reflections = nil }
    // Each shot is one frame, far from the last: all of the reflections'
    // faces each time.
    view.Reflections?.FacesPerFrame = 6
    let field = ["Kai Mercer", "Rosa Vance", "Jett Okafor", "Mila Sorensen"]
    // --each: every car, three-quarter front and rear, settled on the grid.
    if args.contains("--each") {
        for (k, c) in cars.enumerated() {
            let er = race.Race(t, cars: cars, mine: k, names: field, seed: 3)
            for _ in 0..<70 { er.Schedule.Run(1.0 / 60) }
            let ec = er.Player.Car
            let front = forward.Camera(eye: ec.Matrix.TransformPoint(geom.Vec3(3.6, 0.9, 4.4)), target: ec.Matrix.TransformPoint(geom.Vec3(0, 0.55, 0.2)), fovY: 0.62)
            save(view.Frame(er, front, width: w, height: h), w, h, "car-\(c.Id)")
            let side = forward.Camera(eye: ec.Matrix.TransformPoint(geom.Vec3(-5.2, 0.7, -2.6)), target: ec.Matrix.TransformPoint(geom.Vec3(0, 0.5, -0.2)), fovY: 0.62)
            save(view.Frame(er, side, width: w, height: h), w, h, "car-\(c.Id)-rear")
        }
        // The start: choosing a car, as the game shows it.
        let cr = race.Race(t, cars: cars, mine: 3, names: field, seed: 3)
        for _ in 0..<70 { cr.Schedule.Run(1.0 / 60) }
        let cc = cr.Player.Car
        let at = cc.Position + geom.Vec3(0, 0.55, 0)
        let f = cc.Forward
        let b: float32 = 0.6
        let dir = geom.Vec3(f.X * math.Cos(b) - f.Z * math.Sin(b), 0, f.X * math.Sin(b) + f.Z * math.Cos(b))
        let show = forward.Camera(eye: at + dir * 5.8 + geom.Vec3(0, 0.5, 0), target: at - dir * 0.6, fovY: 42 * float32(math.Pi) / 180)
        var pick = view.Frame(cr, show, width: w, height: h)
        let ph = look.HUD(cr)
        ph.Choosing = cars[3]
        ph.ChoiceIndex = 3
        ph.ChoiceCount = cars.count
        ph.Draw(&pick, w, h, cr, dt: 1.0 / 60)
        save(pick, w, h, "choose")
        return 0
    }
    let r = race.Race(t, cars: cars, mine: mine, names: field, seed: 3)
    r.Autopilot = true
    // Settle on the grid, two lights lit.
    for _ in 0..<70 { r.Schedule.Run(1.0 / 60) }
    let me = r.Player!
    let car = me.Car

    // 1. Your car, three-quarter front, low.
    var p = car.Matrix.TransformPoint(geom.Vec3(3.6, 0.9, 4.4))
    var cam = forward.Camera(eye: p, target: car.Matrix.TransformPoint(geom.Vec3(0, 0.55, 0.2)), fovY: 0.62)
    var t0 = time.Instant.Now()
    save(view.Frame(r, cam, width: w, height: h), w, h, "car-1-front")
    if args.contains("--probe"), let pr = view.Reflections {
        print("snapshot: probe at \(pr.Position), \(pr.Draws) draws")
        let pic = pr.Picture()
        save(pic.Pixels, pic.Width, pic.Height, "probe")
        for f in 0..<6 {
            let fp = pr.Picture(face: f)
            save(fp.Pixels, fp.Width, fp.Height, "probe-face-\(f)")
        }
    }
    print("snapshot: a frame in \(t0.Elapsed().AsMilliseconds()) ms, \(view.ItemsDrawn) items, trees \(view.TreesDrawn)")
    let g = raster.GPUCounters
    print("snapshot: GPU \(view.Renderer.GPU): \(g.Draws) draws, \(g.Fallbacks) fell back to the CPU \(g.LastFailure), \(g.Uploads) uploads, \(g.Readbacks) readbacks")
    // 2. From behind the grid, the gantry ahead.
    p = car.Matrix.TransformPoint(geom.Vec3(-1.5, 2.2, -7))
    cam = forward.Camera(eye: p, target: car.Matrix.TransformPoint(geom.Vec3(1.5, 2.5, 30)), fovY: 0.95)
    save(view.Frame(r, cam, width: w, height: h), w, h, "grid-2-lights")
    // 3. The rear three-quarter, the stand behind.
    p = car.Matrix.TransformPoint(geom.Vec3(-3.4, 1.1, -4.6))
    cam = forward.Camera(eye: p, target: car.Matrix.TransformPoint(geom.Vec3(0, 0.6, 0)), fovY: 0.62)
    save(view.Frame(r, cam, width: w, height: h), w, h, "car-3-rear")

    // 4. Racing: run on to the first turn and look at the field from the
    // outside of it; then the chase camera behind you at speed.
    var ch = chase.Chase()
    var frames = 0
    while r.Clock < 9 {
        r.Schedule.Run(1.0 / 60)
        frames += 1
        _ = ch.Camera(position: car.Position, facing: car.Forward, velocity: car.Velocity, dt: 1.0 / 60)
    }
    let lead = r.Order[0].Car
    let (side, _) = t.At(r.Order[0].Place.S + 30, lateral: -t.Edge - 6)
    cam = forward.Camera(eye: side + geom.Vec3(0, 3.2, 0), target: lead.Position + geom.Vec3(0, 0.5, 0), fovY: 0.5)
    save(view.Frame(r, cam, width: w, height: h), w, h, "turn-4-field")
    cam = ch.Camera(position: car.Position, facing: car.Forward, velocity: car.Velocity, dt: 1.0 / 60)
    t0 = time.Instant.Now()
    save(view.Frame(r, cam, width: w, height: h), w, h, "chase-5")
    print("snapshot: chase frame in \(t0.Elapsed().AsMilliseconds()) ms at \(Int(car.Speed * 3.6)) km/h, \(view.ItemsDrawn) items, trees \(view.TreesDrawn)")
    // 7. Someone on nitro, from behind and low.
    var boosting: race.Racer? = nil
    var guardSteps = 0
    while boosting == nil && guardSteps < 60 * 30 {
        r.Schedule.Run(1.0 / 60)
        guardSteps += 1
        for x in r.Order where x.Boosting { boosting = x }
    }
    if let b = boosting {
        let bc = b.Car
        let bp = bc.Matrix.TransformPoint(geom.Vec3(1.2, 0.8, -5.2))
        let bcam = forward.Camera(eye: bp, target: bc.Matrix.TransformPoint(geom.Vec3(0, 0.45, -1.5)), fovY: 0.6)
        save(view.Frame(r, bcam, width: w, height: h), w, h, "nitro-7")
    }
    // 8. Into the sun from the far turn, across the trees: their
    // shadows, and the cars', fall toward you.
    let sun = view.Light.SunDirection.Normalized()
    let flat = geom.Vec3(sun.X, 0, sun.Z).Normalized()
    for (k, s) in [float32(380), 640].enumerated() {
        let (at, _) = t.At(s, lateral: 0)
        let eye = at + geom.Vec3(0, 7, 0) - flat * 10
        let scam = forward.Camera(eye: eye, target: eye + flat * 60 - geom.Vec3(0, 9, 0), fovY: 0.9)
        save(view.Frame(r, scam, width: w, height: h), w, h, "shadows-\(8 + k)")
    }
    // 10. Low on the outside verge of the far turn: the grass close up,
    // the woods behind.
    do {
        let (at, _) = t.At(420, lateral: -t.Edge - 4)
        let (ahead, _) = t.At(445, lateral: -t.Edge - 9)
        let gcam = forward.Camera(eye: at + geom.Vec3(0, 0.9, 0), target: ahead + geom.Vec3(0, 0.6, 0), fovY: 0.8)
        save(view.Frame(r, gcam, width: w, height: h), w, h, "foliage-10")
    }
    // --bench n: draw the chase frame n times (for a profiler to watch).
    if let i = args.firstIndex(of: "--bench"), i + 1 < args.count, let n = Int(args[i + 1]) {
        let t1 = time.Instant.Now()
        for _ in 0..<n { _ = view.Frame(r, cam, width: w, height: h) }
        print("snapshot: \(n) frames in \(t1.Elapsed().AsMilliseconds()) ms")
        return 0
    }
    // Timing: the chase frame again, whole and with parts left out.
    for skip in [[string](), ["cars"], ["trees"], ["still"], ["cars", "trees", "still"]] {
        view.Skip = skip
        var best: int64 = 100000
        for _ in 0..<4 {
            let t1 = time.Instant.Now()
            _ = view.Frame(r, cam, width: w, height: h)
            best = min(best, t1.Elapsed().AsMilliseconds())
        }
        print("snapshot: without \(skip): \(best) ms (\(view.ItemsDrawn) items)")
    }
    view.Skip = []
    // The HUD over a frame.
    let hud = look.HUD(r)
    var frame = view.Frame(r, cam, width: w, height: h)
    var hudBest: int64 = 100000
    for _ in 0..<5 {
        let t1 = time.Instant.Now()
        hud.Draw(&frame, w, h, r, dt: 1.0 / 60)
        hudBest = min(hudBest, t1.Elapsed().AsMicroseconds())
    }
    print("snapshot: the HUD takes \(hudBest / 1000).\(hudBest % 1000 / 100) ms")
    save(frame, w, h, "hud-6")
    _ = math.Pi
    return 0
}
