// nitro-velocity: a street-racing game.
// The first track is the Sunny Oval: three laps against four rivals on a
// summer afternoon. Beat them to the flag.
//
//     vsc run nitro-velocity -- [--demo seconds] [--car id] [--track data/sunny-oval.json] [--mute] [--scale 0.75] [--no-post] [--no-ao] [--no-reflections]
//
// First choose your car on the grid: ← → (or A D) through the cars,
// Enter to race; the rivals get theirs at random. Then W or ↑ throttle, S or ↓ brake (and reverse when stopped), A D or ← →
// steer, Space handbrake, Shift nitro, C change camera, B look back, R
// put the car back on the track, M mute, H hide the keys, Enter back to
// choosing a car after the flag, Esc quit. --demo drives itself (in
// --car, or the first) for that long and saves screenshots/play-1…4.png
// along the way.
package main

import (
    "entity/run"
    "entity/schedule"
    "fs"
    "gpu"
    "image"
    "image/draw"
    "image/png"
    "math"
    "math/geom"
    "nitro-velocity/look"
    "os/env"
    "nitro-velocity/race"
    "nitro-velocity/sound"
    "nitro-velocity/track"
    "render/chase"
    "render/forward"
    "time"
    "ui/window"
)

let field = ["Kai Mercer", "Rosa Vance", "Jett Okafor", "Mila Sorensen"]

final class Game {
    let circuit: track.Track
    /// The cars there are; which is yours.
    let cars: [race.CarInfo]
    var choice = 0
    /// Choosing a car (the race waits, the camera circles yours).
    var picking = true
    var orbit: float32 = 0
    /// Deals the rivals' cars: new each race, the same while you choose.
    var seed: uint64 = 1
    let view: look.Look
    var racing: race.Race
    let hud: look.HUD
    let audio: sound.Sound
    /// The outer schedule run.Window steps: it steps whichever race is on.
    let ticks = schedule.Schedule(hz: 60)
    var keys: [int32: bool] = [:]
    var cam = chase.Chase()
    var camMode = 0
    var steer: float32 = 0
    var throttle: float32 = 0
    var brake: float32 = 0
    var demo: float64 = 0
    var age: float64 = 0
    var shots = 0
    var fps: float32 = 60
    /// Where a frame's time goes (RUN_TRACE=1): sound, scene, HUD, sound.
    var timing: [float32] = [0, 0, 0, 0]
    var hudParts: [float32] = [0, 0, 0]
    var lastTrace: float64 = 0
    let trace = (env.Get("RUN_TRACE") ?? "") != ""
    // The HUD's overlay: drawn over a clear copy each frame, then sent up.
    var overlayMem: UnsafeMutablePointer<uint8>? = nil
    var overlayWidth = 0
    var overlayHeight = 0
    var overlayTex: gpu.Texture? = nil
    var zeros: [uint8] = []
    /// Where the HUD drew last frame.
    var drew: [draw.IRect] = []

    init(_ t: track.Track, _ cars: [race.CarInfo], _ v: look.Look, mute: bool, demo: float64, car: int) {
        circuit = t
        self.cars = cars
        choice = car
        picking = demo == 0
        seed = Game.freshSeed()
        view = v
        self.demo = demo
        racing = Game.newRace(t, cars, choice, seed)
        hud = look.HUD(racing)
        audio = sound.Sound(racing, play: !mute)
        audio.Muted = mute
        if demo > 0 { racing.Autopilot = true }
        cam.Ground = { _, _ in 0 }
        ticks.Add("race", .frame) { dt in
            if !self.picking { self.racing.Schedule.Run(dt) }
        }
    }

    static func newRace(_ t: track.Track, _ cars: [race.CarInfo], _ choice: int, _ seed: uint64) -> race.Race {
        return race.Race(t, cars: cars, mine: choice, names: field, seed: seed)
    }

    static func freshSeed() -> uint64 {
        let now = time.Timestamp.Now()
        return uint64(now.UnixSeconds) &* 1000003 &+ uint64(now.Nanoseconds)
    }

    // restart is a new race: back to choosing a car (the rivals dealt new
    // ones), or straight on in the demo.
    func restart() {
        seed = Game.freshSeed()
        picking = demo == 0
        racing = Game.newRace(circuit, cars, choice, seed)
        if demo > 0 { racing.Autopilot = true }
        hud.Reset()
        audio.Attach(racing)
        cam.Snap()
    }

