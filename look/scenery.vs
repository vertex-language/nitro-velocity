package look

import (
    "fs"
    "math"
    "math/geom"
    "math/noise"
    "mesh"
    "mesh/height"
    "nitro-velocity/track"
    "scene/scatter"
)

// What stands round the track, built by code, in pieces by material.
// Everything is placed in the main straight's frame (the finish line at
// the origin, the race running +Z, +X the infield) and moved out by
// track's At(0).

/// Scenery is what's round the track, as meshes by material.
struct Scenery {
    var Steel = mesh.Mesh()
    /// Signs, each with its own banner texture.
    var Signs: [(mesh.Mesh, int)] = []
    /// Corner brake distance marker boards (0: "150", 1: "100", 2: "50").
    var BrakeBoards: [(mesh.Mesh, int)] = []
    /// FIA debris catch fencing above the outside wall.
    var Fence: [mesh.Mesh] = []
    /// Fence posts along the outside wall (in world coordinates).
    var WorldSteel: [mesh.Mesh] = []
    /// The start lights' five lenses (each its own, they light one by one).
    var Lenses: [mesh.Mesh] = []
    var Housing = mesh.Mesh()
    var Hills = mesh.Mesh()
    /// 3D heightfield terrain chunks replacing the flat grass plane.
    var Terrain: [mesh.Mesh] = []
}

/// Words on the boards round the track (no one's real marks).
let signWords = ["NITRO VELOCITY", "SUNNY OVAL", "VERTEX RACING", "FULL THROTTLE", "VELOCITY 24"]

// box is an axis-aligned box from lo to hi, its UVs in meters / tile.
func box(_ lo: geom.Vec3, _ hi: geom.Vec3, tile: float32 = 2) -> mesh.Mesh {
    var m = mesh.Box(geom.AABB(min: lo, max: hi))
    // Re-map UVs to world meters so textures don't stretch.
    for i in 0..<m.Positions.count {
        let p = m.Positions[i], n = m.Normals[i]
        let u = math.Abs(n.X) > 0.5 ? p.Z : p.X
        let v = math.Abs(n.Y) > 0.5 ? p.Z : p.Y
        m.UVs[i] = geom.Vec2(u / tile, -v / tile)
    }
    return m
}

/// buildTerrain builds a 3D heightfield (`mesh/height.Field`) around the track:
/// level across the racing ribbon and verges, rising into rolling grassy knolls
/// in the infield and valley foothills outside.
func buildTerrain(_ t: track.Track) -> height.Field {
    let half = t.Grass
    let spacing: float32 = 10
    let count = int(half * 2 / spacing) + 1
    var f = height.Field(width: count, depth: count, spacing: spacing, origin: geom.Vec2(-half, -half), fill: -0.012)
    let n = noise.Simplex(seed: 41)
    var hint = -1
    for j in 0..<count {
        let z = -half + float32(j) * spacing
        for i in 0..<count {
            let x = -half + float32(i) * spacing
            let place = t.Locate(geom.Vec3(x, 0, z), hint: hint)
            hint = place.Index
            var h: float32 = -0.012
            if place.Lateral < 0 {
                let out = -place.Lateral - t.WallOutside
                if out > 16 {
                    let blend = math.Clamp((out - 16) / 55, 0, 1)
                    let smooth = blend * blend * (3 - 2 * blend)
                    let far = math.Clamp((out - 90) / 360, 0, 1)
                    let roll = (n.At(x * 0.0045, z * 0.0045) * 0.5 + 0.5) * 6.5 + n.At(x * 0.014, z * 0.014) * 1.4
                    let foothills = far * far * (26 + 34 * (n.At(x * 0.0018, z * 0.0018) * 0.5 + 0.5))
                    h = -0.012 + smooth * roll + foothills
                }
            } else {
                let inside = place.Lateral - t.WallInside
                if inside > 18 {
                    let blend = math.Clamp((inside - 18) / 48, 0, 1)
                    let smooth = blend * blend * (3 - 2 * blend)
                    let knoll = (n.At(x * 0.006 + 3.1, z * 0.006) * 0.5 + 0.5) * 4.2 + n.At(x * 0.018, z * 0.018) * 0.9
                    h = -0.012 + smooth * knoll
                }
            }
            f.Set(i, j, h)
        }
    }
    return f
}

