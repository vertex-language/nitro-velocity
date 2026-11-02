package look

import (
    "fs"
    "image"
    "image/format"
    "math"
    "math/geom"
    "mesh"
    "physics/vehicle"
    "render/forward"
    "scene/gltf"
    "sync"
)

/// Paint is a car's look: which of the model's paint variants, and a
/// color laid over its main paint (nil keeps the variant's own).
public struct Paint {
    public var Name: string
    public var Variant: int
    public var Color: geom.Vec4?
    /// The seats and trim, when the paint has its own.
    public var Trim: geom.Vec4?

    public init(name: string, variant: int, color: geom.Vec4? = nil, trim: geom.Vec4? = nil) {
        Name = name
        Variant = variant
        Color = color
        Trim = trim
    }
}

/// Paints are the field's colors: yours first (a deep metallic blue),
/// then a red, a pearl white, graphite, a yellow and a green, laid over
/// each model's own paint.
public let Paints: [Paint] = [
    Paint("Nitro Blue", variant: 0, color: geom.Vec4(0.012, 0.09, 0.62, 1), trim: geom.Vec4(0.02, 0.06, 0.25, 1)),
    Paint("Rosso Corsa", variant: 0, color: geom.Vec4(0.62, 0.015, 0.01, 1)),
    Paint("Pearl White", variant: 0, color: geom.Vec4(0.82, 0.83, 0.84, 1)),
    Paint("Graphite", variant: 0, color: geom.Vec4(0.07, 0.075, 0.08, 1)),
    Paint("Solar Yellow", variant: 0, color: geom.Vec4(0.85, 0.5, 0.0, 1), trim: geom.Vec4(0.1, 0.1, 0.1, 1)),
    Paint("Venom Green", variant: 0, color: geom.Vec4(0.12, 0.55, 0.05, 1), trim: geom.Vec4(0.03, 0.08, 0.03, 1)),
]

// carPart is one draw of the car: a model, the glTF material it shows
// under each variant, and what it moves with.
struct carPart {
    let model: forward.Model
    let slots: [int]
    /// -1 the body; else the wheel it belongs to (vehicle.Car's order).
    let wheel: int
    /// Turns with the wheel (rim, tire, disc) or only steers (caliper).
    let rolls: bool
    /// Inside the cabin: left out far away.
    let inside: bool
    let triangles: int
}

/// CarModel is a car model on the renderer: its parts batched by
/// material, its wheels apart so they can steer and roll.
public final class CarModel {
    let parts: [carPart]
    let materials: [forward.Material]
    let names: [string]
    let variants: int
    /// Each wheel's hub in the car's frame, as modeled.
    public let Hubs: [geom.Vec3]
    /// How many triangles a whole car draws.
    public let Triangles: int
    // What casts the car's shadow: the body and wheels in one model (no
    // cabin, glass or small hardware), one draw instead of every part.
    let shadow: forward.Model

    /// Parts is each draw: its material (variant 0), triangles, wheel, and
    /// whether it's in the cabin (for tuning).
    public var Parts: [string] {
        var out: [string] = []
        for p in parts { out.append("\(p.slots[0] >= 0 ? names[p.slots[0]] : "-") \(p.triangles) w\(p.wheel) \(p.inside ? "in" : "")") }
        return out
    }

