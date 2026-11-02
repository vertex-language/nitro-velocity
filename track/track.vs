// Package track is a circuit: its centerline (an oval of straights and
// half circles, or a smooth loop through points), how wide it is, where
// its kerbs, grass and walls are, its finish line and starting grid, and
// the questions racing asks of it: where along the lap a point is and
// how far off the middle, what the ground under a tire is, whether a
// corner of a car is into a wall. Laps run counterclockwise seen from
// above, so the inside of every turn is on the left.
//
// A track is data (data/*.json); Meshes builds what's drawn of it.
package track

import (
    "encoding/json"
    "fs"
    "math"
    "math/geom"
    "physics/vehicle"
)

/// Surface is what's under a tire.
public enum Surface: int {
    case asphalt = 0
    case kerb = 1
    case grass = 2
}

/// Place is where a point is on the track.
public struct Place {
    /// Meters along the lap from the finish line, 0…Length.
    public var S: float32
    /// Meters left of the centerline (negative: right).
    public var Lateral: float32
    /// The nearest centerline sample.
    public var Index: int

    public init(S: float32, Lateral: float32, Index: int) {
        self.S = S
        self.Lateral = Lateral
        self.Index = Index
    }
}

/// Track is a circuit.
public final class Track {
    public let Name: string
    public let Laps: int
    /// The racing surface's width, the paved apron either side of it, and
    /// the kerbs' width on the turns.
    public let Width: float32
    public let Apron: float32
    public let Kerb: float32
    /// How far from the centerline the walls stand, inside (left) and
    /// outside (right).
    public let WallInside: float32
    public let WallOutside: float32
    /// How far the grass reaches from the middle of the map.
    public let Grass: float32
    /// The lap's length, meters.
    public let Length: float32
    /// The centerline, a sample a meter or so apart: where, how far along,
    /// which way it runs, its left, and how sharply it turns (1/radius,
    /// positive turning left).
    public let Points: [geom.Vec3]
    public let Distance: [float32]
    public let Tangents: [geom.Vec3]
    public let Lefts: [geom.Vec3]
    public let Curvature: [float32]

    /// Load reads a track's JSON.
    public static func Load(path: fs.Path) throws -> Track {
        return try Decode(try fs.ReadText(path))
    }

    /// Decode reads a track from JSON text.
    public static func Decode(text: string) throws -> Track {
        let v = try json.Parse(bytes: [uint8](text.utf8))
        var pts: [geom.Vec3] = []
        if let o = v["oval"] {
            pts = oval(float32(o["straight"]?.Double ?? 250), float32(o["radius"]?.Double ?? 100))
        } else if let ps = v["points"]?.Array {
            var ctrl: [geom.Vec3] = []
            for p in ps {
                if let a = p.Array, a.count == 2 { ctrl.append(geom.Vec3(float32(a[0].Double ?? 0), 0, float32(a[1].Double ?? 0))) }
            }
            pts = loop(ctrl)
        }
        if pts.count < 8 { throw TrackError(Message: "a track needs an oval or at least three points") }
        return Track(name: v["name"]?.String ?? "track", laps: int(v["laps"]?.Int ?? 3), points: pts,
                     width: float32(v["width"]?.Double ?? 14), apron: float32(v["apron"]?.Double ?? 1.5),
                     kerb: float32(v["kerb"]?.Double ?? 1.4), wallInside: float32(v["wallInside"]?.Double ?? 20),
                     wallOutside: float32(v["wallOutside"]?.Double ?? 24), grass: float32(v["grass"]?.Double ?? 1200))
    }

    public init(name: string, laps: int, points: [geom.Vec3], width: float32, apron: float32, kerb: float32,
                wallInside: float32, wallOutside: float32, grass: float32) {
        Name = name
        Laps = laps
        Width = width
        Apron = apron
        Kerb = kerb
        WallInside = wallInside
        WallOutside = wallOutside
        Grass = grass
        Points = points
        let n = points.count
        var dist: [float32] = []
        var d: float32 = 0
        for i in 0..<n {
            dist.append(d)
            d += (points[(i + 1) % n] - points[i]).Length()
        }
        Distance = dist
        Length = d
        var tans: [geom.Vec3] = []
        var lefts: [geom.Vec3] = []
        for i in 0..<n {
            let t = (points[(i + 1) % n] - points[(i + n - 1) % n]).Normalized()
            tans.append(t)
            lefts.append(geom.Vec3.UnitY.Cross(t))
        }
        Tangents = tans
        Lefts = lefts
        var curv: [float32] = []
        for i in 0..<n {
            // Turning per meter, over a few meters either side.
            let a = tans[(i + n - 3) % n], b = tans[(i + 3) % n]
            let span = dist[(i + 3) % n] - dist[(i + n - 3) % n]
            let len = span < 0 ? span + d : span
            let turn = math.Asin(math.Clamp(a.Cross(b).Y, -1, 1))
            curv.append(turn / math.Max(len, 0.1))
        }
        Curvature = curv
    }

