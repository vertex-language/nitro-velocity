package look

import (
    "image/draw"
    "math"
    "math/geom"
    "nitro-velocity/race"
    "text/font"
)

/// HUD is what's drawn over the race: before it, the car you're choosing;
/// then your place and lap, the times, a map of the track, the
/// speedometer with its rev arc, gear and nitro; the countdown; notes as
/// laps go by; and, at the flag, the results on a frosted glass panel.
public final class HUD {
    var faces: [string: font.Face] = [:]
    var runs: [string: font.Run] = [:]
    var map: [geom.Vec2] = []
    var mapLo = geom.Vec2.Zero
    var mapHi = geom.Vec2.Zero
    /// A note in the middle of the screen, and how long it has left.
    var note = ""
    var noteLeft: float32 = 0
    var lastLap = -1
    var finishedAt: float32 = -1
    var shownAt: float32 = 0
    /// Show the keys.
    public var Help = true
    /// Frames a second, for the corner.
    public var Fps: float32 = 60
    /// The car you're choosing before the race (nil once it's on), which
    /// of how many.
    public var Choosing: race.CarInfo? = nil
    public var ChoiceIndex = 0
    public var ChoiceCount = 1
    /// Frost the results panel's backdrop here, on the CPU (drawing over a
    /// frame read back); false when the HUD is an overlay and the GPU does
    /// it from Panel.
    public var CPUFrost = true
    /// The results panel this frame, when it's up: its box (HUD pixels),
    /// corner radius and how far it has faded in; for the GPU's backdrop.
    public private(set) var Panel: (x: float32, y: float32, width: float32, height: float32, radius: float32, strength: float32)? = nil
    /// Where this frame's HUD drew (HUD pixels, clipped to the frame): an
    /// overlay need only clear and send these.
    public private(set) var Dirty: [draw.IRect] = []

    public init(_ r: race.Race) {
        let t = r.Track
        var lo = geom.Vec2(1e9, 1e9), hi = geom.Vec2(-1e9, -1e9)
        var i = 0
        while i < t.Points.count {
            let p = geom.Vec2(t.Points[i].X, t.Points[i].Z)
            map.append(p)
            lo = geom.Vec2(math.Min(lo.X, p.X), math.Min(lo.Y, p.Y))
            hi = geom.Vec2(math.Max(hi.X, p.X), math.Max(hi.Y, p.Y))
            i += 6
        }
        mapLo = lo
        mapHi = hi
    }

    func face(_ size: float32, weight: int32 = 700, italic: bool = true) -> font.Face {
        let key = "\(Int(size * 10))/\(weight)/\(italic)"
        if let f = faces[key] { return f }
        let f = font.Load(font.Spec(families: ["Avenir Next Condensed", "Avenir Next", "Helvetica Neue"], size: size, weight: weight, italic: italic))
        faces[key] = f
        return f
    }

    /// Reset forgets the last race's notes and results.
    public func Reset() {
        note = ""
        noteLeft = 0
        lastLap = -1
        finishedAt = -1
    }

    /// Draw draws the HUD over a frame of width × height pixels (frosting
    /// the results' backdrop here when CPUFrost).
    public func Draw(_ px: inout [uint8], _ width: int, _ height: int, _ r: race.Race, dt: float32) {
        let s = update(width, height, r, dt: dt)
        if let box = resultsBox(width, height, s, r), CPUFrost {
            frost(&px, width, height, box.0, strength: box.1, radius: 26 * s)
        }
        draw.WithCanvas(&px, width: int32(width), height: int32(height)) { c in
            self.paint(c, width, height, s, r)
        }
    }

    /// Draw draws the HUD into a canvas the frame's size (an overlay: the
    /// results' backdrop is left to the GPU, from Panel).
    public func Draw(into c: draw.Canvas, _ width: int, _ height: int, _ r: race.Race, dt: float32) {
        let s = update(width, height, r, dt: dt)
        if let box = resultsBox(width, height, s, r) {
            Panel = (x: float32(box.0.X), y: float32(box.0.Y), width: float32(box.0.Width), height: float32(box.0.Height), radius: 26 * s, strength: box.1)
        }
        paint(c, width, height, s, r)
    }

