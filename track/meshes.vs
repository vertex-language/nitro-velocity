package track

import (
    "math"
    "math/geom"
    "mesh"
)

/// Meshes is what's drawn of a track, each part in chunks along the lap
/// (so the renderer can leave out what's behind the camera).
public struct Meshes {
    /// The racing surface and its aprons (UVs in meters / 8).
    public var Asphalt: [mesh.Mesh] = []
    /// White lines at the edges.
    public var Lines: [mesh.Mesh] = []
    /// Kerbs on the turns (V along the lap in 3 m stripes, red then white).
    public var Kerbs: [mesh.Mesh] = []
    /// The finish line, a checkered strip (UVs over the checker).
    public var Finish: mesh.Mesh = mesh.Mesh()
    /// Painted boxes on the grid.
    public var Grid: mesh.Mesh = mesh.Mesh()
    /// The outside wall: concrete, its face toward the track (UVs in meters / 4).
    public var Wall: [mesh.Mesh] = []
    /// The wall's painted top band.
    public var WallBand: [mesh.Mesh] = []
    /// The inside barrier: steel rails and their posts.
    public var Rails: [mesh.Mesh] = []
    public var Posts: [mesh.Mesh] = []
    /// Grass, in tiles (UVs in meters / 5).
    public var Grass: [mesh.Mesh] = []
    /// The verges: strips 3 m wide along both edges where the grass meets
    /// the aprons, just above the grass (UVs in meters / 5, as the grass),
    /// for worn ground to be painted on.
    public var Verge: [mesh.Mesh] = []

    public init() {}
}

/// Build makes a track's meshes, `chunk` meters of lap at a time.
public func Build(_ t: Track, chunk: float32 = 60) -> Meshes {
    var m = Meshes()
    let n = t.Points.count
    // Chunk boundaries in sample indices.
    var cuts: [int] = [0]
    for i in 1..<n where t.Distance[i] - t.Distance[cuts[cuts.count - 1]] >= chunk { cuts.append(i) }
    cuts.append(n)
    let outerApron = t.Edge + t.Apron
    for c in 0..<(cuts.count - 1) {
        let a = cuts[c], b = cuts[c + 1]
        // The surface and aprons: one ribbon edge to edge.
        m.Asphalt.append(ribbon(t, a, b, -outerApron, outerApron, y: 0, uScale: 1.0 / 8, vScale: 1.0 / 8, across: 12))
        // Edge lines.
        var lines = ribbon(t, a, b, t.Edge - 0.35, t.Edge - 0.1, y: 0.004, uScale: 1, vScale: 1.0 / 8)
        lines.Append(ribbon(t, a, b, -t.Edge + 0.1, -t.Edge + 0.35, y: 0.004, uScale: 1, vScale: 1.0 / 8))
        m.Lines.append(lines)
        // The verges, from just under the aprons' edges out.
        var verge = ribbon(t, a, b, outerApron - 0.15, outerApron + 3, y: -0.006, uScale: 1.0 / 5, vScale: 1.0 / 5, across: 8)
        verge.Append(ribbon(t, a, b, -outerApron - 3, -outerApron + 0.15, y: -0.006, uScale: 1.0 / 5, vScale: 1.0 / 5, across: 8))
        m.Verge.append(verge)
        // Kerbs where it turns, both edges.
        var kerbs = mesh.Mesh()
        var k = a
        while k < b {
            if !t.Kerbed(k) {
                k += 1
                continue
            }
            var e = k
            while e < b && t.Kerbed(e) { e += 1 }
            for side in [float32(1), -1] {
                kerbs.Append(kerb(t, k, min(e + 1, n), side))
            }
            k = e
        }
        if kerbs.VertexCount > 0 { m.Kerbs.append(kerbs) }
        // The outside wall and its band; the inside rails.
        m.Wall.append(wall(t, a, b, -t.WallOutside, height: 1.15, thick: 0.5))
        m.WallBand.append(band(t, a, b, -t.WallOutside, height: 1.15, thick: 0.5))
        let (rails, posts) = armco(t, a, b, t.WallInside)
        m.Rails.append(rails)
        m.Posts.append(posts)
    }
    m.Finish = finish(t)
    m.Grid = grid(t)
    m.Grass = grass(t, tile: 200)
    return m
}

