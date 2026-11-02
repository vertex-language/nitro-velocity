package race

import (
    "math"
    "nitro-velocity/track"
    "physics/vehicle"
)

/// Driver drives a car round a track: along a racing line (wide into a
/// turn, clipping the inside, wide out), as fast as the turns ahead allow
/// at its skill, round slower cars, using its nitro on the straights.
public final class Driver {
    let track: track.Track
    /// How close to the tires' limit it takes the turns (1 the limit).
    public var Skill: float32
    /// Where it likes to be across the road, -1…1 of the room it has.
    public var Lane: float32
    var rand: uint64
    var dodge: float32 = 0
    var wobble: float32 = 0
    var wobbleTime: float32 = 0
    // Backing out of trouble: seconds left of it, and seconds spent
    // stopped facing the wrong way.
    var reversing: float32 = 0
    var trouble: float32 = 0
    /// The speed it wanted last step, m/s (for the check and the HUD's debug).
    public private(set) var Want: float32 = 0

    public init(t: track.Track, skill: float32, lane: float32, seed: uint64) {
        track = t
        Skill = skill
        Lane = lane
        rand = seed &* 0x9E3779B97F4A7C15 | 1
    }

    func next() -> float32 {
        rand ^= rand << 13
        rand ^= rand >> 7
        rand ^= rand << 17
        return float32(rand % 10000) / 10000
    }

    // line is where the racing line runs across the road s meters along:
    // out wide (right, the outside) on the straights, in to the left at
    // the middle of each turn, judged by how much the road turns round it.
    func line(s: float32) -> float32 {
        var turn: float32 = 0
        var k: float32 = -40
        while k <= 40 {
            turn += math.Abs(track.Turn(s + k)) * (1 - math.Abs(k) / 50)
            k += 10
        }
        let c = math.Clamp(turn / 0.045, 0, 1)
        let edge = track.Edge - 1.6
        return (-0.45 + 1.15 * c) * edge
    }

