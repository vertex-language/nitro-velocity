// Package race is nitro-velocity's running race: the cars as entities
// (you and the field), a countdown, laps counted at the line, positions,
// lap times, the walls and the cars knocking into each other, nitro, and
// cars put back on the track when they end up stuck or upside down. The
// schedule steps it at 60 Hz: input → drivers → cars → contacts → rules.
// The window and the headless check both run it; drawing is look's,
// sound is sound's.
package race

import (
    "entity"
    "entity/schedule"
    "math"
    "math/geom"
    "nitro-velocity/track"
    "physics/vehicle"
)

/// Phase is where the race is.
public enum Phase {
    /// Lights counting down; cars held on the line.
    case countdown
    case racing
    /// You've crossed the line for the last time; the rest finish.
    case finished
}

/// Racer is one car in the race and how its race is going.
public final class Racer {
    public let Name: string
    public let Car: vehicle.Car
    public let IsPlayer: bool
    /// Who drives it when you don't: the field always, you after the flag.
    public var Driver: Driver
    /// Which paint (for look).
    public let Paint: int
    /// Which car: an index into the race's Cars.
    public let Model: int
    /// Where it is on the track, and its progress (laps done × length +
    /// meters into this lap; negative on the grid).
    public var Place = track.Place(S: 0, Lateral: 0, Index: -1)
    public var Laps = -1
    public var Progress: float32 = 0
    /// Its place in the order, 1 first.
    public var Position = 1
    /// Seconds into the race when this lap began; the last and best laps.
    public var LapStart: float32 = 0
    public var LastLap: float32 = 0
    public var BestLap: float32 = 0
    public var Finished = false
    public var FinishTime: float32 = 0
    /// Nitro in the bottle (0…1), and whether it's burning.
    public var Nitro: float32 = 0.5
    public var Boosting = false
    /// What it's doing this step.
    public var Controls = vehicle.Controls()
    /// The hardest knock this step (N·s), and the last one's time.
    public var Impact: float32 = 0
    /// Seconds stuck, upside down, or lost; and how often it's been put back.
    var stuck: float32 = 0
    var flipped: float32 = 0
    public private(set) var Respawns = 0

    init(name: string, car: vehicle.Car, player: bool, driver: Driver, paint: int, model: int) {
        Name = name
        Car = car
        IsPlayer = player
        Driver = driver
        Paint = paint
        Model = model
    }
}

/// Race is the race and its schedule.
public final class Race {
    public let Track: track.Track
    public let Entities = entity.World()
    public let Racers: entity.Store<Racer>
    public let Schedule = schedule.Schedule(hz: 60)
    public private(set) var Phase = race.Phase.countdown
    /// Seconds since the green light (negative while counting down).
    public private(set) var Clock: float32 = -3.6
    /// The order now, first to last.
    public private(set) var Order: [Racer] = []
    /// You.
    public private(set) var Player: Racer! = nil
    /// What you're asking of your car; copied in each frame.
    public var PlayerInput = vehicle.Controls()
    /// Your car drives itself (the demo, the check).
    public var Autopilot = false
    /// The order cars crossed the line for the last time.
    public private(set) var Results: [Racer] = []
    /// The cars there are to race; each racer's Model is one of them.
    public let Cars: [CarInfo]

    /// A race on a track: you in `cars[mine]` and a car each for `names`,
    /// picked from `cars` at random by `seed` (Picks says what they got),
    /// you starting from `slot` on the grid (the back by default).
    public init(_ t: track.Track, cars: [CarInfo], mine: int = 0, names: [string], seed: uint64 = 1, slot: int = -1) {
        Track = t
        Cars = cars
        Racers = Entities.Store(Racer.self)
        let picks = Picks(cars.count, field: names.count, seed: seed)
        let count = names.count + 1
        let me = slot < 0 || slot >= count ? count - 1 : slot
        var others = 0
        for k in 0..<count {
            let (p, yaw) = t.Grid(k)
            let player = k == me
            let model = player ? max(0, min(cars.count - 1, mine)) : picks[others % max(1, picks.count)]
            let car = vehicle.Car(cars[model].Spec, at: p, yaw: yaw)
            car.Ground = t.Ground()
            // The field: quick, a little different each.
            let skills: [float32] = [0.985, 0.97, 0.955, 0.945, 0.935, 0.925]
            let lanes: [float32] = [0.6, -0.8, 1.0, -0.4, 0.2, -1.0]
            let skill: float32 = player ? 0.97 : skills[others % 6]
            let d = Driver(t, skill: skill, lane: player ? 0 : lanes[others % 6], seed: uint64(k + 7))
            let r = Racer(name: player ? "You" : names[others], car: car, player: player, driver: d, paint: player ? 0 : others + 1, model: model)
            if !player { others += 1 }
            r.Place = t.Locate(p)
            r.Progress = -(t.Length - r.Place.S)
            let e = Entities.Spawn()
            Racers.Set(e, r)
            if player { Player = r }
        }
        order()
        build()
    }