/// buildScenery makes the start gantry and its lights, FIA catch fencing,
/// brake markers, and 3D terrain & hills.
func buildScenery(_ t: track.Track, _ field: height.Field) -> Scenery {
    var s = Scenery()

    // The start gantry: twin space-frame lattice towers beyond the aprons,
    // a tubular bridge truss across, banners each way, and five hooded
    // twin-lens starting lights facing the cars on the grid.
    let span = t.Edge + t.Apron + 1.6
    for x in [-span, span] {
        for cz in [float32(-0.42), 0.42] {
            s.Steel.Append(box(geom.Vec3(x - 0.16, 0, cz - 0.16), geom.Vec3(x + 0.16, 7.7, cz + 0.16)))
        }
        var h: float32 = 1.2
        while h < 7.2 {
            s.Steel.Append(box(geom.Vec3(x - 0.12, h, -0.42), geom.Vec3(x + 0.12, h + 0.14, 0.42)))
            h += 1.5
        }
    }
    s.Steel.Append(box(geom.Vec3(-span - 0.4, 6.4, -0.6), geom.Vec3(span + 0.4, 7.6, 0.6)))
    s.Housing.Append(box(geom.Vec3(-span - 0.45, 7.55, -0.72), geom.Vec3(span + 0.45, 7.72, 0.72)))
    var front = mesh.Quad(geom.Vec3(span, 6.45, -0.62), geom.Vec3(-span, 6.45, -0.62), geom.Vec3(-span, 7.55, -0.62), geom.Vec3(span, 7.55, -0.62))
    s.Signs.append((front, 0))
    front = mesh.Quad(geom.Vec3(-span, 6.45, 0.62), geom.Vec3(span, 6.45, 0.62), geom.Vec3(span, 7.55, 0.62), geom.Vec3(-span, 7.55, 0.62))
    s.Signs.append((front, 1))
    for i in 0..<5 {
        let x = (float32(i) - 2) * 1.0
        s.Housing.Append(box(geom.Vec3(x - 0.42, 5.25, -0.75), geom.Vec3(x + 0.42, 6.4, -0.35)))
        // Sun visor hoods above each lens pair.
        s.Housing.Append(box(geom.Vec3(x - 0.38, 6.30, -0.96), geom.Vec3(x + 0.38, 6.38, -0.74)))
        s.Housing.Append(box(geom.Vec3(x - 0.38, 5.83, -0.94), geom.Vec3(x + 0.38, 5.90, -0.74)))
        for (y0, _) in [(float32(5.45), 0), (float32(5.9), 1)] {
            s.Lenses.append(mesh.Quad(geom.Vec3(x + 0.3, y0, -0.76), geom.Vec3(x - 0.3, y0, -0.76),
                                      geom.Vec3(x - 0.3, y0 + 0.38, -0.76), geom.Vec3(x + 0.3, y0 + 0.38, -0.76)))
        }
    }

    // FIA debris catch fencing above the outside wall, chunked around the circuit.
    let (fences, posts) = buildCatchFence(t)
    s.Fence = fences
    s.WorldSteel = posts

    // Corner brake distance boards (150m, 100m, 50m) before Turn 1 and Turn 3.
    s.BrakeBoards = buildBrakeBoards(t)

    // 3D terrain chunks from the heightfield (`mesh/height.Chunk`).
    let cellsPerChunk = 16
    var cz = 0
    while cz < field.Depth - 1 {
        var cx = 0
        while cx < field.Width - 1 {
            let chunk = height.Chunk(field, x: cx, z: cz, cells: min(cellsPerChunk, min(field.Width - 1 - cx, field.Depth - 1 - cz)), step: 1, uvScale: 0.2)
            s.Terrain.append(chunk)
            cx += cellsPerChunk
        }
        cz += cellsPerChunk
    }

    // Hills far off: a ring from 720 m to 2.4 km, rising and rolling seamlessly from the terrain edge.
    s.Hills = hills(field)
    return s
}

