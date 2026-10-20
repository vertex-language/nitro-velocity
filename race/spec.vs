package race

import (
    "encoding/json"
    "fs"
    "math/geom"
    "physics/vehicle"
)

/// CarInfo is one car you can race: its name, its model (for look), who
/// made the model, and its build, measured off the model (data/cars.json,
/// written by assets_src/sketchfab/cook.py).
public struct CarInfo {
    public var Id: string
    public var Name: string
    public var Year: int
    /// The model, under assets/.
    public var Model: string
    public var Credit: string
    /// "rear" or "all".
    public var Drive: string
    public var Spec: vehicle.Spec
}

/// CarsError is a cars file that doesn't describe cars.
public struct CarsError: Error, CustomStringConvertible {
    public let Message: string
    public var description: string { return "cars: \(Message)" }
}

/// LoadCars reads the cars (data/cars.json).
public func LoadCars(_ path: fs.Path) throws -> [CarInfo] {
    return try DecodeCars(try fs.ReadText(path))
}

/// DecodeCars reads the cars from JSON text.
public func DecodeCars(_ text: string) throws -> [CarInfo] {
    let v = try json.Parse(bytes: [uint8](text.utf8))
    var out: [CarInfo] = []
    for c in v["cars"]?.Array ?? [] {
        func vec(_ x: json.Value?) -> geom.Vec3 {
            let a = x?.Array ?? []
            if a.count < 3 { return geom.Vec3.Zero }
            return geom.Vec3(float32(a[0].Double ?? 0), float32(a[1].Double ?? 0), float32(a[2].Double ?? 0))
        }
        var hubs: [geom.Vec3] = []
        for h in c["hubs"]?.Array ?? [] { hubs.append(vec(h)) }
        var radii: [float32] = []
        for r in c["radii"]?.Array ?? [] { radii.append(float32(r.Double ?? 0.34)) }
        if hubs.count != 4 || radii.count != 4 { throw CarsError(Message: "car \(c["id"]?.String ?? "?"): want four hubs and radii") }
        let drive = c["drive"]?.String ?? "rear"
        let spec = Build(hubs: hubs, radii: radii, min: vec(c["min"]), max: vec(c["max"]),
                         mass: float32(c["mass"]?.Double ?? 1450), power: float32(c["power"]?.Double ?? 1),
                         allWheels: drive == "all", bias: float32(c["bias"]?.Double ?? 0))
        out.append(CarInfo(Id: c["id"]?.String ?? "", Name: c["name"]?.String ?? "car", Year: int(c["year"]?.Int ?? 0),
                           Model: c["model"]?.String ?? "", Credit: c["credit"]?.String ?? "", Drive: drive, Spec: spec))
    }
    if out.isEmpty { throw CarsError(Message: "no cars") }
    return out
}

/// Build is a car's build from its model's measurements (facing +Z, +X
/// its left, the ground at y = 0): each wheel's hub (front left, front
/// right, rear left, rear right) and tire radius, the body's box, its
/// weight, its power (1 the Sports engine), whether all four wheels drive,
/// and how far forward of the axles' middle its weight sits.
public func Build(hubs: [geom.Vec3], radii: [float32], min lo: geom.Vec3, max hi: geom.Vec3,
                  mass: float32, power: float32, allWheels: bool, bias: float32) -> vehicle.Spec {
    var s = vehicle.Spec.Sports()
    s.Mass = mass
    s.Torque = s.Torque.map { $0 * power }
    s.BoostForce *= power
    // The body: its box from a hand's width off the ground to just under
    // the roof, a touch inside the model's widest and longest.
    let bottom: float32 = 0.1
    let top = hi.Y * 0.94
    s.HalfExtents = geom.Vec3((hi.X - lo.X) / 2 * 0.96, (top - bottom) / 2, (hi.Z - lo.Z) / 2 * 0.97)
    s.BoxCenter = geom.Vec3(0, (top + bottom) / 2, (hi.Z + lo.Z) / 2)
    let frontZ = (hubs[0].Z + hubs[1].Z) / 2
    let rearZ = (hubs[2].Z + hubs[3].Z) / 2
    let mid = (frontZ + rearZ) / 2
    s.CenterOfMass = geom.Vec3(0, 0.42, mid + bias)
    // What each spring holds at rest: the weight shared by how near the
    // center of mass is to its axle.
    let wheelbase = frontZ - rearZ
    let frontShare = (s.CenterOfMass.Z - rearZ) / wheelbase
    s.Wheels = []
    for i in 0..<4 {
        let front = i < 2
        var w = vehicle.WheelSpec(hubs[i])
        w.Radius = radii[i]
        w.Steers = front
        w.Drives = allWheels || !front
        w.Handbrake = !front
        w.BrakeShare = front ? 0.32 : 0.18
        w.Grip = front ? 1 : 1.06
        w.Stiffness = front ? 40000 : 46000
        w.Damping = front ? 3400 : 3800
        let load = s.Mass * 9.81 * (front ? frontShare : 1 - frontShare) / 2
        // The hub sits where it's modeled when the spring holds its load.
        w.Position = geom.Vec3(hubs[i].X, hubs[i].Y - load / w.Stiffness, hubs[i].Z)
        s.Wheels.append(w)
    }
    return s
}

/// Picks is a car for each of `field` rivals out of `count`, at random by
/// `seed`: dealt from a shuffled deck of every car (reshuffled when it runs
/// out), so the field is as mixed as it can be.
public func Picks(_ count: int, field: int, seed: uint64) -> [int] {
    var out: [int] = []
    if count <= 0 { return out }
    var x = seed &* 0x9E3779B97F4A7C15 | 1
    var deck: [int] = []
    while out.count < field {
        if deck.isEmpty {
            for k in 0..<count { deck.append(k) }
            var i = count - 1
            while i > 0 {
                x ^= x << 13
                x ^= x >> 7
                x ^= x << 17
                let j = int(x % uint64(i + 1))
                let t = deck[i]
                deck[i] = deck[j]
                deck[j] = t
                i -= 1
            }
        }
        out.append(deck.removeLast())
    }
    return out
}