    /// Load reads a glTF car (facing +Z, as glTF has it) and puts it on
    /// the renderer, its four wheels matched to vehicle.Car's order (front
    /// left, front right, rear left, rear right; +X is left). `plate`
    /// replaces the license plate's picture.
    public init(r: forward.Renderer, path: fs.Path, plate: forward.Texture? = nil) throws {
        let doc = try gltf.Load(path)
        // Its images, decoded on threads (JPEG and PNG through the system).
        let images = decodeAll(doc.Images.map { $0.Bytes })
        var textures: [forward.Texture?] = []
        for img in images { textures.append(img.map { r.Upload($0) }) }
        func tex(i: int) -> forward.Texture? {
            if i < 0 || i >= doc.Textures.count { return nil }
            let k = doc.Textures[i].Image
            return k >= 0 && k < textures.count ? textures[k] : nil
        }
        var mats: [forward.Material] = []
        var names: [string] = []
        for g in doc.Materials {
            var m = material(g, tex)
            if g.Name == "License", let p = plate { m.Base = p }
            mats.append(m)
            names.append(g.Name)
        }
        materials = mats
        self.names = names
        variants = max(1, doc.Variants.count)

        // Already facing +Z; nothing to turn.
        let turn = geom.Mat4.Identity
        // The wheels: nodes named Wheel… with children, placed by where
        // their hubs are.
        var hubs = [geom.Vec3](repeating: geom.Vec3.Zero, count: 4)
        var wheelOf: [int: int] = [:]
        for (i, n) in doc.Nodes.enumerated() where n.Name.hasPrefix("Wheel") && !n.Children.isEmpty {
            let hub = (turn * doc.WorldMatrix(i)).Position()
            let k = (hub.Z > 0 ? 0 : 2) + (hub.X > 0 ? 0 : 1)
            hubs[k] = hub
            wheelOf[i] = k
        }
        Hubs = hubs
        // Every primitive into a batch: by what it moves with and which
        // material it shows under each variant.
        var batches: [string: mesh.Mesh] = [:]
        var info: [string: (wheel: int, rolls: bool, inside: bool, slots: [int])] = [:]
        var counts: [string: int] = [:]
        var tris = 0
        for (i, n) in doc.Nodes.enumerated() where n.Mesh >= 0 {
            var wheel = -1
            var p = i
            while p >= 0 {
                if let k = wheelOf[p] { wheel = k; break }
                p = doc.Nodes[p].Parent
            }
            let rolls = !n.Name.contains("BrakePad")
            let inside = n.Name.hasPrefix("Interior")
            var place = turn * doc.WorldMatrix(i)
            if wheel >= 0 { place = geom.Translation(geom.Vec3.Zero - hubs[wheel]) * place }
            for prim in doc.Meshes[n.Mesh].Primitives {
                var slots: [int] = []
                for v in 0..<variants { slots.append(prim.MaterialFor(variant: v)) }
                let key = "\(wheel)/\(rolls)/\(inside)/\(slots)"
                var m = batches[key] ?? mesh.Mesh()
                m.Append(prim.Mesh.Transformed(by: place))
                batches[key] = m
                info[key] = (wheel: wheel, rolls: rolls, inside: inside, slots: slots)
                counts[key] = (counts[key] ?? 0) + prim.Mesh.TriangleCount
                tris += prim.Mesh.TriangleCount
            }
        }
        Triangles = tris
        var parts: [carPart] = []
        var proxy = mesh.Mesh()
        for key in batches.keys.sorted() {
            let b = batches[key]!
            let d = info[key]!
            let slot = d.slots[0]
            if !d.inside && slot >= 0 && slot < mats.count && mats[slot].Alpha != .blend && !fine(names[slot]) {
                proxy.Append(d.wheel >= 0 ? b.Transformed(by: geom.Translation(hubs[d.wheel])) : b)
            }
            parts.append(carPart(model: try r.Upload(b), slots: d.slots, wheel: d.wheel, rolls: d.rolls, inside: d.inside, triangles: counts[key] ?? 0))
        }
        self.parts = parts
        shadow = try r.Upload(proxy)
    }

    /// Items draws a car: its body where the car is, each wheel at its
    /// hub, steered and rolled, in a paint; the brake lights bright when
    /// braking. Detail 0 is everything; 1 leaves out the cabin; 2 (far
    /// off) also the wheels' fine spokes, the brakes and small hardware.
    public func Items(car: vehicle.Car, paint: Paint, braking: bool, detail: int) -> [forward.Item] {
        var out: [forward.Item] = []
        let body = car.Matrix
        let v = min(paint.Variant, variants - 1)
        var wheels: [geom.Mat4] = []
        var calipers: [geom.Mat4] = []
        for i in 0..<min(4, car.Wheels.count) {
            wheels.append(car.WheelMatrix(i))
            calipers.append(body * geom.Translation(car.Hub(i)) * geom.RotationY(car.Wheels[i].Steer))
        }
        let center = car.Position + geom.Vec3(0, 0.6, 0)
        // The body's paint, as it comes out, for the stand-in below.
        var bodyColor = paint.Color ?? geom.Vec4(0.5, 0.5, 0.5, 1)
        for p in parts {
            if p.inside && detail >= 2 { continue }
            let slot = p.slots[v]
            if slot < 0 || slot >= materials.count { continue }
            var m = materials[slot]
            let name = names[slot]
            if detail >= 2 && fine(name) { continue }
            if let c = paint.Color, name.hasPrefix("Paint 1") { m.Color = c }
            if name.hasPrefix("Paint 1") { bodyColor = m.Color }
            if let c = paint.Trim, name.hasPrefix("Interior 3") { m.Color = c }
            if braking && name == "Brakelight" { m.Emissive = m.Emissive * 3.5 }
            if detail >= 2 && name == "Glass" {
                m.Alpha = .opaque
                m.Color = geom.Vec4(0.02, 0.025, 0.032, 1)
            }
            var place = body
            if p.wheel >= 0 && p.wheel < wheels.count { place = p.rolls ? wheels[p.wheel] : calipers[p.wheel] }
            var it = forward.Item(p.model, m, at: place)
            it.Center = center
            it.Radius = 3
            it.Shadow = .none
            it.InProbes = false
            out.append(it)
        }
        // In reflections, the car as one shape in its paint.
        var paintOnly = forward.Material()
        paintOnly.Color = bodyColor
        paintOnly.Roughness = 0.22
        paintOnly.Metallic = 0.75
        paintOnly.Clearcoat = 1.0
        paintOnly.ClearcoatRoughness = 0.04
        var seen = forward.Item(shadow, paintOnly, at: body)
        seen.Center = center
        seen.Radius = 3
        seen.Shadow = .none
        seen.InView = false
        out.append(seen)
        var cast = forward.Item(shadow, forward.Material(), at: body)
        cast.Center = center
        cast.Radius = 3
        cast.Shadow = .only
        out.append(cast)
        return out
    }
}