// buildCatchFence builds chunks of FIA debris fencing and steel posts along
// the top of the outside concrete barrier.
func buildCatchFence(_ t: track.Track) -> ([mesh.Mesh], [mesh.Mesh]) {
    var fences: [mesh.Mesh] = []
    var posts: [mesh.Mesh] = []
    let n = t.Points.count
    let chunkSize = 80
    var a = 0
    while a < n {
        let b = min(n, a + chunkSize)
        var fm = mesh.Mesh()
        var pm = mesh.Mesh()
        let at = -t.WallOutside - 0.18
        let y0: float32 = 1.15, y1: float32 = 3.05
        for i in a...b {
            let j = i % n
            let p = t.Points[j], l = t.Lefts[j]
            let s = i == n ? t.Length : t.Distance[j]
            let base = p + l * at
            fm.Positions.append(base + geom.Vec3(0, y0, 0))
            fm.Positions.append(base + geom.Vec3(0, y1, 0))
            fm.Normals.append(l)
            fm.Normals.append(l)
            fm.UVs.append(geom.Vec2(s / 3.0, 1))
            fm.UVs.append(geom.Vec2(s / 3.0, 0))
        }
        for i in 0..<(b - a) {
            let v = uint32(i * 2)
            fm.Indices += [v, v + 1, v + 2, v + 1, v + 3, v + 2]
        }
        var nextPost = t.Distance[a]
        for i in a..<b {
            let j = i % n
            if t.Distance[j] < nextPost { continue }
            nextPost = t.Distance[j] + 6.0
            let p = t.Points[j] + t.Lefts[j] * (at - 0.06)
            let yaw = math.Atan2(t.Tangents[j].X, t.Tangents[j].Z)
            var post = mesh.Box(geom.AABB(min: geom.Vec3(-0.045, 1.1, -0.045), max: geom.Vec3(0.045, 3.12, 0.045)))
            post = post.Transformed(by: geom.Translation(p) * geom.RotationY(yaw))
            pm.Append(post)
        }
        fences.append(fm)
        posts.append(pm)
        a = b
    }
    return (fences, posts)
}

// buildBrakeBoards places 150m, 100m, and 50m brake marker boards along the
// outside verge approaching each turn entry.
func buildBrakeBoards(_ t: track.Track) -> [(mesh.Mesh, int)] {
    var out: [(mesh.Mesh, int)] = []
    let n = t.Points.count
    // Find turn entries where curvature transitions from straight to turn.
    var entries: [float32] = []
    var inTurn = false
    for i in 0..<n {
        let k = t.Kerbed(i)
        if k && !inTurn {
            entries.append(t.Distance[i])
        }
        inTurn = k
    }
    let offsets: [(float32, int)] = [(150, 0), (100, 1), (50, 2)]
    for entry in entries {
        for (dist, idx) in offsets {
            var s = entry - dist
            if s < 0 { s += t.Length }
            let (p, dir) = t.At(s, lateral: -(t.Edge + t.Apron + 1.8))
            let left = geom.Vec3.UnitY.Cross(dir).Normalized()
            // Face back toward approaching cars (-dir).
            let p0 = p - left * 0.65 + geom.Vec3(0, 0.15, 0)
            let p1 = p + left * 0.65 + geom.Vec3(0, 0.15, 0)
            let p2 = p + left * 0.65 + geom.Vec3(0, 1.15, 0)
            let p3 = p - left * 0.65 + geom.Vec3(0, 1.15, 0)
            let q = mesh.Quad(p0, p1, p2, p3)
            out.append((q, idx))
        }
    }
    return out
}