    /// Edge is the racing surface's half width.
    public var Edge: float32 { return Width / 2 }

    // ---- where things are ----

    /// Locate finds where a point is: along the lap, and off the middle.
    /// `hint` (an Index from last time) makes it quick for something that
    /// moves a little each step.
    public func Locate(p: geom.Vec3, hint: int = -1) -> Place {
        let n = Points.count
        var best = 0
        var bestD: float32 = 1e30
        if hint >= 0 && hint < n {
            for k in -40...40 {
                let i = (hint + k + n) % n
                let q = Points[i]
                let dx = p.X - q.X, dz = p.Z - q.Z
                let dd = dx * dx + dz * dz
                if dd < bestD { bestD = dd; best = i }
            }
        }
        // Too far from the hint to trust: look everywhere.
        if bestD > 900 {
            for i in 0..<n {
                let q = Points[i]
                let dx = p.X - q.X, dz = p.Z - q.Z
                let dd = dx * dx + dz * dz
                if dd < bestD { bestD = dd; best = i }
            }
        }
        // Between this sample and the next (or the one before).
        var i = best
        let off = p - Points[i]
        var along = off.Dot(Tangents[i])
        if along < 0 {
            i = (i + n - 1) % n
            along = (p - Points[i]).Dot(Tangents[i])
        }
        var s = Distance[i] + along
        if s < 0 { s += Length }
        if s >= Length { s -= Length }
        let lateral = (p - Points[best]).Dot(Lefts[best])
        return Place(S: s, Lateral: lateral, Index: best)
    }

    /// Index is the sample at or before s meters along.
    public func Index(s: float32) -> int {
        var x = s.truncatingRemainder(dividingBy: Length)
        if x < 0 { x += Length }
        // Samples are nearly a meter apart: start near, walk.
        let n = Points.count
        var i = min(n - 1, int(x / Length * float32(n)))
        while i > 0 && Distance[i] > x { i -= 1 }
        while i + 1 < n && Distance[i + 1] <= x { i += 1 }
        return i
    }

    /// At is the point s meters along and `lateral` meters left of the
    /// middle, on the ground; with the way the track runs there.
    public func At(s: float32, lateral: float32 = 0) -> (geom.Vec3, geom.Vec3) {
        let n = Points.count
        var x = s.truncatingRemainder(dividingBy: Length)
        if x < 0 { x += Length }
        let i = Index(x)
        let j = (i + 1) % n
        let seg = (j == 0 ? Length : Distance[j]) - Distance[i]
        let k = seg > 0 ? (x - Distance[i]) / seg : 0
        let p = Points[i] + (Points[j] - Points[i]) * k
        let t = (Tangents[i] + (Tangents[j] - Tangents[i]) * k).Normalized()
        let l = geom.Vec3.UnitY.Cross(t)
        return (p + l * lateral, t)
    }

    /// Turn is how sharply the track turns s meters along (1/radius,
    /// positive left).
    public func Turn(s: float32) -> float32 {
        return Curvature[Index(s)]
    }

    /// Yaw is the heading of the track s meters along (0 down +Z, growing
    /// toward +X, as vehicle.Car's).
    public func Yaw(s: float32) -> float32 {
        let (_, t) = At(s)
        return math.Atan2(t.X, t.Z)
    }

    /// Kerbed is whether a stretch has kerbs: where it turns.
    public func Kerbed(i: int) -> bool {
        return math.Abs(Curvature[i]) > 0.0025
    }

    /// SurfaceAt is what's under a point `lateral` meters off the middle
    /// at sample i.
    public func SurfaceAt(i: int, lateral: float32) -> Surface {
        let a = math.Abs(lateral)
        if a <= Edge { return .asphalt }
        if Kerbed(i) && a <= Edge + Kerb { return .kerb }
        if a <= Edge + Apron && !Kerbed(i) { return .asphalt }
        return .grass
    }