    // build makes the schedule.
    func build() {
        Schedule.Add("input", .input, writes: ["Racer"]) { _ in
            if !self.Autopilot && !(self.Player.Finished) { self.Player.Controls = self.PlayerInput }
        }
        Schedule.Add("drivers", .fixed, reads: ["Racer"], writes: ["Racer"]) { dt in
            self.drive(dt)
        }
        Schedule.Add("cars", .fixed, reads: ["Racer"], writes: ["Racer"]) { dt in
            self.Racers.Each { _, r in
                r.Car.Step(dt, r.Controls)
            }
        }
        Schedule.Add("contacts", .fixed, writes: ["Racer"]) { dt in
            self.contacts()
        }
        Schedule.Add("rules", .fixed, writes: ["Racer"]) { dt in
            self.rules(dt)
        }
    }

    /// Lights is how many red lights are lit (0…5) during the countdown,
    /// and whether it's gone green.
    public var Lights: (int, bool) {
        if Clock >= 0 { return (0, true) }
        let lit = int((Clock + 3.6) / 0.6)
        return (min(5, max(0, lit)), false)
    }

    // drive asks each driver (and you) what to do this step.
    func drive(_ dt: float32) {
        let held = Phase == .countdown
        Racers.Each { _, r in
            if !r.IsPlayer || self.Autopilot || r.Finished {
                r.Controls = r.Driver.Drive(r, self, dt)
            }
            if held {
                // On the line: brakes on; the engine revs with the throttle.
                r.Controls.Brake = 1
                r.Controls.Handbrake = true
                r.Controls.Boost = 0
            }
            // Nitro: burns while asked for and there's some left.
            r.Boosting = !held && r.Controls.Boost > 0 && r.Nitro > 0.02
            if !r.Boosting { r.Controls.Boost = 0 }
        }
    }

    // contacts keeps cars out of the walls and out of each other.
    func contacts() {
        var cars: [Racer] = []
        Racers.Each { _, r in
            r.Impact = 0
            cars.append(r)
        }
        for r in cars {
            let car = r.Car
            var corners = car.Corners()
            // The bottom four are enough, and the middles of the long sides.
            corners = [corners[0], corners[2], corners[4], corners[6]]
            for p in corners {
                guard let hit = Track.Wall(p, hint: r.Place.Index) else { continue }
                let (n, depth) = hit
                let v = car.Velocity.Dot(n)
                car.Push(at: p, normal: n, depth: depth, friction: 0.25, restitution: 0.2)
                r.Impact = math.Max(r.Impact, -v * car.Spec.Mass * 0.3)
            }
        }
        for i in 0..<cars.count {
            for j in (i + 1)..<cars.count {
                let k = vehicle.Collide(cars[i].Car, cars[j].Car)
                if k > 0 {
                    cars[i].Impact = math.Max(cars[i].Impact, k)
                    cars[j].Impact = math.Max(cars[j].Impact, k)
                }
            }
        }
    }