    // update moves the HUD's notes and timers on, and works out where it
    // will draw; answers its scale (1 at 720 pixels high).
    func update(_ width: int, _ height: int, _ r: race.Race, dt: float32) -> float32 {
        let s = float32(height) / 720
        Panel = nil
        Dirty = []
        func mark(_ x: float32, _ y: float32, _ w: float32, _ h: float32) {
            let x0 = max(0, int(x)), y0 = max(0, int(y))
            let x1 = min(width, int(x + w) + 1), y1 = min(height, int(y + h) + 1)
            if x1 > x0 && y1 > y0 { Dirty.append(draw.IRect(int32(x0), int32(y0), int32(x1 - x0), int32(y1 - y0))) }
        }
        if Choosing != nil {
            let pw = 620 * s, ph = 172 * s
            mark((float32(width) - pw) / 2 - 4 * s, float32(height) - ph - 44 * s, pw + 8 * s, ph + 8 * s)
            mark(0, 0, 420 * s, 110 * s)
            return s
        }
        let me = r.Player!
        // Notes: a new lap, the last lap, a best lap.
        if me.Laps != lastLap {
            if lastLap >= 0 && me.Laps >= 1 && me.Laps < r.Track.Laps {
                note = me.Laps == r.Track.Laps - 1 ? "FINAL LAP" : "LAP \(me.Laps + 1)"
                if me.BestLap > 0 && me.LastLap == me.BestLap { note += "   ·   BEST " + clock(me.BestLap) }
                noteLeft = 2.4
            }
            lastLap = me.Laps
        }
        noteLeft = math.Max(0, noteLeft - dt)
        if me.Finished && finishedAt < 0 { finishedAt = r.Clock }
        if let box = resultsBox(width, height, s, r) {
            mark(float32(box.0.X), float32(box.0.Y), float32(box.0.Width), float32(box.0.Height))
            return s
        }
        let w = float32(width), h = float32(height)
        mark(0, 0, 300 * s, (172 + 27 * float32(r.Order.count)) * s)
        mark(w - 214 * s, 0, 214 * s, 212 * s)
        mark(w - 300 * s, h - 300 * s, 300 * s, 300 * s)
        if r.Clock < 1.2 { mark(w * 0.3, h * 0.18, w * 0.4, h * 0.42) }
        if noteLeft > 0 { mark(w * 0.15, h * 0.24 - 64 * s, w * 0.7, 96 * s) }
        if Help && r.Clock < 6 { mark(0, h - 48 * s, w, 48 * s) }
        return s
    }

    // resultsBox is the results panel (and how far it has faded in) once
    // you've finished; nil before.
    func resultsBox(_ width: int, _ height: int, _ s: float32, _ r: race.Race) -> (draw.IRect, float32)? {
        if !r.Player.Finished || finishedAt < 0 { return nil }
        let k = math.Clamp((r.Clock - finishedAt) / 0.7, 0, 1)
        let pw = 620 * s, ph = 470 * s
        let x0 = (float32(width) - pw) / 2
        let y0 = (float32(height) - ph) / 2 + (1 - k) * (1 - k) * 60 * s
        return (draw.IRect(int32(x0), int32(y0), int32(pw), int32(ph)), k)
    }

    // paint draws it all.
    func paint(_ c: draw.Canvas, _ width: int, _ height: int, _ s: float32, _ r: race.Race) {
        if let car = Choosing {
            chooser(c, width, height, s, r, car)
            return
        }
        if let box = resultsBox(width, height, s, r) {
            results(c, box.0, s, r, box.1)
            return
        }
        standing(c, s, r)
        minimap(c, width, s, r)
        speedometer(c, width, height, s, r)
        countdown(c, width, height, s, r)
        if noteLeft > 0 { banner(c, width, height, s) }
        if Help && r.Clock < 6 {
            let keys = "W / ↑ throttle    S / ↓ brake · reverse    A D / ← → steer    Space handbrake    Shift nitro    C camera    B look back    R reset    M mute    H help"
            text(c, keys, size: 13 * s, x: 24 * s, baseline: float32(height) - 22 * s, color: draw.Color(255, 255, 255, 230), weight: 500, italic: false)
        }
    }

    // ---- the parts ----