// fine is whether a material's parts are too small to see far off: brake
// discs and calipers, mirrors, small hardware.
func fine(name: string) -> bool {
    return name == "Disc" || name == "Brake" || name == "Mirror" || name == "Mechanical" || name == "Hardware" || name == "License"
}

// material turns a glTF material into the renderer's, correcting raw near-zero
// albedos in the source asset so wheels, tires, brakes, and aero trim read
// with physically plausible reflectance under daylight.
func material(g: gltf.Material, tex: (int) -> forward.Texture?) -> forward.Material {
    var m = forward.Material()
    m.Base = tex(g.BaseColorTexture)
    m.Color = g.BaseColor
    m.Normal = tex(g.NormalTexture)
    m.NormalStrength = g.NormalScale
    m.NormalTiling = g.NormalTiling
    m.Tiling = g.BaseTiling
    m.MetalRough = tex(g.MetallicRoughnessTexture)
    m.Metallic = g.Metallic
    m.Roughness = g.Roughness
    m.Occlusion = tex(g.OcclusionTexture)
    m.OcclusionStrength = g.OcclusionStrength
    m.OcclusionUV2 = g.OcclusionUV == 1
    m.Emissive = g.EmissiveFactor * g.EmissiveStrength
    m.EmissiveMap = tex(g.EmissiveTexture)
    m.Clearcoat = g.Clearcoat
    m.ClearcoatRoughness = math.Max(0.02, g.ClearcoatRoughness)
    m.DoubleSided = g.DoubleSided
    if g.Name.hasPrefix("Paint 1") {
        m.Clearcoat = 1.0
        m.ClearcoatRoughness = 0.035
    } else if g.Name == "Rim1" {
        // Main multi-spoke alloy wheel face (was 0.001 non-metallic black in glTF).
        m.Color = geom.Vec4(0.68, 0.71, 0.76, 1)
        m.Metallic = 0.72
        m.Roughness = 0.24
        m.Clearcoat = 0.55
        m.ClearcoatRoughness = 0.06
    } else if g.Name == "Rim2" {
        // Polished machined rim barrel & lip.
        m.Color = geom.Vec4(0.84, 0.86, 0.90, 1)
        m.Metallic = 0.88
        m.Roughness = 0.16
    } else if g.Name == "Disc" {
        // Steel brake rotor.
        m.Color = geom.Vec4(0.58, 0.59, 0.62, 1)
        m.Metallic = 0.85
        m.Roughness = 0.28
    } else if g.Name == "Brake" {
        // Anodized racing caliper.
        m.Color = geom.Vec4(0.78, 0.06, 0.04, 1)
        m.Metallic = 0.45
        m.Roughness = 0.26
        m.Clearcoat = 0.65
        m.ClearcoatRoughness = 0.08
    } else if g.Name == "Tiretread" {
        // Vulcanized racing tread compound in linear color space.
        m.Color = geom.Vec4(0.022, 0.023, 0.025, 1)
        m.Metallic = 0
        m.Roughness = 0.64
    } else if g.Name == "Tireside" {
        // Deep charcoal tire sidewall rubber in linear color space.
        m.Color = geom.Vec4(0.024, 0.025, 0.028, 1)
        m.Metallic = 0
        m.Roughness = 0.52
        m.Clearcoat = 0
    } else if g.Name == "material2" {
        // Exterior carbon/satin aero splitters, diffuser, skirts, and vents.
        m.Color = geom.Vec4(0.042, 0.044, 0.048, 1)
        m.Metallic = 0.18
        m.Roughness = 0.36
        m.Clearcoat = 0.25
        m.ClearcoatRoughness = 0.18
    } else if g.Name == "Grid" {
        m.Color = geom.Vec4(0.09, 0.095, 0.10, 1)
        m.Metallic = 0.6
        m.Roughness = 0.40
    }
    if g.AlphaMode == "MASK" {
        m.Alpha = .mask
        m.Cutoff = g.AlphaCutoff
        m.SoftEdges = false
    }
    if g.Transmission > 0.5 || g.AlphaMode == "BLEND" {
        // Glass: tinted dark, reflecting the sky and probe.
        m.Alpha = .blend
        m.Color = geom.Vec4(0.025, 0.03, 0.038, g.Transmission > 0.5 ? 0.58 : g.BaseColor.W)
        m.Roughness = math.Max(0.02, g.Roughness)
        m.Metallic = 0
        m.Clearcoat = 1.0
        m.ClearcoatRoughness = 0.02
    }
    return m
}

// decodeAll decodes images, a thread each; one that won't decode is nil.
func decodeAll(all: [[uint8]]) -> [image.RGBA?] {
    var boxes: [decodeBox] = []
    var threads: [sync.Thread] = []
    for b in all {
        let box = decodeBox(b)
        boxes.append(box)
        threads.append(sync.Thread.spawn { box.run() })
    }
    for t in threads { t.join() }
    return boxes.map { $0.image }
}

final class decodeBox {
    let bytes: [uint8]
    var image: image.RGBA? = nil

    init(b: [uint8]) { bytes = b }

    func run() { image = format.Decode(bytes) }
}