    /// Ground is a vehicle's ground on this track: flat, gripping as the
    /// surface under each tire does, kerbs ridged. Each car wants its own
    /// (it remembers where its wheels were, to look them up quickly).
    public func Ground() -> (geom.Vec3, geom.Vec3, float32) -> vehicle.Hit? {
        let memo = hintBox()
        return { from, dir, length in
            if dir.Y >= -1e-4 { return nil }
            let place = self.Locate(from, hint: memo.index)
            memo.index = place.Index
            let kind = self.SurfaceAt(place.Index, lateral: place.Lateral)
            var y: float32 = 0
            var grip: float32 = 1
            var drag: float32 = 0
            switch kind {
            case .asphalt:
                break
            case .kerb:
                // A low ridge with ribs across it: the tires feel each one.
                let across = (math.Abs(place.Lateral) - self.Edge) / self.Kerb
                let rib = 0.5 + 0.5 * math.Sin(place.S * 2 * float32(math.Pi) / 0.6)
                y = 0.03 * math.Sin(math.Clamp(across, 0, 1) * float32(math.Pi) * 0.5 + 0.6) + 0.008 * rib
                grip = 0.94
                drag = 0.01
            case .grass:
                grip = 0.62
                drag = 0.09
            }
            let t = (y - from.Y) / dir.Y
            if t < 0 || t > length { return nil }
            return vehicle.Hit(point: from + dir * t, normal: geom.Vec3.UnitY, distance: t, grip: grip, drag: drag, surface: kind.rawValue)
        }
    }

    /// Wall is how far a point is into a wall, and the way out; nil when
    /// it's clear of both.
    public func Wall(p: geom.Vec3, hint: int = -1) -> (geom.Vec3, float32)? {
        let place = Locate(p, hint: hint)
        let left = Lefts[place.Index]
        if place.Lateral > WallInside {
            return (left * -1, place.Lateral - WallInside)
        }
        if place.Lateral < -WallOutside {
            return (left, -WallOutside - place.Lateral)
        }
        return nil
    }

    /// Grid is starting place `slot` (0 on pole): two by two behind the
    /// line, the right column a little further back. Its point and yaw.
    public func Grid(slot: int) -> (geom.Vec3, float32) {
        let row = slot / 2, col = slot % 2
        let s = Length - 9 - float32(row) * 10 - float32(col) * 5
        let lateral: float32 = col == 0 ? Width * 0.22 : -Width * 0.22
        let (p, _) = At(s, lateral: lateral)
        return (p, Yaw(s))
    }
}

/// TrackError is a track file that doesn't describe a track.
public struct TrackError: Error, CustomStringConvertible {
    public let Message: string
    public var description: string { return "track: \(Message)" }
}

final class hintBox {
    var index = -1
}

// oval is a stadium's centerline: two straights `straight` meters long
// joined by half circles of `radius`, a sample about every meter, run
// counterclockwise from the middle of the main straight (x = -radius,
// heading +Z).
func oval(straight: float32, radius: float32) -> [geom.Vec3] {
    var pts: [geom.Vec3] = []
    let half = straight / 2
    let arcSteps = max(16, int(float32(math.Pi) * radius))
    let lineSteps = max(4, int(straight))
    // The second half of the main straight.
    for i in 0..<(lineSteps / 2) { pts.append(geom.Vec3(-radius, 0, float32(i) * half / float32(lineSteps / 2))) }
    // The far turn: round the center (0, half), from -X to +X.
    for i in 0..<arcSteps {
        let a = float32(math.Pi) - float32(i) / float32(arcSteps) * float32(math.Pi)
        pts.append(geom.Vec3(radius * math.Cos(a), 0, half + radius * math.Sin(a)))
    }
    // The back straight, heading -Z.
    for i in 0..<lineSteps { pts.append(geom.Vec3(radius, 0, half - float32(i) * straight / float32(lineSteps))) }
    // The near turn: round (0, -half), from +X back to -X.
    for i in 0..<arcSteps {
        let a = -float32(i) / float32(arcSteps) * float32(math.Pi)
        pts.append(geom.Vec3(radius * math.Cos(a), 0, -half + radius * math.Sin(a)))
    }
    // The first half of the main straight, up to the line.
    for i in 0..<(lineSteps / 2) { pts.append(geom.Vec3(-radius, 0, -half + float32(i) * half / float32(lineSteps / 2))) }
    return pts
}

// loop is a smooth closed curve through control points (centripetal
// Catmull-Rom), a sample about every meter.
func loop(c: [geom.Vec3]) -> [geom.Vec3] {
    let n = c.count
    var out: [geom.Vec3] = []
    for i in 0..<n {
        let p0 = c[(i + n - 1) % n], p1 = c[i], p2 = c[(i + 1) % n], p3 = c[(i + 2) % n]
        let steps = max(2, int((p2 - p1).Length()))
        for k in 0..<steps {
            let t = float32(k) / float32(steps)
            let t2 = t * t, t3 = t2 * t
            let p = (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
            out.append(geom.Vec3(p.X, 0, p.Z))
        }
    }
    return out
}