// ribbon is a strip from lateral l0 to l1 over samples a…b (b may be n,
// closing the loop), at height y, facing up, `across` strips wide; U
// across in meters times uScale (or 0…1 when uScale is 1: a painted
// line), V along.
func ribbon(_ t: Track, _ a: int, _ b: int, _ l0: float32, _ l1: float32, y: float32, uScale: float32, vScale: float32, across: int = 1) -> mesh.Mesh {
    var m = mesh.Mesh()
    let n = t.Points.count
    let cols = max(1, across)
    let lineU = uScale >= 1
    for i in a...b {
        let j = i % n
        let p = t.Points[j], l = t.Lefts[j]
        let s = i == n ? t.Length : t.Distance[j]
        for k in 0...cols {
            let f = float32(k) / float32(cols)
            let lat = l0 + (l1 - l0) * f
            m.Positions.append(p + l * lat + geom.Vec3(0, y, 0))
            m.Normals.append(geom.Vec3.UnitY)
            m.UVs.append(geom.Vec2(lineU ? f : lat * uScale, s * vScale))
        }
    }
    let row = uint32(cols + 1)
    for i in 0..<(b - a) {
        for k in 0..<cols {
            let v = uint32(i) * row + uint32(k)
            // Counterclockwise seen from above: l0 is to the right of l1.
            m.Indices += [v, v + row, v + 1, v + 1, v + row, v + row + 1]
        }
    }
    return m
}

// kerb is a raised, sculpted FIA kerb on one side (1 left, -1 right) from
// the track's edge out by its width, over samples a…b: a bevelled inner
// step rising from the asphalt, a crowned top with subtle rumble serrations
// every 1.5 m, and an outer taper back to the apron.
func kerb(_ t: Track, _ a: int, _ b: int, _ side: float32) -> mesh.Mesh {
    var m = mesh.Mesh()
    let n = t.Points.count
    let across = 6
    let profileH: [float32] = [0.003, 0.038, 0.052, 0.054, 0.046, 0.024, 0.003]
    let profileSlope: [float32] = [0.22, 0.14, 0.03, -0.02, -0.09, -0.14, -0.08]
    for i in a..<b {
        let j = i % n
        let p = t.Points[j], l = t.Lefts[j], tg = t.Tangents[j]
        let s = t.Distance[j]
        let tooth = float32(math.Sin(float64(s) * 2.0 * math.Pi / 1.5))
        let toothSlope = float32(math.Cos(float64(s) * 2.0 * math.Pi / 1.5) * (2.0 * math.Pi / 1.5))
        for k in 0...across {
            let f = float32(k) / float32(across)
            let lat = (t.Edge + f * t.Kerb) * side
            let crown = (k >= 1 && k <= 5) ? float32(0.007) * tooth : float32(0)
            let h = profileH[k] + crown
            m.Positions.append(p + l * lat + geom.Vec3(0, h, 0))
            let dLat = profileSlope[k] * side
            let dTan = (k >= 1 && k <= 5) ? float32(0.007) * toothSlope : float32(0)
            m.Normals.append((geom.Vec3.UnitY - l * dLat - tg * dTan).Normalized())
            m.UVs.append(geom.Vec2(f, s / 3))
        }
    }
    let row = uint32(across + 1)
    for i in 0..<(b - a - 1) {
        for k in 0..<across {
            let v = uint32(i) * row + uint32(k)
            // Winding so the top faces up on either side.
            if side > 0 {
                m.Indices += [v, v + row, v + 1, v + 1, v + row, v + row + 1]
            } else {
                m.Indices += [v, v + 1, v + row, v + 1, v + row + 1, v + row]
            }
        }
    }
    return m
}

// wall is a Jersey-profile concrete barrier along lateral `at` (its face
// toward the middle), up to `height - 0.3` where the painted top band
// takes over with zero coplanar overlap.
func wall(_ t: Track, _ a: int, _ b: int, _ at: float32, height: float32, thick: float32) -> mesh.Mesh {
    let toward: float32 = at < 0 ? 1 : -1   // the face's normal, along left
    let back = at - toward * thick
    let split = height - 0.3
    let foot = float32(0.28)
    var m = mesh.Mesh()
    // Sloped Jersey base foot (0 to 0.28 m), vertical face (0.28 m to split), and back.
    m.Append(slanted(t, a, b, at + toward * 0.14, 0, foot, toward, out: -0.14))
    m.Append(side(t, a, b, at, foot, split, toward, uScale: 0.25))
    m.Append(side(t, a, b, back, 0, split, -toward, uScale: 0.25))
    return m
}