    /// Drive is what to do this step.
    public func Drive(r: Racer, race: Race, dt: float32) -> vehicle.Controls {
        let car = r.Car
        let place = r.Place
        let v = math.Max(0, car.ForwardSpeed)
        // A slow, small drift in where it holds its line, so the field
        // doesn't run on rails.
        wobbleTime -= dt
        if wobbleTime <= 0 {
            wobble = (next() - 0.5) * 1.2
            wobbleTime = 2 + next() * 3
        }
        // Someone ahead and in the way: pick a side and go round.
        var limit: float32 = 1000
        if let o = race.ahead(of: r, within: 30) {
            var gap = o.Place.S - place.S
            if gap < 0 { gap += track.Length }
            let side = o.Place.Lateral - (place.Lateral + dodge)
            if math.Abs(side) < 2.6 && gap < 26 {
                // The side with more road.
                let room = track.Edge - 1.4
                let leftRoom = room - o.Place.Lateral, rightRoom = o.Place.Lateral + room
                let want: float32 = leftRoom > rightRoom ? 2.9 : -2.9
                dodge += (want - dodge) * math.Min(1, dt * 1.5)
                // No room to get by yet: don't drive into its back.
                if gap < 9 && math.Abs(side) < 1.9 { limit = o.Car.ForwardSpeed + gap * 0.5 }
            } else {
                dodge *= 1 - math.Min(1, dt * 0.6)
            }
        } else {
            dodge *= 1 - math.Min(1, dt * 0.6)
        }
        // Someone alongside and close across: give them room.
        race.Racers.Each { _, o in
            if o === r { return }
            var ds = o.Place.S - place.S
            if ds < -self.track.Length / 2 { ds += self.track.Length }
            if ds > self.track.Length / 2 { ds -= self.track.Length }
            let across = (place.Lateral + self.dodge) - o.Place.Lateral
            if math.Abs(ds) < 6 && math.Abs(across) < 2.8 {
                let away: float32 = across >= 0 ? 1 : -1
                self.dodge += away * (2.8 - math.Abs(across)) * math.Min(1, dt * 3)
            }
        }
        dodge = math.Clamp(dodge, -5, 5)
        // Where to aim: ahead along the line, further at speed, and further
        // when well off it (so it merges back rather than cutting across).
        let look = math.Max(math.Max(9, v * 0.75), math.Abs(place.Lateral - line(place.S)) * 2.2)
        let s1 = place.S + look
        let lateral = math.Clamp(line(s1) + Lane * 1.3 + wobble + dodge, -track.Edge + 1.3, track.Edge - 1.3)
        let (target, _) = track.At(s1, lateral: lateral)
        let to = target - car.Position
        let angle = math.Atan2(to.Dot(car.Left), math.Max(0.1, to.Dot(car.Forward)))
        // What the turn here needs before any error: the wheels at the
        // road's angle over the wheelbase, plus the slip the front tires
        // need at this much sideways pull; over the lock the car allows.
        let k = track.Turn(place.S + v * 0.3)
        let grip0 = car.Spec.Friction * 9.81
        let pull = math.Clamp(v * v * math.Abs(k) / grip0, 0, 1)
        let ws = car.Spec.Wheels
        let wheelbase = ws.count == 4 ? (ws[0].Position.Z + ws[1].Position.Z - ws[2].Position.Z - ws[3].Position.Z) / 2 : 2.8
        let needed = math.Atan(wheelbase * k) + (k >= 0 ? 1 : -1) * car.Spec.PeakAngle * pull * 0.9
        let lock = car.Spec.MaxSteer / (1 + v / car.Spec.SteerFalloff)
        // Damp the turn by how fast it's already turning beyond the road's.
        let yawRate = car.AngularVelocity.Y - v * k
        var steer = math.Clamp(needed / lock + angle * 3.2 - yawRate * 0.15, -1, 1)
        // Countersteer when the tail steps out.
        let vel = car.Velocity
        let slip = math.Atan2(vel.Dot(car.Left), math.Max(1, vel.Dot(car.Forward)))
        if math.Abs(slip) > 0.12 && v > 8 { steer = math.Clamp(steer + slip * 1.2, -1, 1) }

        // Stopped and facing well away from the way the race goes (spun,
        // nose in a wall): back out, turning the tail toward the wall so
        // the nose comes round, then go.
        // How far the nose points left of the way the race goes. Backing
        // up with the wheels turned left swings the nose right, and so on.
        let (_, along) = track.At(place.S)
        let roadLeft = track.Lefts[place.Index]
        let facing = math.Atan2(car.Forward.Dot(roadLeft), car.Forward.Dot(along))
        if reversing > 0 {
            reversing -= dt
            // Round far enough: stop backing and go.
            if math.Abs(facing) < 0.7 { reversing = 0 }
            var c = vehicle.Controls()
            c.Brake = 0.7
            c.Steer = facing > 0 ? 1 : -1
            if reversing <= 0 { trouble = 0 }
            Want = 0
            return c
        }
        // Near a wall and pointed well away from the race: back out now,
        // before driving any further into it.
        let nearWall = place.Lateral > track.WallInside - 5 || place.Lateral < -track.WallOutside + 5
        if race.Phase != .countdown && math.Abs(facing) > 1.0 && nearWall && v < 6 {
            trouble += dt * 3
            if trouble > 0.8 { reversing = 2.5 }
        } else if race.Phase != .countdown && car.Speed < 2.5 && (math.Abs(facing) > 0.9 || r.Impact > 0) {
            trouble += dt
            if trouble > 0.8 { reversing = 2.5 }
        } else {
            trouble = math.Max(0, trouble - dt)
        }

        // How fast: the slowest the turns ahead allow, less what it can
        // brake away in the distance to each.
        // Turns taken a margin under the tires' limit (load moving across
        // the car, the rear driving): Skill of that margin.
        let grip = car.Spec.Friction * Skill * 0.86 * 9.81
        var want: float32 = 95
        var d: float32 = 0
        while d <= 170 {
            let k = math.Abs(track.Turn(place.S + d))
            if k > 1e-4 {
                // Downforce adds grip with speed: v² = μ(g + D v²/m) / k.
                let aero = car.Spec.Downforce / car.Spec.Mass * car.Spec.Friction * Skill * 0.86
                let denom = k - aero
                let corner: float32 = denom > 1e-5 ? math.Sqrt(grip / denom) : 95
                let allowed = math.Sqrt(corner * corner + 2 * 8.5 * d)
                want = math.Min(want, allowed)
            }
            d += 6
        }
        // Run wide of the line: ease off until it's back.
        let off = math.Abs(place.Lateral - lateral)
        if off > 2.5 && math.Abs(k) > 0.002 { want *= math.Clamp(1 - (off - 2.5) * 0.04, 0.75, 1) }
        // Off the road it's slower.
        if race.Track.SurfaceAt(place.Index, lateral: place.Lateral) == .grass { want = math.Min(want, 30) }
        want = math.Min(want, limit)
        Want = want
        var c = vehicle.Controls()
        c.Steer = steer
        let err = want - v
        if err > 0 {
            c.Throttle = math.Clamp(0.35 + err * 0.3, 0, 1)
            // Sliding: gently, or the tail keeps coming round.
            if math.Abs(slip) > 0.25 && v > 6 { c.Throttle = math.Min(c.Throttle, 0.25) }
            // Ease off when the rear tires spin.
            var spin: float32 = 0
            for w in car.Wheels where w.Spec.Drives { spin = math.Max(spin, w.SlipAlong) }
            if spin > 1.5 { c.Throttle *= 0.6 }
        } else {
            c.Brake = math.Clamp(-err * 0.18, 0, 1)
        }
        // Nitro on a straight with plenty of it, when not braking soon.
        var straight = true
        var a: float32 = 0
        while a < 120 {
            if math.Abs(track.Turn(place.S + a)) > 0.003 { straight = false }
            a += 15
        }
        if straight && r.Nitro > 0.35 && err > 3 && math.Abs(slip) < 0.1 && race.Phase != .countdown { c.Boost = 1 }
        // A field held back a touch when you're well behind, so it's a race.
        if !r.IsPlayer, let p = race.Player, !p.Finished {
            let behind = r.Progress - p.Progress
            if behind > 120 { c.Throttle *= 0.9 }
        }
        return c
    }
}