    // standing is your place and lap, top left, and the times under it.
    func standing(_ c: draw.Canvas, _ s: float32, _ r: race.Race) {
        let me = r.Player!
        let n = r.Order.count
        glass(c, draw.IRect(int32(20 * s), int32(18 * s), int32(250 * s), int32(118 * s)), s)
        text(c, "POS", size: 13 * s, x: 36 * s, baseline: 42 * s, color: draw.Color(150, 205, 255, 255), weight: 600)
        text(c, "\(me.Position)", size: 58 * s, x: 34 * s, baseline: 96 * s, color: draw.Color(255, 255, 255, 255), weight: 800)
        let w = face(58 * s, weight: 800).Measure("\(me.Position)")
        text(c, "/\(n)", size: 26 * s, x: 38 * s + w, baseline: 96 * s, color: draw.Color(255, 255, 255, 190), weight: 700)
        text(c, "LAP", size: 13 * s, x: 150 * s, baseline: 42 * s, color: draw.Color(150, 205, 255, 255), weight: 600)
        let lap = min(r.Track.Laps, max(1, me.Laps + 1))
        text(c, "\(lap)/\(r.Track.Laps)", size: 36 * s, x: 148 * s, baseline: 82 * s, color: draw.Color(255, 255, 255, 255), weight: 800)
        let now = r.Clock > 0 ? r.Clock - me.LapStart : 0
        text(c, "TIME  " + clock(math.Max(0, now)), size: 15 * s, x: 36 * s, baseline: 124 * s, color: draw.Color(255, 255, 255, 235), weight: 600, italic: false)
        let best = me.BestLap > 0 ? clock(me.BestLap) : "–:––.––"
        text(c, "BEST  " + best, size: 15 * s, x: 150 * s, baseline: 124 * s, color: draw.Color(255, 220, 120, 235), weight: 600, italic: false)
        // The order under it.
        var y = 160 * s
        for x in r.Order {
            let mine = x.IsPlayer
            let row = draw.IRect(int32(20 * s), int32(y - 17 * s), int32(200 * s), int32(24 * s))
            c.FillRounded(row, radii: draw.Radii(all: 6 * s), mine ? draw.Color(30, 120, 255, 200) : draw.Color(10, 14, 24, 120))
            text(c, "\(x.Position)", size: 15 * s, x: 30 * s, baseline: y, color: draw.Color(255, 255, 255, 255), weight: 800)
            text(c, x.Name.uppercased(), size: 14 * s, x: 52 * s, baseline: y, color: draw.Color(255, 255, 255, mine ? 255 : 215), weight: 600, italic: false)
            y += 27 * s
        }
    }

    // minimap is the track from above, top right, everyone on it.
    func minimap(_ c: draw.Canvas, _ width: int, _ s: float32, _ r: race.Race) {
        let size = 170 * s
        let x0 = float32(width) - size - 24 * s, y0 = 18 * s
        glass(c, draw.IRect(int32(x0), int32(y0), int32(size), int32(size)), s)
        let span = math.Max(mapHi.X - mapLo.X, mapHi.Y - mapLo.Y)
        let k = (size - 34 * s) / span
        let cx = x0 + size / 2, cy = y0 + size / 2
        let mid = (mapLo + mapHi) * 0.5
        // The map turned so the main straight runs up the screen.
        func at(_ p: geom.Vec2) -> (float32, float32) {
            return (cx + (p.X - mid.X) * k, cy - (p.Y - mid.Y) * k)
        }
        // The track: a dot every few meters, close enough to read as a line.
        for p in map {
            let (x, y) = at(p)
            c.FillRounded(draw.IRect(int32(x - 3 * s), int32(y - 3 * s), int32(6 * s), int32(6 * s)), radii: draw.Radii(all: 3 * s), draw.Color(255, 255, 255, 170))
        }
        // The finish line.
        let (lx, ly) = at(geom.Vec2(r.Track.Points[0].X, r.Track.Points[0].Z))
        c.Fill(draw.IRect(int32(lx - 7 * s), int32(ly - 1.5 * s), int32(14 * s), int32(3 * s)), draw.Color(255, 60, 40, 255))
        for x in r.Order.reversed() {
            let (px, py) = at(geom.Vec2(x.Car.Position.X, x.Car.Position.Z))
            let rad = (x.IsPlayer ? 7 : 5) * s
            let col = x.IsPlayer ? draw.Color(40, 160, 255, 255) : paintColor(x.Paint)
            c.FillRounded(draw.IRect(int32(px - rad - 1.5 * s), int32(py - rad - 1.5 * s), int32(rad * 2 + 3 * s), int32(rad * 2 + 3 * s)), radii: draw.Radii(all: rad + 1.5 * s), draw.Color(10, 12, 20, 220))
            c.FillRounded(draw.IRect(int32(px - rad), int32(py - rad), int32(rad * 2), int32(rad * 2)), radii: draw.Radii(all: rad), col)
        }
    }

