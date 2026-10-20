// check is nitro-velocity without a window: the track is the oval it
// says (its length, its turns, where a point is on it, what's under a
// tire, its walls), the grid is behind the line in the right order, and
// a race run with every car driving itself (you on autopilot) counts
// down, goes green, and everyone finishes the laps: on the road, in the
// walls rarely, never stuck or upside down for long, in sensible lap
// times, each in their own place.
//
//     vsc run check
package main

import (
    "entity/run"
    "fs"
    "media/audio"
    "media/wav"
    "math"
    "math/geom"
    "nitro-velocity/race"
    "nitro-velocity/sound"
    "nitro-velocity/track"
    "physics/vehicle"
    "render/forward"
    "time"
)

var failures = 0

func check(_ ok: bool, _ what: string) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

func main() -> int32 {
    let t: track.Track
    do {
        t = try track.Track.Load(fs.Path("data/sunny-oval.json"))
    } catch {
        check(false, "the track loads: \(error)")
        return 1
    }
    // 2 × 260 m of straight and two half circles of 110 m.
    let want = 2 * 260 + 2 * float32(math.Pi) * 110
    check(math.Abs(t.Length - want) < 4, "the oval is \(Int(t.Length)) m round (\(Int(want)) by its numbers)")
    check(t.Laps == 3 && t.Name == "Sunny Oval", "\(t.Name), \(t.Laps) laps")
    // Points on it are found where they are.
    var worst: float32 = 0
    var s: float32 = 5
    while s < t.Length {
        for lat in [float32(-6), 0, 5] {
            let (p, _) = t.At(s, lateral: lat)
            let q = t.Locate(p)
            var ds = math.Abs(q.S - s)
            if ds > t.Length / 2 { ds = t.Length - ds }
            worst = math.Max(worst, math.Max(ds, math.Abs(q.Lateral - lat)))
        }
        s += 37
    }
    check(worst < 0.6, "a point's place along and across is found again (at worst \(worst) m off)")
    // The turns turn left, by 1/110 m; the straights don't.
    let mid = t.Turn(260 / 2 + 110 * float32(math.Pi) / 2)
    check(math.Abs(mid - 1.0 / 110) < 0.001 && math.Abs(t.Turn(60)) < 0.0005, "turns are left, 1/\(Int(1 / mid)) m; straights are straight")
    // Surfaces.
    let i = t.Index(130 + 110 * 1.5)
    check(t.SurfaceAt(i, lateral: 0) == .asphalt && t.SurfaceAt(i, lateral: t.Edge + 0.5) == .kerb && t.SurfaceAt(i, lateral: t.Edge + 5) == .grass,
          "asphalt, kerbs on the turns, grass beyond")
    let g = t.Ground()
    if let hit = g(geom.Vec3(-110, 1, 30), geom.Vec3(0, -1, 0), 2), let off = g(geom.Vec3(-110 - 15, 1, 30), geom.Vec3(0, -1, 0), 2) {
        check(hit.Grip == 1 && off.Grip < 0.8 && off.Drag > 0, "tires grip on asphalt, less on grass")
    } else {
        check(false, "the ground is under the track")
    }
    let (wp, _) = t.At(50, lateral: -t.WallOutside - 0.3)
    check(t.Wall(wp) != nil && t.Wall(t.At(50).0) == nil, "the outside wall stops what's past it, and only that")
    // The grid: behind the line, pole first.
    let (p0, y0) = t.Grid(0)
    let (p3, _) = t.Grid(3)
    let a0 = t.Locate(p0), a3 = t.Locate(p3)
    check(a0.S > t.Length - 20 && a3.S < a0.S && math.Abs(y0) < 0.05, "the grid is behind the line, pole in front, facing up the straight")

    // A race, everyone driving themselves.
    let field = ["Kai Mercer", "Rosa Vance", "Jett Okafor", "Mila Sorensen"]
    // The cars: each with four wheels under a body, the rivals dealt them
    // at random but all different while there are enough to go round.
    let cars = try! race.LoadCars(fs.Path("data/cars.json"))
    var built = true
    for c in cars {
        let s = c.Spec
        let front = s.Wheels.count == 4 ? s.Wheels[0].Position.Z - s.Wheels[2].Position.Z : 0
        if s.Wheels.count != 4 || front < 2 || front > 3.2 || s.HalfExtents.Z < 1.8 || s.Wheels[0].Radius < 0.28 || s.Wheels[0].Radius > 0.42 {
            print("      \(c.Id): wheelbase \(f2(front)) m, half length \(f2(s.HalfExtents.Z)) m, tire \(f2(s.Wheels.isEmpty ? 0 : s.Wheels[0].Radius)) m")
            built = false
        }
    }
    check(cars.count >= 2 && built, "\(cars.count) cars, each a car's size on four wheels")
    let deal = race.Picks(cars.count, field: field.count, seed: 42)
    var distinct = true
    for i in 0..<deal.count { for j in 0..<i where deal[i] == deal[j] { distinct = false } }
    check(distinct || cars.count < field.count, "the rivals' cars are all different (\(deal))")
    check(race.Picks(cars.count, field: field.count, seed: 7) != deal || race.Picks(cars.count, field: field.count, seed: 9) != deal, "and dealt differently another time")
    let r = race.Race(t, cars: cars, mine: 0, names: field, seed: 42)
    r.Autopilot = true
    check(r.Phase == .countdown && r.Player.Position == 5, "you start at the back, the lights counting")
    var greenAt: float64 = -1
    var worstOff: float32 = 0
    var worstWho = ""
    var knocks = 0
    let t0 = time.Instant.Now()
    var steps = 0
    run.Headless(r.Schedule, seconds: 300) { at in
        steps += 1
        if greenAt < 0 && r.Phase != .countdown { greenAt = at }
        for x in r.Order {
            if r.Phase != .countdown && !x.Finished {
                let off = math.Abs(x.Place.Lateral) - t.Edge
                if off > worstOff {
                    worstOff = off
                    worstWho = "\(x.Name) in the \(r.Cars[x.Model].Name) at \(f2(r.Clock)) s, \(Int(x.Place.S)) m round, \(Int(x.Car.Speed * 3.6)) km/h, lap \(x.Laps)"
                }
            }
            if x.Impact > 2000 { knocks += 1 }
        }
        return !r.Done
    }
    let ms = t0.Elapsed().AsMilliseconds()
    check(greenAt > 3 && greenAt < 4, "green after the lights (\(greenAt) s)")
    check(r.Done, "everyone finishes \(t.Laps) laps (\(r.Results.count) of 5)")
    var lapsOk = true
    var respawns = 0
    var line = ""
    for (k, x) in r.Results.enumerated() {
        respawns += x.Respawns
        if x.Respawns > 0 { print("      \(x.Name) was put back \(x.Respawns)×") }
        if x.BestLap < 25 || x.BestLap > 70 { lapsOk = false }
        line += "\(k + 1). \(x.Name) \(f2(x.FinishTime)) s (best \(f2(x.BestLap)))  "
    }
    print("      \(line)")
    check(lapsOk, "lap times are a sports car's round 1.2 km")
    check(respawns == 0, "no one is put back on the track (\(respawns))")
    check(worstOff < 6, "they keep to the road (at worst \(f2(worstOff)) m past its edge: \(worstWho))")
    var places: [int] = []
    for x in r.Order { places.append(x.Position) }
    check(places == [1, 2, 3, 4, 5], "each in their own place")
    let per = float64(ms) / float64(max(1, steps))
    check(per < 4, "a frame of the race takes \(f2(float32(per))) ms to step (\(steps) frames in \(ms) ms)")
    // Nose in the outside wall at a standstill, turned 80° from the race:
    // it backs out and drives on, without being put back.
    let w = race.Race(t, cars: cars, mine: 0, names: ["Kai Mercer"])
    w.Autopilot = true
    run.Headless(w.Schedule, seconds: 4) { _ in w.Phase == .countdown }
    let stuck = w.Player!
    let (at, _) = t.At(160, lateral: -t.WallOutside + 2.6)
    stuck.Car.Place(at, yaw: t.Yaw(160) - 1.4)
    stuck.Place = t.Locate(at)
    let s0 = stuck.Place.S
    var tick = 0
    run.Headless(w.Schedule, seconds: 10) { _ in
        tick += 1
        if tick % 15 == 0 && CommandLine.arguments.contains("-v") {
            let c = stuck.Car
            print("      \(tick) s \(Int(stuck.Place.S)) lat \(f2(stuck.Place.Lateral)) v \(f2(c.ForwardSpeed)) gear \(c.Gear) th \(f2(stuck.Controls.Throttle)) br \(f2(stuck.Controls.Brake)) st \(f2(stuck.Controls.Steer)) yaw \(f2(c.Yaw - t.Yaw(stuck.Place.S))) imp \(Int(stuck.Impact))")
        }
        return true
    }
    check(stuck.Respawns == 0 && stuck.Place.S > s0 + 60 && math.Abs(stuck.Place.Lateral) < t.Edge + 3,
          "a car stopped nose-first in the wall backs out and drives on (\(Int(stuck.Place.S - s0)) m on, put back \(stuck.Respawns)×)")
    // Sound, made without a device: the grid idling, then racing. Never
    // silent, never past full scale, no NaNs, louder once going; written
    // to a WAV when asked (vsc run check -- --wav out.wav).
    let sr = race.Race(t, cars: cars, mine: 0, names: field, seed: 42)
    sr.Autopilot = true
    let snd = sound.Sound(sr, play: false)
    var samples: [float32] = []
    var grid: float32 = 0, going: float32 = 0, peak: float32 = 0
    var bad = 0
    var frame = 0
    while sr.Clock < 12 {
        sr.Schedule.Run(1.0 / 60)
        let me = sr.Player!
        let cam = forward.Camera(eye: me.Car.Position - me.Car.Forward * 6 + geom.Vec3(0, 2, 0), target: me.Car.Position)
        snd.Update(sr, cam, dt: 1.0 / 60)
        let block = snd.Render(frames: 800)
        var e: float32 = 0
        for x in block {
            if x != x { bad += 1 }
            peak = math.Max(peak, math.Abs(x))
            e += x * x
        }
        let rms = math.Sqrt(e / float32(block.count))
        if sr.Clock < -0.5 && sr.Clock > -2.5 { grid = math.Max(grid, rms) }
        if sr.Clock > 6 { going = math.Max(going, rms) }
        samples += block
        frame += 1
    }
    check(bad == 0 && peak <= 1, "the sound is clean: no NaNs, peak \(f2(peak))")
    check(grid > 0.02 && going > 0.02, "engines heard on the grid (\(f2(grid * 100))% RMS) and racing (\(f2(going * 100))%)")
    // One engine: at the redline on the throttle it's louder and brighter
    // (more zero crossings) than idling.
    func measure(_ x: [float32]) -> (float32, int) {
        var e: float32 = 0
        var z = 0
        for i in 1..<x.count {
            e += x[i] * x[i]
            if (x[i] < 0) != (x[i - 1] < 0) { z += 1 }
        }
        return (math.Sqrt(e / float32(x.count)), z)
    }
    let (idleRms, idleZ) = measure(sound.Sound.Engine(rpm: 950, load: 0, seconds: 0.5))
    let (fullRms, fullZ) = measure(sound.Sound.Engine(rpm: 7400, load: 1, seconds: 0.5))
    check(fullRms > idleRms * 1.3 && fullZ > idleZ * 2, "an engine flat out is louder and higher than idling (\(f2(fullRms * 100))% vs \(f2(idleRms * 100))%, \(fullZ) vs \(idleZ) crossings)")
    if let i = CommandLine.arguments.firstIndex(of: "--wav"), i + 1 < CommandLine.arguments.count {
        do {
            try fs.WriteFile(fs.Path(CommandLine.arguments[i + 1]), wav.Encode(audio.Buffer(samples: samples, rate: 48000, channels: 2), format: .pcm16))
            print("      wrote \(CommandLine.arguments[i + 1])")
        } catch {
            check(false, "writing the sound: \(error)")
        }
    }
    print(failures == 0 ? "all passed" : "\(failures) failed")
    return failures == 0 ? 0 : 1
}

func f2(_ x: float32) -> string {
    let v = Int((math.Abs(x) * 100).rounded())
    return "\(x < 0 ? "-" : "")\(v / 100).\(v % 100 < 10 ? "0" : "")\(v % 100)"
}