    // choose moves to the next car (or back), on the grid where you'll start.
    func choose(_ step: int) {
        choice = (choice + step + cars.count) % cars.count
        racing = Game.newRace(circuit, cars, choice, seed)
        hud.Reset()
        audio.Attach(racing)
    }

    func down(_ k: window.KeyCode) -> bool { return keys[k.rawValue] ?? false }

    // input turns keys into smooth controls: the wheel eases toward full
    // lock and back (faster back to the middle), pedals ramp in quickly.
    func input(_ dt: float32) {
        var want: float32 = 0
        if down(.a) || down(.arrowLeft) { want += 1 }
        if down(.d) || down(.arrowRight) { want -= 1 }
        let rate: float32 = want == 0 || want * steer < 0 ? 6 : 3.2
        steer += math.Clamp(want - steer, -rate * dt, rate * dt)
        let gas: float32 = down(.w) || down(.arrowUp) ? 1 : 0
        let stop: float32 = down(.s) || down(.arrowDown) ? 1 : 0
        throttle += math.Clamp(gas - throttle, -8 * dt, 7 * dt)
        brake += math.Clamp(stop - brake, -10 * dt, 8 * dt)
        var c = racing.PlayerInput
        c.Steer = steer
        c.Throttle = throttle
        c.Brake = brake
        c.Handbrake = down(.space)
        c.Boost = down(.shiftLeft) || down(.shiftRight) ? 1 : 0
        racing.PlayerInput = c
    }

    // Present draws a frame on the GPU and presents it: the scene, the HUD
    // drawn on the host as an overlay and uploaded, the results panel's
    // frost done by the layer. Nothing is read back.
    func Present(_ f: run.Frame, _ layer: gpu.Layer) {
        let dt = f.Dt
        age += float64(dt)
        fps += (1 / math.Max(dt, 0.001) - fps) * 0.05
        if demo == 0 && !picking { input(dt) }
        let c = camera(dt)
        let t0 = time.Instant.Now()
        audio.Update(racing, c, dt: dt)
        audio.Pump()
        let t1 = time.Instant.Now()
        view.Render(racing, c, width: f.Width, height: f.Height)
        let t2 = time.Instant.Now()
        // The HUD, an overlay the frame's size in memory of its own (an
        // array would be copied each time it's written through): where it
        // drew last frame is cleared, it draws, and only where it drew (now
        // or last frame) is sent up, without waiting.
        if overlayWidth != f.Width || overlayHeight != f.Height {
            overlayMem?.deallocate()
            let mem = UnsafeMutablePointer<uint8>.allocate(capacity: f.Width * f.Height * 4)
            mem.initialize(repeating: 0, count: f.Width * f.Height * 4)
            overlayMem = mem
            overlayWidth = f.Width
            overlayHeight = f.Height
            overlayTex = gpu.Texture.Create(device: gpu.Default(), width: f.Width, height: f.Height, format: .rgba8)
            drew = [draw.IRect(0, 0, int32(f.Width), int32(f.Height))]
        }
        let mem = overlayMem!
        let stride = f.Width * 4
        let h0 = time.Instant.Now()
        // Cleared by copying from a row of zeros (a bulk copy; a fill is a
        // loop in this build).
        if zeros.count < stride { zeros = [uint8](repeating: 0, count: stride) }
        zeros.withUnsafeBytes { z in
            for r in drew {
                for y in int(r.Y)..<int(r.Y + r.Height) {
                    UnsafeMutableRawPointer(mem + y * stride + int(r.X) * 4).copyMemory(from: z.baseAddress!, byteCount: int(r.Width) * 4)
                }
            }
        }
        let h1 = time.Instant.Now()
        hud.Fps = fps
        hud.Choosing = picking ? cars[choice] : nil
        hud.ChoiceIndex = choice
        hud.ChoiceCount = cars.count
        hud.Draw(into: draw.Canvas(base: mem, width: int32(f.Width), height: int32(f.Height), stride: int32(stride)), f.Width, f.Height, racing, dt: dt)
        let h2 = time.Instant.Now()
        if let o = overlayTex {
            for r in drew + hud.Dirty {
                o.Upload(x: int(r.X), y: int(r.Y), width: int(r.Width), height: int(r.Height),
                         bytes: UnsafeRawPointer(mem + int(r.Y) * stride + int(r.X) * 4), bytesPerRow: stride)
            }
        }
        drew = hud.Dirty
        let t3 = time.Instant.Now()
        hudParts[0] += (float32((h1 - h0).AsMicroseconds()) / 1000 - hudParts[0]) * 0.05
        hudParts[1] += (float32((h2 - h1).AsMicroseconds()) / 1000 - hudParts[1]) * 0.05
        hudParts[2] += (float32((t3 - h2).AsMicroseconds()) / 1000 - hudParts[2]) * 0.05
        // The results' frost, in the layer's pixels.
        var backdrop: gpu.Backdrop? = nil
        if let p = hud.Panel {
            let k = float32(layer.Width) / float32(f.Width)
            backdrop = gpu.Backdrop(x: p.x * k, y: p.y * k, width: p.width * k, height: p.height * k, radius: p.radius * k, strength: p.strength)
        }
        if let scene = view.Renderer.Color {
            layer.Present(scene, overlay: overlayTex, backdrop: backdrop)
            if demo > 0 && shotDue() {
                // What the window shows, read back.
                if let px = layer.Capture(scene, overlay: overlayTex, backdrop: backdrop) { save(px, layer.Width, layer.Height) }
            }
        }
        let t4 = time.Instant.Now()
        audio.Pump()
        timing[0] += (float32((t1 - t0).AsMicroseconds()) / 1000 - timing[0]) * 0.05
        timing[1] += (float32((t2 - t1).AsMicroseconds()) / 1000 - timing[1]) * 0.05
        timing[2] += (float32((t3 - t2).AsMicroseconds()) / 1000 - timing[2]) * 0.05
        timing[3] += (float32((t4 - t3).AsMicroseconds()) / 1000 - timing[3]) * 0.05
        if trace && age - lastTrace > 1 {
            lastTrace = age
            print("  sound \(f2(timing[0])) ms (ran dry \(audio.Underruns)×), scene \(f2(timing[1])) ms, hud \(f2(timing[2])) ms (clear \(f2(hudParts[0])), draw \(f2(hudParts[1])), send \(f2(hudParts[2]))), present \(f2(timing[3])) ms; draws \(view.Renderer.Draws), shadow draws \(view.Renderer.ShadowDraws), reflection draws \(view.Reflections?.Draws ?? 0) (\(view.Reflections?.Ms ?? []) ms)")
        }
    }

