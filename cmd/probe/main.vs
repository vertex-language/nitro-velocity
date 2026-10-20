// probe: the full field on autopilot, one car traced. A tool for tuning.
//
//     vsc run probe -- [name] [from s] [to s]
package main

import (
    "fs"
    "math"
    "nitro-velocity/race"
    "nitro-velocity/track"
    "physics/vehicle"
)

func main() -> int32 {
    let args = CommandLine.arguments
    let who = args.count > 1 ? args[1] : "You"
    let from = args.count > 2 ? float32(args[2]) ?? 0 : 0
    let to = args.count > 3 ? float32(args[3]) ?? 60 : 60
    let t = try! track.Track.Load(fs.Path("data/sunny-oval.json"))
    let cars = try! race.LoadCars(fs.Path("data/cars.json"))
    let r = race.Race(t, cars: cars, names: ["Kai Mercer", "Rosa Vance", "Jett Okafor", "Mila Sorensen"])
    r.Autopilot = true
    var frame = 0
    while r.Clock < to {
        r.Schedule.Run(1.0 / 60)
        frame += 1
        if r.Clock < from || frame % 10 != 0 { continue }
        for p in r.Order where p.Name == who {
            let c = p.Car
            let v = c.Velocity
            let slip = math.Atan2(v.Dot(c.Left), math.Max(1, v.Dot(c.Forward)))
            var near = ""
            for o in r.Order where o !== p {
                let d = (o.Car.Position - c.Position).Length()
                if d < 8 { near += " \(o.Name.prefix(4))@\(Int(d * 10))" }
            }
            print("t \(Int(r.Clock * 10)) pos \(p.Position) s \(Int(p.Place.S)) lat \(Int(p.Place.Lateral * 10)) v \(Int(c.ForwardSpeed * 3.6)) want \(Int(p.Driver.Want * 3.6)) th \(Int(p.Controls.Throttle * 100)) br \(Int(p.Controls.Brake * 100)) st \(Int(p.Controls.Steer * 100)) slip \(Int(slip * 57)) yaw \(Int((c.Yaw - t.Yaw(p.Place.S)) * 57)) imp \(Int(p.Impact))\(near)")
        }
    }
    return 0
}