    // speedometer is bottom right: the speed in big italic figures, the
    // rev arc round it red toward the limit, the gear, nitro under it.
    func speedometer(_ c: draw.Canvas, _ width: int, _ height: int, _ s: float32, _ r: race.Race) {
        let me = r.Player!
        let car = me.Car
        let radius = 108 * s
        let cx = float32(width) - radius - 40 * s, cy = float32(height) - radius - 52 * s
        // A dark disc behind it.
        c.FillRounded(draw.IRect(int32(cx - radius - 14 * s), int32(cy - radius - 14 * s), int32((radius + 14 * s) * 2), int32((radius + 14 * s) * 2)),
                      radii: draw.Radii(all: radius + 14 * s), draw.Color(8, 12, 22, 150))
        // The rev arc: 26 segments over 250°, lit up to the rpm.
        let segs = 26
        let spec = car.Spec
        let frac = math.Clamp((car.Rpm - 0) / (spec.Redline * 1.05), 0, 1)
        let a0 = float32(math.Pi) * 0.75, sweep = float32(math.Pi) * 1.4
        for i in 0..<segs {
            let f0 = float32(i) / float32(segs), f1 = (float32(i) + 0.72) / float32(segs)
            let lit = f0 < frac
            let red = f0 > spec.Redline / (spec.Redline * 1.05) * 0.86
            var col = lit ? (red ? draw.Color(255, 50, 40, 255) : draw.Color(60, 175, 255, 255)) : draw.Color(255, 255, 255, 45)
            if lit && !red && f0 > 0.7 { col = draw.Color(140, 220, 255, 255) }
            arc(c, cx, cy, radius - 14 * s, radius, a0 + sweep * f0, a0 + sweep * f1, col)
        }
        // Speed.
        let kmh = Int(math.Abs(car.ForwardSpeed) * 3.6)
        let sf = face(64 * s, weight: 800)
        let st = "\(kmh)"
        text(c, st, size: 64 * s, x: cx - sf.Measure(st) / 2, baseline: cy + 18 * s, color: draw.Color(255, 255, 255, 255), weight: 800)
        let unit = "KM/H"
        text(c, unit, size: 13 * s, x: cx - face(13 * s, weight: 600).Measure(unit) / 2, baseline: cy + 38 * s, color: draw.Color(150, 205, 255, 255), weight: 600)
        // Gear in a ring under it.
        let g = car.Gear < 0 ? "R" : (car.Gear == 0 ? "N" : "\(car.Gear)")
        let gr = 20 * s
        c.FillRounded(draw.IRect(int32(cx - gr), int32(cy + 52 * s), int32(gr * 2), int32(gr * 2)), radii: draw.Radii(all: gr), draw.Color(255, 255, 255, 235))
        let gf = face(24 * s, weight: 800, italic: false)
        text(c, g, size: 24 * s, x: cx - gf.Measure(g) / 2, baseline: cy + 52 * s + gr + 8.5 * s, color: draw.Color(10, 14, 24, 255), weight: 800, italic: false)
        // Nitro: a bar under the dial.
        let bw = 230 * s, bh = 12 * s
        let bx = cx - bw / 2, by = float32(height) - 34 * s
        text(c, "NITRO", size: 12 * s, x: bx, baseline: by - 6 * s, color: draw.Color(150, 205, 255, 255), weight: 700)
        c.FillRounded(draw.IRect(int32(bx), int32(by), int32(bw), int32(bh)), radii: draw.Radii(all: bh / 2), draw.Color(255, 255, 255, 50))
        let fill = math.Max(bh, bw * me.Nitro)
        if me.Nitro > 0.01 {
            let grad = draw.LinearGradient(angle: 90, stops: [draw.GradientStop(draw.Color(20, 90, 255, 255), at: 0), draw.GradientStop(draw.Color(120, 230, 255, 255), at: 1)])
            c.FillGradient(draw.IRect(int32(bx), int32(by), int32(fill), int32(bh)), radii: draw.Radii(all: bh / 2), grad)
        }
        if me.Boosting {
            text(c, "BOOST", size: 14 * s, x: bx + bw - face(14 * s, weight: 800).Measure("BOOST"), baseline: by - 6 * s, color: draw.Color(140, 230, 255, 255), weight: 800)
        }
    }