// band is the wall's painted top: the upper 0.3 m of the barrier and its
// top cap, meeting wall() cleanly at `height - 0.3` without Z-fighting.
func band(_ t: Track, _ a: int, _ b: int, _ at: float32, height: float32, thick: float32) -> mesh.Mesh {
    let toward: float32 = at < 0 ? 1 : -1
    let back = at - toward * thick
    let split = height - 0.3
    var m = side(t, a, b, at, split, height, toward, uScale: 1.0 / 6)
    m.Append(top(t, a, b, at, back, height))
    m.Append(side(t, a, b, back, split, height, -toward, uScale: 1.0 / 6))
    return m
}

// side is a vertical strip at lateral `at` from y0 to y1, facing `toward`
// (along left); U along the lap.
func side(_ t: Track, _ a: int, _ b: int, _ at: float32, _ y0: float32, _ y1: float32, _ toward: float32, uScale: float32) -> mesh.Mesh {
    var m = mesh.Mesh()
    let n = t.Points.count
    for i in a...b {
        let j = i % n
        let p = t.Points[j], l = t.Lefts[j]
        let s = i == n ? t.Length : t.Distance[j]
        let base = p + l * at
        m.Positions.append(base + geom.Vec3(0, y0, 0))
        m.Positions.append(base + geom.Vec3(0, y1, 0))
        m.Normals.append(l * toward)
        m.Normals.append(l * toward)
        m.UVs.append(geom.Vec2(s * uScale, (1.2 - y0) * 0.5))
        m.UVs.append(geom.Vec2(s * uScale, (1.2 - y1) * 0.5))
    }
    for i in 0..<(b - a) {
        let v = uint32(i * 2)
        if toward > 0 {
            m.Indices += [v, v + 1, v + 2, v + 1, v + 3, v + 2]
        } else {
            m.Indices += [v, v + 2, v + 1, v + 1, v + 2, v + 3]
        }
    }
    return m
}

// top is a flat strip between laterals l0 and l1 at height y, facing up.
func top(_ t: Track, _ a: int, _ b: int, _ l0: float32, _ l1: float32, _ y: float32) -> mesh.Mesh {
    let lo = math.Min(l0, l1), hi = math.Max(l0, l1)
    return ribbon(t, a, b, lo, hi, y: y, uScale: 0.25, vScale: 0.25)
}

// armco is a steel crash barrier at lateral `at` (facing the middle): two
// rails, and posts every 2.5 m.
func armco(_ t: Track, _ a: int, _ b: int, _ at: float32) -> (mesh.Mesh, mesh.Mesh) {
    let toward: float32 = at < 0 ? 1 : -1
    var rails = mesh.Mesh()
    for (y0, y1) in [(float32(0.38), float32(0.56)), (float32(0.6), float32(0.78))] {
        // A beam with a bulge: three faces stepping out and back.
        let mid = (y0 + y1) / 2
        rails.Append(slanted(t, a, b, at, y0, mid, toward, out: 0.06))
        rails.Append(slanted(t, a, b, at, y1, mid, toward, out: 0.06, flip: true))
        rails.Append(side(t, a, b, at - toward * 0.04, y0, y1, -toward, uScale: 0.25))
    }
    var posts = mesh.Mesh()
    let n = t.Points.count
    var next = t.Distance[a]
    for i in a..<b {
        let j = i % n
        if t.Distance[j] < next { continue }
        next = t.Distance[j] + 2.5
        let p = t.Points[j] + t.Lefts[j] * (at - toward * 0.12)
        let yaw = math.Atan2(t.Tangents[j].X, t.Tangents[j].Z)
        var post = mesh.Box(geom.AABB(min: geom.Vec3(-0.06, 0, -0.04), max: geom.Vec3(0.06, 0.85, 0.04)))
        post = post.Transformed(by: geom.Translation(p) * geom.RotationY(yaw))
        posts.Append(post)
    }
    return (rails, posts)
}