// boards are signs along the outside wall: 6 m long, on top of it,
// every 9 m down both straights, facing in.
func boards(_ t: track.Track) -> [(mesh.Mesh, int)] {
    var out: [(mesh.Mesh, int)] = []
    var k = 0
    var s: float32 = 0
    while s < t.Length {
        if math.Abs(t.Turn(s)) < 0.001 && math.Abs(t.Turn(s + 6)) < 0.001 && !(s < 100 || s > t.Length - 100) {
            // Seen from the track, further along is on the left.
            let (a, _) = t.At(s, lateral: -t.WallOutside + 0.1)
            let (b, _) = t.At(s + 6, lateral: -t.WallOutside + 0.1)
            let lo: float32 = 1.2, hi: float32 = 2.3
            let q = mesh.Quad(b + geom.Vec3(0, lo, 0), a + geom.Vec3(0, lo, 0), a + geom.Vec3(0, hi, 0), b + geom.Vec3(0, hi, 0))
            out.append((q, 1 + k % (signWords.count - 1)))
            k += 1
        }
        s += 9
    }
    return out
}

// hills is a ring of rolling mountains far beyond the heightfield terrain.
func hills(_ field: height.Field) -> mesh.Mesh {
    var m = mesh.Mesh()
    let rings = 22, around = 140
    let r0: float32 = 720, r1: float32 = 2400
    let n = noise.Simplex(seed: 41)
    for j in 0...rings {
        let f = float32(j) / float32(rings)
        let r = r0 + (r1 - r0) * f * f
        for i in 0...around {
            let a = float32(i) / float32(around) * 2 * float32(math.Pi)
            let x = math.Cos(a) * r, z = math.Sin(a) * r
            let baseH = field.Sample(math.Clamp(x, -790, 790), math.Clamp(z, -790, 790))
            let rise = math.Clamp((r - r0) / 850, 0, 1)
            let ridge = math.Abs(n.At(x * 0.0016 + 2.3, z * 0.0016))
            let h = baseH * (1 - rise * 0.5) + rise * rise * (62 + 85 * (n.At(x * 0.0011, z * 0.0011) * 0.5 + 0.5) + 28 * ridge) + rise * 18 * n.At(x * 0.004, z * 0.004) - 0.8
            m.Positions.append(geom.Vec3(x, h, z))
            m.UVs.append(geom.Vec2(x / 35, z / 35))
            let g = 0.72 + 0.28 * (n.At(x * 0.009, z * 0.009) * 0.5 + 0.5)
            // Warmer earthy rock tint on high ridges, lush olive on lower slopes.
            let rock = math.Clamp((h - 45) / 70, 0, 1) * 0.22
            m.Colors.append(geom.Vec4(g * (0.86 + rock), g * (0.98 - rock * 0.3), g * (0.78 - rock * 0.2), 1))
        }
    }
    let row = uint32(around + 1)
    for j in 0..<rings {
        for i in 0..<around {
            let v = uint32(j) * row + uint32(i)
            m.Indices += [v, v + 1, v + row, v + 1, v + row + 1, v + row]
        }
    }
    // Normals from the faces.
    m.Normals = [geom.Vec3](repeating: geom.Vec3.Zero, count: m.Positions.count)
    var k = 0
    while k + 2 < m.Indices.count {
        let a = int(m.Indices[k]), b = int(m.Indices[k + 1]), c = int(m.Indices[k + 2])
        let nrm = (m.Positions[b] - m.Positions[a]).Cross(m.Positions[c] - m.Positions[a])
        m.Normals[a] = m.Normals[a] + nrm
        m.Normals[b] = m.Normals[b] + nrm
        m.Normals[c] = m.Normals[c] + nrm
        k += 3
    }
    for i in 0..<m.Normals.count {
        var nn = m.Normals[i].Normalized()
        if nn.Y < 0 { nn = nn * -1 }
        m.Normals[i] = nn
    }
    return m
}

/// Woods are where the trees round the track stand: a list of places for
/// each kind of tree.
struct Woods {
    var Places: [[geom.Mat4]] = []
}