    // countdown is the lights' count in the middle: 3, 2, 1, GO!
    func countdown(_ c: draw.Canvas, _ width: int, _ height: int, _ s: float32, _ r: race.Race) {
        var word = ""
        var age: float32 = 0
        if r.Clock < 0 && r.Clock > -3 {
            let left = -r.Clock
            word = "\(Int(math.Ceil(left)))"
            age = 1 - (left - math.Floor(left))
            if left - math.Floor(left) < 0.0001 { age = 0 }
        } else if r.Clock >= 0 && r.Clock < 1.2 {
            word = "GO!"
            age = r.Clock / 1.2
        }
        if word.isEmpty { return }
        // Big, shrinking and fading as the second goes.
        let size = (150 - 40 * age) * s
        let a = uint8(math.Clamp((1 - age * age) * 255, 0, 255))
        let f = face(size, weight: 900)
        let w = f.Measure(word)
        let col = word == "GO!" ? draw.Color(80, 255, 140, a) : draw.Color(255, 255, 255, a)
        text(c, word, size: size, x: (float32(width) - w) / 2, baseline: float32(height) * 0.42 + size * 0.35, color: col, weight: 900)
    }

    // banner is the note in the middle (a lap, a best lap).
    func banner(_ c: draw.Canvas, _ width: int, _ height: int, _ s: float32) {
        let a = math.Clamp(math.Min(noteLeft / 0.4, (2.4 - noteLeft) / 0.25), 0, 1)
        let f = face(34 * s, weight: 800)
        let w = f.Measure(note)
        let x = (float32(width) - w) / 2
        let y = float32(height) * 0.24
        c.FillRounded(draw.IRect(int32(x - 26 * s), int32(y - 40 * s), int32(w + 52 * s), int32(56 * s)), radii: draw.Radii(all: 14 * s), draw.Color(8, 14, 30, uint8(150 * a)))
        text(c, note, size: 34 * s, x: x, baseline: y, color: draw.Color(255, 255, 255, uint8(255 * a)), weight: 800)
    }

    // results is the flag: on a glass panel over the race (blurred under
    // it), the place you finished, everyone's times.
    func results(_ c: draw.Canvas, _ box: draw.IRect, _ s: float32, _ r: race.Race, _ k: float32) {
        let me = r.Player!
        let x0 = float32(box.X), y0 = float32(box.Y), pw = float32(box.Width), ph = float32(box.Height)
        do {
            let a = k
            c.FillRounded(box, radii: draw.Radii(all: 26 * s), draw.Color(255, 255, 255, uint8(38 * a)))
            let edge = draw.Color(255, 255, 255, uint8(110 * a))
            c.FillRing(box, radii: draw.Radii(all: 26 * s), widths: draw.Edges(all: 1.5 * s), colors: [edge, edge, edge, edge])
            let won = me.Position == 1
            let title = won ? "YOU WON" : ordinal(me.Position).uppercased() + " PLACE"
            let tf = self.face(72 * s, weight: 900)
            let tw = tf.Measure(title)
            let tc = won ? draw.Color(255, 214, 90, uint8(255 * a)) : draw.Color(255, 255, 255, uint8(255 * a))
            self.text(c, title, size: 72 * s, x: x0 + (pw - tw) / 2, baseline: y0 + 104 * s, color: tc, weight: 900)
            let sub = "\(r.Track.Name.uppercased())   ·   \(r.Track.Laps) LAPS   ·   \(clock(me.FinishTime))"
            let sw = self.face(16 * s, weight: 600, italic: false).Measure(sub)
            self.text(c, sub, size: 16 * s, x: x0 + (pw - sw) / 2, baseline: y0 + 138 * s, color: draw.Color(255, 255, 255, uint8(220 * a)), weight: 600, italic: false)
            // The table: place, name, time (or how far behind, still running).
            var y = y0 + 186 * s
            let leader = r.Results.first
            for x in r.Order {
                let mine = x.IsPlayer
                let row = draw.IRect(int32(x0 + 40 * s), int32(y - 24 * s), int32(pw - 80 * s), int32(34 * s))
                c.FillRounded(row, radii: draw.Radii(all: 10 * s), mine ? draw.Color(30, 120, 255, uint8(190 * a)) : draw.Color(10, 16, 30, uint8(90 * a)))
                self.text(c, "\(x.Position)", size: 20 * s, x: x0 + 58 * s, baseline: y, color: draw.Color(255, 255, 255, uint8(255 * a)), weight: 800)
                self.text(c, x.Name.uppercased(), size: 18 * s, x: x0 + 96 * s, baseline: y, color: draw.Color(255, 255, 255, uint8(255 * a)), weight: 600, italic: false)
                var t = "running"
                if x.Finished {
                    t = x === leader ? clock(x.FinishTime) : "+" + clock(x.FinishTime - (leader?.FinishTime ?? 0))
                }
                let best = x.BestLap > 0 ? "best " + clock(x.BestLap) : ""
                let tw2 = self.face(18 * s, weight: 700, italic: false).Measure(t)
                self.text(c, t, size: 18 * s, x: x0 + pw - 60 * s - tw2, baseline: y, color: draw.Color(255, 255, 255, uint8(255 * a)), weight: 700, italic: false)
                self.text(c, best, size: 13 * s, x: x0 + pw - 250 * s, baseline: y, color: draw.Color(255, 230, 160, uint8(200 * a)), weight: 500, italic: false)
                y += 42 * s
            }
            let hint = "ENTER  choose a car        ESC  quit"
            let hw = self.face(15 * s, weight: 700, italic: false).Measure(hint)
            self.text(c, hint, size: 15 * s, x: x0 + (pw - hw) / 2, baseline: y0 + ph - 26 * s, color: draw.Color(255, 255, 255, uint8(230 * a)), weight: 700, italic: false)
        }
    }