    // rules moves the clock, counts laps, keeps the order, fills and burns
    // nitro, and puts back cars that are stuck.
    func rules(_ dt: float32) {
        Clock += dt
        if Phase == .countdown && Clock >= 0 {
            Phase = .racing
            Racers.Each { _, r in r.LapStart = 0 }
        }
        let L = Track.Length
        Racers.Each { _, r in
            let before = r.Place.S
            r.Place = self.Track.Locate(r.Car.Position, hint: r.Place.Index)
            let after = r.Place.S
            if before > L * 0.75 && after < L * 0.25 {
                // Over the line, going the right way.
                r.Laps += 1
                if r.Laps >= 1 && !r.Finished {
                    r.LastLap = self.Clock - r.LapStart
                    if r.BestLap == 0 || r.LastLap < r.BestLap { r.BestLap = r.LastLap }
                }
                r.LapStart = self.Clock
                if r.Laps >= self.Track.Laps && !r.Finished {
                    r.Finished = true
                    r.FinishTime = self.Clock
                    self.Results.append(r)
                    if r.IsPlayer { self.Phase = .finished }
                }
            } else if before < L * 0.25 && after > L * 0.75 {
                // Back over it: that lap doesn't count.
                r.Laps -= 1
            }
            r.Progress = float32(r.Laps) * L + r.Place.S
            if r.Finished { r.Progress = float32(self.Track.Laps) * L + 1000 - r.FinishTime }
            // Nitro: a trickle always, more sliding sideways at speed or
            // tucked in behind another car; burns while boosting.
            if self.Phase != .countdown {
                var fill: float32 = 0.025
                let car = r.Car
                let v = car.Velocity
                let slide = math.Abs(math.Atan2(v.Dot(car.Left), math.Max(1, v.Dot(car.Forward))))
                if slide > 0.18 && car.Speed > 14 && car.Grounded >= 3 { fill += 0.22 }
                if self.drafting(r) { fill += 0.06 }
                if r.Boosting { fill = -0.28 }
                r.Nitro = math.Clamp(r.Nitro + fill * dt, 0, 1)
            }
            self.rescue(r, dt)
        }
        order()
    }

    // drafting is whether a car sits in another's slipstream: one ahead
    // within 18 m and nearly in line.
    func drafting(_ r: Racer) -> bool {
        if r.Car.Speed < 20 { return false }
        var found = false
        Racers.Each { _, o in
            if o === r || found { return }
            let d = o.Progress - r.Progress
            if d > 3 && d < 18 && math.Abs(o.Place.Lateral - r.Place.Lateral) < 1.8 { found = true }
        }
        return found
    }

    // rescue puts a car back on the track when it's been upside down,
    // stuck, or off past the walls for a while.
    func rescue(_ r: Racer, _ dt: float32) {
        let car = r.Car
        if car.Up.Y < 0.35 { r.flipped += dt } else { r.flipped = 0 }
        let trying = r.Controls.Throttle > 0.3 || r.Controls.Brake > 0.3
        if Phase != .countdown && car.Speed < 1 && trying { r.stuck += dt } else { r.stuck = math.Max(0, r.stuck - dt) }
        let lost = r.Place.Lateral > Track.WallInside + 4 || r.Place.Lateral < -Track.WallOutside - 4 || car.Position.Y < -5
        if r.flipped > 1.5 || r.stuck > 3.5 || lost {
            Respawn(r)
        }
    }

    /// Respawn puts a car back on the track a little behind where it was,
    /// at the middle, facing the way the race goes, rolling.
    public func Respawn(_ r: Racer) {
        let s = r.Place.S - 6
        let (p, _) = Track.At(s, lateral: math.Clamp(r.Place.Lateral, -Track.Edge * 0.5, Track.Edge * 0.5))
        r.Car.Place(p + geom.Vec3(0, 0.05, 0), yaw: Track.Yaw(s))
        r.Car.Velocity = r.Car.Forward * 8
        r.Place = Track.Locate(p)
        r.stuck = 0
        r.flipped = 0
        r.Respawns += 1
    }

    // order sorts the field: those finished in the order they finished,
    // then everyone else by how far round they are.
    func order() {
        var all: [Racer] = []
        Racers.Each { _, r in all.append(r) }
        all.sort { a, b in a.Progress > b.Progress }
        for (i, r) in all.enumerated() { r.Position = i + 1 }
        Order = all
    }

    /// Done is whether everyone has finished.
    public var Done: bool {
        var all = true
        Racers.Each { _, r in if !r.Finished { all = false } }
        return all
    }

    /// Ahead is the racer just ahead of r on the road (nil if none close):
    /// for the drivers.
    func ahead(of r: Racer, within: float32) -> Racer? {
        var best: Racer? = nil
        var bestD: float32 = within
        let L = Track.Length
        Racers.Each { _, o in
            if o === r { return }
            var d = o.Place.S - r.Place.S
            if d < -L / 2 { d += L }
            if d > L / 2 { d -= L }
            if d > 0 && d < bestD {
                bestD = d
                best = o
            }
        }
        return best
    }
}