    // camera is this frame's view: the chase camera (near or far), or low
    // on the bumper; B looks back.
    func camera(_ dt: float32) -> forward.Camera {
        let car = racing.Player.Car
        if picking {
            // Round your car's front, slowly swinging from one side to the
            // other, low like a showroom shot.
            orbit += dt
            let b = 0.95 * math.Sin(orbit * 0.22)
            let f = car.Forward
            let dir = geom.Vec3(f.X * math.Cos(b) - f.Z * math.Sin(b), 0, f.X * math.Sin(b) + f.Z * math.Cos(b))
            let at = car.Position + geom.Vec3(0, 0.55, 0)
            let eye = at + dir * 5.8 + geom.Vec3(0, 0.5, 0)
            cam.Snap()
            _ = cam.Camera(position: car.Position, facing: car.Forward, velocity: car.Velocity, dt: dt)
            return forward.Camera(eye: eye, target: at - dir * 0.6, fovY: 42 * float32(math.Pi) / 180)
        }
        switch camMode {
        case 1:
            cam.Distance = 8.6
            cam.Height = 2.6
        default:
            cam.Distance = 6.4
            cam.Height = 1.75
        }
        cam.Back = down(.b)
        if camMode == 2 {
            let eye = car.Matrix.TransformPoint(geom.Vec3(0, 0.95, down(.b) ? -2.6 : 1.2))
            let ahead = car.Matrix.TransformPoint(geom.Vec3(0, 0.85, down(.b) ? -30 : 30))
            _ = cam.Camera(position: car.Position, facing: car.Forward, velocity: car.Velocity, dt: dt)
            return forward.Camera(eye: eye, target: ahead, fovY: 66 * float32(math.Pi) / 180 + 12 * float32(math.Pi) / 180 * math.Clamp(car.Speed / 85, 0, 1))
        }
        return cam.Camera(position: car.Position, facing: car.Forward, velocity: car.Velocity, dt: dt)
    }