    // chooser is the start: the race's name top left, and at the bottom a
    // glass card with the car you're on, ‹ › either side, what it is, a dot
    // for each car, and the keys.
    func chooser(_ c: draw.Canvas, _ width: int, _ height: int, _ s: float32, _ r: race.Race, _ car: race.CarInfo) {
        text(c, "NITRO VELOCITY", size: 40 * s, x: 32 * s, baseline: 62 * s, color: draw.Color(255, 255, 255, 255), weight: 900)
        let sub = "\(r.Track.Name.uppercased())   ·   \(r.Track.Laps) LAPS   ·   \(r.Order.count) CARS"
        text(c, sub, size: 15 * s, x: 34 * s, baseline: 88 * s, color: draw.Color(150, 205, 255, 255), weight: 600, italic: false)

        let pw = 620 * s, ph = 172 * s
        let x0 = (float32(width) - pw) / 2, y0 = float32(height) - ph - 40 * s
        let box = draw.IRect(int32(x0), int32(y0), int32(pw), int32(ph))
        c.FillRounded(box, radii: draw.Radii(all: 22 * s), draw.Color(8, 14, 28, 150))
        let edge = draw.Color(255, 255, 255, 70)
        c.FillRing(box, radii: draw.Radii(all: 22 * s), widths: draw.Edges(all: 1.2 * s), colors: [edge, edge, edge, edge])
        let label = "CHOOSE YOUR CAR"
        let lw = face(13 * s, weight: 700).Measure(label)
        text(c, label, size: 13 * s, x: x0 + (pw - lw) / 2, baseline: y0 + 30 * s, color: draw.Color(150, 205, 255, 255), weight: 700)
        // The name, as big as fits.
        var size = 40 * s
        while size > 22 * s && face(size, weight: 900).Measure(car.Name.uppercased()) > pw - 150 * s { size -= 2 * s }
        let name = car.Name.uppercased()
        let nw = face(size, weight: 900).Measure(name)
        text(c, name, size: size, x: x0 + (pw - nw) / 2, baseline: y0 + 76 * s, color: draw.Color(255, 255, 255, 255), weight: 900)
        // ‹ and › either side.
        for (k, x) in [(0, x0 + 34 * s), (1, x0 + pw - 34 * s)] {
            let cy = y0 + 64 * s, a = 11 * s
            var p = draw.Path()
            let d: float32 = k == 0 ? 1 : -1
            p.MoveTo(x + d * a * 0.55, cy - a)
            p.LineTo(x - d * a * 0.45, cy)
            p.LineTo(x + d * a * 0.55, cy + a)
            p.LineTo(x + d * a * 0.55 - d * 5 * s, cy + a)
            p.LineTo(x - d * a * 0.45 - d * 5 * s, cy)
            p.LineTo(x + d * a * 0.55 - d * 5 * s, cy - a)
            p.Close()
            c.FillPath(p, draw.Color(255, 255, 255, 220))
        }
        let drive = car.Drive == "all" ? "ALL-WHEEL DRIVE" : "REAR-WHEEL DRIVE"
        let facts = "\(car.Year)   ·   \(drive)   ·   \(Int(car.Spec.Mass)) KG"
        let fw = face(14 * s, weight: 600, italic: false).Measure(facts)
        text(c, facts, size: 14 * s, x: x0 + (pw - fw) / 2, baseline: y0 + 104 * s, color: draw.Color(255, 255, 255, 215), weight: 600, italic: false)
        // A dot a car, yours lit.
        let gap = 16 * s
        let dx0 = x0 + pw / 2 - gap * float32(ChoiceCount - 1) / 2
        for i in 0..<ChoiceCount {
            let rad = (i == ChoiceIndex ? 4.5 : 3) * s
            let cx = dx0 + gap * float32(i), cy = y0 + 124 * s
            c.FillRounded(draw.IRect(int32(cx - rad), int32(cy - rad), int32(rad * 2), int32(rad * 2)), radii: draw.Radii(all: rad),
                          i == ChoiceIndex ? draw.Color(60, 175, 255, 255) : draw.Color(255, 255, 255, 90))
        }
        let keys = "← →  choose        ENTER  race        ESC  quit"
        let kw2 = face(14 * s, weight: 700, italic: false).Measure(keys)
        text(c, keys, size: 14 * s, x: x0 + (pw - kw2) / 2, baseline: y0 + ph - 18 * s, color: draw.Color(255, 255, 255, 235), weight: 700, italic: false)
    }