// plant scatters `kinds` kinds of tree (assets/foliage/trees.glb) on the
// 3D terrain:
// thick outside the walls a way back, in clumps in the infield, none near
// the track, the grandstand or the straight's sightlines.
func plant(_ t: track.Track, _ field: height.Field, kinds: int) -> Woods {
    var w = Woods()
    // No [[T]](repeating:count:) yet (vsc_TODO #47).
    for _ in 0..<kinds { w.Places.append([]) }
    let clumps = noise.Simplex(seed: 5)
    var rule = scatter.Rule(spacing: 9)
    rule.Seed = 3
    rule.Variants = kinds
    rule.MinScale = 0.75
    rule.MaxScale = 1.15
    var hint = -1
    rule.Density = { x, z in
        let p = t.Locate(geom.Vec3(x, 0, z), hint: hint)
        hint = p.Index
        let clump = clumps.At(x * 0.008, z * 0.008) * 0.5 + 0.5
        if p.Lateral < 0 {
            // Outside: from 14 m past the wall, thickening, out to 230 m.
            let out = -p.Lateral - t.WallOutside
            if out < 14 || out > 230 { return 0 }
            return math.Clamp((out - 14) / 30, 0.15, 1) * math.Clamp(clump * 1.6 - 0.2, 0, 1)
        }
        // Inside: clumps well clear of the barrier.
        let inside = p.Lateral - t.WallInside
        if inside < 22 { return 0 }
        return math.Clamp(clump * 2 - 1, 0, 0.8)
    }
    for p in scatter.Scatter(min: geom.Vec2(-480, -560), max: geom.Vec2(480, 560), rule) {
        let groundY = field.Sample(p.Position.X, p.Position.Y)
        let at = geom.Translation(geom.Vec3(p.Position.X, groundY - 0.14, p.Position.Y)) * geom.RotationY(p.Yaw) * geom.Scale(geom.Vec3(splat: p.Scale))
        w.Places[p.Variant].append(at)
    }
    return w
}

/// Meadow is where the grass clumps (assets/foliage/grass.glb) stand: a
/// list of places for each clump.
struct Meadow {
    var Places: [[geom.Mat4]] = []
}

// plantGrass scatters 3D grass tufts along the inner and outer verges and
// embankments within sight of the track.
func plantGrass(_ t: track.Track, _ field: height.Field, kinds: int) -> Meadow {
    var m = Meadow()
    for _ in 0..<kinds { m.Places.append([]) }
    let clumps = noise.Simplex(seed: 19)
    var rule = scatter.Rule(spacing: 2.6)
    rule.Seed = 19
    rule.Variants = kinds
    rule.MinScale = 1.0
    rule.MaxScale = 1.6
    var hint = -1
    rule.Density = { x, z in
        let p = t.Locate(geom.Vec3(x, 0, z), hint: hint)
        hint = p.Index
        let edge = t.Edge + t.Apron
        let d = math.Abs(p.Lateral) - edge
        if d < 1.2 || d > 22.0 { return 0 }
        let band = 1.0 - math.Clamp((d - 2.5) / 19.5, 0, 1)
        let c = clumps.At(x * 0.05, z * 0.05) * 0.5 + 0.5
        return band * math.Clamp(c * 1.4 - 0.25, 0, 1)
    }
    for p in scatter.Scatter(min: geom.Vec2(-310, -430), max: geom.Vec2(310, 430), rule) {
        let groundY = field.Sample(p.Position.X, p.Position.Y)
        let at = geom.Translation(geom.Vec3(p.Position.X, groundY, p.Position.Y)) * geom.RotationY(p.Yaw) * geom.Scale(geom.Vec3(splat: p.Scale))
        m.Places[p.Variant].append(at)
        // A second, smaller clump of another kind beside it: a fuller tuft.
        let side = at * geom.Translation(geom.Vec3(0.42, 0, 0.18)) * geom.RotationY(2.1) * geom.Scale(geom.Vec3(splat: 0.8))
        m.Places[(p.Variant + 1) % kinds].append(side)
    }
    return m
}