    // shotDue is whether the demo saves this frame: the lights, the start,
    // a turn mid-race, the flag.
    func shotDue() -> bool {
        switch shots {
        case 0: return racing.Clock > -1.6
        case 1: return racing.Clock > 1.0
        case 2: return racing.Clock > 14
        case 3: return racing.Player.Finished && racing.Clock - racing.Player.FinishTime > 1.2
        default: return false
        }
    }

    // save writes a demo frame to screenshots/play-n.png.
    func save(_ px: [uint8], _ width: int, _ height: int) {
        let name = "screenshots/play-\(shots + 1).png"
        do {
            try fs.WriteFile(fs.Path(name), png.Encode(image.RGBA(width: width, height: height, pixels: px)))
            print("demo: wrote \(name) (\(Int(fps)) fps, \(width)×\(height), \(Int(racing.Player.Car.Speed * 3.6)) km/h, P\(racing.Player.Position))")
        } catch {
            print("demo: \(error)")
        }
        shots += 1
    }

    func Handle(_ win: window.Window, _ e: window.Event) -> bool {
        switch e {
        case .keyDown(let k):
            keys[k.Code.rawValue] = true
            if picking {
                switch k.Code {
                case .arrowLeft, .a:
                    choose(-1)
                case .arrowRight, .d:
                    choose(1)
                case .enter, .space:
                    if !k.Repeat {
                        picking = false
                        cam.Snap()
                    }
                case .escape:
                    return false
                case .m:
                    audio.Muted = !audio.Muted
                default:
                    break
                }
                break
            }
            if k.Repeat { break }
            switch k.Code {
            case .escape:
                return false
            case .c:
                camMode = (camMode + 1) % 3
            case .r:
                racing.Respawn(racing.Player)
            case .m:
                audio.Muted = !audio.Muted
            case .h:
                hud.Help = !hud.Help
            case .enter:
                if racing.Player.Finished { restart() }
            default:
                break
            }
        case .keyUp(let k):
            keys[k.Code.rawValue] = false
        case .focusChanged(let focused):
            if !focused { keys = [:] }
        default:
            break
        }
        return true
    }
}

func f2(_ x: float32) -> string {
    let v = Int((x * 100).rounded())
    return "\(v / 100).\(v % 100 < 10 ? "0" : "")\(v % 100)"
}

func main() async -> int32 {
    let args = CommandLine.arguments
    func flag(_ name: string) -> string? {
        if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
        return nil
    }
    let game: Game
    do {
        let t0 = time.Instant.Now()
        let t = try track.Track.Load(fs.Path(flag("--track") ?? "data/sunny-oval.json"))
        let cars = try race.LoadCars(fs.Path("data/cars.json"))
        var car = 0
        if let want = flag("--car") {
            for (i, c) in cars.enumerated() where c.Id == want || "\(i)" == want { car = i }
        }
        let v = try look.Look(t, cars: cars, assets: fs.Path("assets"), data: fs.Path("data"))
        if args.contains("--no-post") { v.Post = nil }
        if args.contains("--no-ao") { v.Post?.Occlusion = 0 }
        if args.contains("--no-reflections") { v.Reflections = nil }
        let demo = float64(flag("--demo") ?? "") ?? (args.contains("--demo") ? 140 : 0)
        game = Game(t, cars, v, mute: args.contains("--mute"), demo: demo, car: car)
        print("nitro-velocity: \(t.Name), \(Int(t.Length)) m, \(t.Laps) laps, \(cars.count) cars; loaded in \(t0.Elapsed().AsMilliseconds()) ms\(game.audio.Problem.isEmpty ? "" : "; no sound: " + game.audio.Problem)")
    } catch {
        print("nitro-velocity: \(error)")
        return 1
    }
    var o = run.Options()
    // Drawn at the window's own pixels (Retina); --scale 0.75 draws fewer.
    o.Scale = float32(flag("--scale") ?? "") ?? 1
    o.Done = { game.demo > 0 && (game.age > game.demo || game.shots >= 4) }
    let status = await run.Window(title: "Nitro Velocity", options: o, schedule: game.ticks,
                                  present: { f, layer in game.Present(f, layer) },
                                  handle: { w, e in game.Handle(w, e) })
    if game.demo > 0 { print("nitro-velocity: sound ran dry \(game.audio.Underruns) times") }
    game.audio.Close()
    return status
}