    // ---- drawing helpers ----

    // glass is a small frosted card behind HUD text.
    func glass(_ c: draw.Canvas, _ r: draw.IRect, _ s: float32) {
        c.FillRounded(r, radii: draw.Radii(all: 14 * s), draw.Color(8, 14, 28, 120))
        let edge = draw.Color(255, 255, 255, 50)
        // One color an edge: top, right, bottom, left.
        c.FillRing(r, radii: draw.Radii(all: 14 * s), widths: draw.Edges(all: 1 * s), colors: [edge, edge, edge, edge])
    }

    // text draws a line with a soft shadow under it.
    func text(_ c: draw.Canvas, _ s: string, size: float32, x: float32, baseline: float32, color: draw.Color, weight: int32 = 700, italic: bool = true) {
        let f = face(size, weight: weight, italic: italic)
        // Shaped once per string and face: most of the HUD's words repeat
        // every frame.
        let key = "\(Int(size * 10))/\(weight)/\(italic)/" + s
        var run: font.Run
        if let r = runs[key] {
            run = r
        } else {
            run = f.Shape(s)
            if runs.count > 600 { runs = [:] }
            runs[key] = run
        }
        let off = math.Max(1, size / 22)
        font.DrawRun(c, run, x: x + off, baseline: baseline + off, scale: 1, color: draw.Color(0, 0, 0, uint8(float32(color.A) * 0.45)))
        font.DrawRun(c, run, x: x, baseline: baseline, scale: 1, color: color)
    }
}

// arc fills a ring segment from angle a0 to a1 (radians, 0 right, going
// clockwise on screen) between two radii.
func arc(_ c: draw.Canvas, _ cx: float32, _ cy: float32, _ r0: float32, _ r1: float32, _ a0: float32, _ a1: float32, _ col: draw.Color) {
    var p = draw.Path()
    let am = (a0 + a1) * 0.5
    let c0 = math.Cos(a0), s0 = math.Sin(a0)
    let cm = math.Cos(am), sm = math.Sin(am)
    let c1 = math.Cos(a1), s1 = math.Sin(a1)
    p.MoveTo(cx + c0 * r1, cy + s0 * r1)
    p.LineTo(cx + cm * r1, cy + sm * r1)
    p.LineTo(cx + c1 * r1, cy + s1 * r1)
    p.LineTo(cx + c1 * r0, cy + s1 * r0)
    p.LineTo(cx + cm * r0, cy + sm * r0)
    p.LineTo(cx + c0 * r0, cy + s0 * r0)
    p.Close()
    c.FillPath(p, col)
}