// slanted is a strip from height y0 (flush at `at`) to y1 (stood `out`
// toward the middle): one face of a rail's bulge.
func slanted(_ t: Track, _ a: int, _ b: int, _ at: float32, _ y0: float32, _ y1: float32, _ toward: float32, out: float32, flip: bool = false) -> mesh.Mesh {
    var m = mesh.Mesh()
    let n = t.Points.count
    for i in a...b {
        let j = i % n
        let p = t.Points[j], l = t.Lefts[j]
        let s = i == n ? t.Length : t.Distance[j]
        let p0 = p + l * at + geom.Vec3(0, y0, 0)
        let p1 = p + l * (at + toward * out) + geom.Vec3(0, y1, 0)
        let across = p1 - p0
        var nrm = across.Cross(t.Tangents[j]).Normalized()
        if nrm.Dot(l * toward) < 0 { nrm = nrm * -1 }
        m.Positions.append(p0)
        m.Positions.append(p1)
        m.Normals.append(nrm)
        m.Normals.append(nrm)
        m.UVs.append(geom.Vec2(s * 0.25, 0))
        m.UVs.append(geom.Vec2(s * 0.25, 1))
    }
    for i in 0..<(b - a) {
        let v = uint32(i * 2)
        // Wind so the normal side is the front.
        let up = (toward > 0) != flip
        if up {
            m.Indices += [v, v + 1, v + 2, v + 1, v + 3, v + 2]
        } else {
            m.Indices += [v, v + 2, v + 1, v + 1, v + 2, v + 3]
        }
    }
    return m
}

// finish is the checkered strip across the track at the line.
func finish(_ t: Track) -> mesh.Mesh {
    var m = mesh.Mesh()
    let w = t.Edge
    let (p0, d) = t.At(0)
    let l = geom.Vec3.UnitY.Cross(d)
    let back: float32 = 0.9, ahead: float32 = 0.9
    let corners = [p0 - d * back - l * w, p0 - d * back + l * w, p0 + d * ahead + l * w, p0 + d * ahead - l * w]
    for c in corners {
        m.Positions.append(c + geom.Vec3(0, 0.005, 0))
        m.Normals.append(geom.Vec3.UnitY)
    }
    m.UVs = [geom.Vec2(0, 0), geom.Vec2(1, 0), geom.Vec2(1, 1), geom.Vec2(0, 1)]
    m.Indices = [0, 2, 1, 0, 3, 2]
    return m
}

// grid is the painted boxes of the first eight starting places: a line
// across in front of each, and short lines down its sides.
func grid(_ t: Track) -> mesh.Mesh {
    var m = mesh.Mesh()
    for slot in 0..<8 {
        let (p, yaw) = t.Grid(slot)
        let place = geom.Translation(p) * geom.RotationY(yaw)
        for (x0, z0, x1, z1) in [(float32(-1.3), float32(2.6), float32(1.3), float32(2.85)),
                                 (float32(-1.3), float32(0.6), float32(-1.15), float32(2.85)),
                                 (float32(1.15), float32(0.6), float32(1.3), float32(2.85))] {
            var q = mesh.Mesh()
            q.Positions = [geom.Vec3(x0, 0.005, z0), geom.Vec3(x1, 0.005, z0), geom.Vec3(x1, 0.005, z1), geom.Vec3(x0, 0.005, z1)]
            q.Normals = [geom.Vec3.UnitY, geom.Vec3.UnitY, geom.Vec3.UnitY, geom.Vec3.UnitY]
            q.UVs = [geom.Vec2(0, 0), geom.Vec2(1, 0), geom.Vec2(1, 1), geom.Vec2(0, 1)]
            q.Indices = [0, 2, 1, 0, 3, 2]
            m.Append(q.Transformed(by: place))
        }
    }
    return m
}

// grass is the ground round about, square tiles just under the asphalt.
func grass(_ t: Track, tile: float32) -> [mesh.Mesh] {
    var out: [mesh.Mesh] = []
    let half = t.Grass
    var z = -half
    while z < half {
        var x = -half
        while x < half {
            var m = mesh.Mesh()
            // A few cells a tile, so it isn't one huge triangle.
            let cells = 4
            let step = tile / float32(cells)
            for j in 0...cells {
                for i in 0...cells {
                    let px = x + float32(i) * step, pz = z + float32(j) * step
                    m.Positions.append(geom.Vec3(px, -0.012, pz))
                    m.Normals.append(geom.Vec3.UnitY)
                    m.UVs.append(geom.Vec2(px / 5, pz / 5))
                }
            }
            let row = uint32(cells + 1)
            for j in 0..<cells {
                for i in 0..<cells {
                    let v = uint32(j) * row + uint32(i)
                    m.Indices += [v, v + row, v + 1, v + 1, v + row, v + row + 1]
                }
            }
            out.append(m)
            x += tile
        }
        z += tile
    }
    return out
}