// frost blurs the frame inside a box and dims everything outside it a
// little: a glass panel over the race. Strength 0…1 eases it in.
func frost(_ px: inout [uint8], _ width: int, _ height: int, _ box: draw.IRect, strength: float32, radius: float32 = 0) {
    if strength <= 0 { return }
    // Dim the whole frame.
    let dim = 1 - 0.35 * strength
    for i in 0..<(width * height) {
        px[i * 4] = uint8(float32(px[i * 4]) * dim)
        px[i * 4 + 1] = uint8(float32(px[i * 4 + 1]) * dim)
        px[i * 4 + 2] = uint8(float32(px[i * 4 + 2]) * dim)
    }
    // The box: shrunk by 6, blurred three times, laid back over it.
    let x0 = max(0, int(box.X)), y0 = max(0, int(box.Y))
    let x1 = min(width, int(box.X + box.Width)), y1 = min(height, int(box.Y + box.Height))
    let f = 6
    let sw = max(1, (x1 - x0) / f), sh = max(1, (y1 - y0) / f)
    var small = [float32](repeating: 0, count: sw * sh * 3)
    for y in 0..<sh {
        for x in 0..<sw {
            var r: float32 = 0, g: float32 = 0, b: float32 = 0
            for dy in 0..<f {
                let row = (y0 + y * f + dy) * width
                for dx in 0..<f {
                    let i = (row + x0 + x * f + dx) * 4
                    r += float32(px[i]); g += float32(px[i + 1]); b += float32(px[i + 2])
                }
            }
            let o = (y * sw + x) * 3
            small[o] = r / float32(f * f); small[o + 1] = g / float32(f * f); small[o + 2] = b / float32(f * f)
        }
    }
    for _ in 0..<3 { small = boxBlur(small, sw, sh) }
    let k = strength
    for y in y0..<y1 {
        let sy = math.Clamp((float32(y - y0) + 0.5) / float32(f) - 0.5, 0, float32(sh - 1))
        let iy = int(sy), fy = sy - float32(iy), iy2 = min(sh - 1, iy + 1)
        for x in x0..<x1 {
            // Outside the rounded corners: left as it is.
            if radius > 0 {
                let dx = math.Max(0, math.Max(float32(x0) + radius - float32(x), float32(x) - (float32(x1) - radius)))
                let dy = math.Max(0, math.Max(float32(y0) + radius - float32(y), float32(y) - (float32(y1) - radius)))
                if dx * dx + dy * dy > radius * radius { continue }
            }
            let sx = math.Clamp((float32(x - x0) + 0.5) / float32(f) - 0.5, 0, float32(sw - 1))
            let ix = int(sx), fx = sx - float32(ix), ix2 = min(sw - 1, ix + 1)
            let i = (y * width + x) * 4
            for ch in 0..<3 {
                let a = small[(iy * sw + ix) * 3 + ch] * (1 - fx) + small[(iy * sw + ix2) * 3 + ch] * fx
                let b = small[(iy2 * sw + ix) * 3 + ch] * (1 - fx) + small[(iy2 * sw + ix2) * 3 + ch] * fx
                let v = a * (1 - fy) + b * fy
                // Lifted toward white a little: frosted, not tinted dark.
                let frosted = v * 0.82 + 255 * 0.1
                px[i + ch] = uint8(math.Clamp(float32(px[i + ch]) * (1 - k) + frosted * k, 0, 255))
            }
        }
    }
}

// boxBlur is one pass of a 5-wide box blur both ways, edges clamped.
func boxBlur(_ img: [float32], _ w: int, _ h: int) -> [float32] {
    var tmp = [float32](repeating: 0, count: img.count)
    for y in 0..<h {
        for x in 0..<w {
            for ch in 0..<3 {
                var s: float32 = 0
                for d in -2...2 { s += img[(y * w + max(0, min(w - 1, x + d))) * 3 + ch] }
                tmp[(y * w + x) * 3 + ch] = s / 5
            }
        }
    }
    var out = [float32](repeating: 0, count: img.count)
    for y in 0..<h {
        for x in 0..<w {
            for ch in 0..<3 {
                var s: float32 = 0
                for d in -2...2 { s += tmp[(max(0, min(h - 1, y + d)) * w + x) * 3 + ch] }
                out[(y * w + x) * 3 + ch] = s / 5
            }
        }
    }
    return out
}

/// clock is seconds as m:ss.hh.
public func clock(_ t: float32) -> string {
    let cs = Int((math.Max(0, t) * 100).rounded())
    let m = cs / 6000, sec = (cs / 100) % 60, h = cs % 100
    return "\(m):\(sec < 10 ? "0" : "")\(sec).\(h < 10 ? "0" : "")\(h)"
}

func ordinal(_ n: int) -> string {
    if n % 100 >= 11 && n % 100 <= 13 { return "\(n)th" }
    switch n % 10 {
    case 1: return "\(n)st"
    case 2: return "\(n)nd"
    case 3: return "\(n)rd"
    default: return "\(n)th"
    }
}

// paintColor is a racer's dot on the map, in their paint.
func paintColor(_ paint: int) -> draw.Color {
    switch paint % Paints.count {
    case 1: return draw.Color(220, 30, 30, 255)
    case 2: return draw.Color(240, 240, 245, 255)
    case 3: return draw.Color(110, 115, 125, 255)
    case 4: return draw.Color(255, 190, 20, 255)
    case 5: return draw.Color(60, 210, 70, 255)
    default: return draw.Color(40, 160, 255, 255)
    }
}
