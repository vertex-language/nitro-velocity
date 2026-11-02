// Package sound is nitro-velocity's sound, all of it made as it plays
// (media/mix voices into a media/device output): every car's engine (a
// V8's firing pulses through exhaust and body resonances, intake noise
// with the throttle, pops on the overrun), tires screeching, the wind,
// the nitro's rush, the crowd, knocks, the start beeps and a fanfare at
// the flag. Cars are heard from the camera: quieter far off, panned,
// their pitch shifted as they pass.
package sound

import (
    "math"
    "math/geom"
    "media/device"
    "media/mix"
    "nitro-velocity/race"
    "render/forward"
)

/// Sound plays a race.
public final class Sound {
    let out: device.Output?
    public let Mixer: mix.Mixer
    let rate: int
    var engines: [engine] = []
    var screech: noiseVoice
    var wind: noiseVoice
    var rush: noiseVoice
    var crowd: noiseVoice
    var lastLights = 0
    var wentGreen = false
    var flagged = false
    var knockCooldown: float32 = 0
    /// Silent, still running.
    public var Muted = false
    /// Why there's no sound, when there isn't.
    public private(set) var Problem = ""

    /// A sound for a race: opens the default output (none in a test, or
    /// when there's no device: it then makes the sound and drops it).
    public init(r: race.Race, play: bool = true) {
        var o: device.Output? = nil
        var problem = ""
        if play {
            do {
                o = try device.Output.Open(rate: 48000, channels: 2, seconds: 0.4)
            } catch {
                problem = "\(error)"
            }
        }
        out = o
        Problem = problem
        rate = o?.Rate ?? 48000
        Mixer = mix.Mixer(rate: rate)
        Mixer.Gain = 0.9
        screech = noiseVoice(rate, seed: 11, kind: .screech)
        wind = noiseVoice(rate, seed: 12, kind: .wind)
        rush = noiseVoice(rate, seed: 13, kind: .rush)
        crowd = noiseVoice(rate, seed: 14, kind: .crowd)
        for v in [screech.voice!, wind.voice!, rush.voice!, crowd.voice!] { Mixer.Add(v) }
        Attach(r)
    }

    /// Attach listens to a (new) race: an engine for each car.
    public func Attach(r: race.Race) {
        for e in engines { e.voice.Done = true }
        engines = []
        var k = 0
        for x in r.Order {
            let e = engine(rate, seed: uint32(k * 7 + 3), player: x.IsPlayer)
            engines.append(e)
            Mixer.Add(e.voice!)
            k += 1
        }
        lastLights = 0
        wentGreen = false
        flagged = false
    }

    /// Update sets every voice from the race as seen from the camera.
    public func Update(r: race.Race, camera: forward.Camera, dt: float32) {
        let ear = camera.Eye
        let ahead = (camera.Target - camera.Eye).Normalized()
        let right = ahead.Cross(geom.Vec3.UnitY).Normalized()
        let me = r.Player!
        // Engines: yours full and in the middle; the rest by distance.
        var i = 0
        var loudestSkid: float32 = 0
        var skidPan: float32 = 0
        for x in r.Order where i < engines.count {
            let e = engines[min(i, engines.count - 1)]
            i += 1
            let car = x.Car
            e.rpm = car.Rpm
            e.load = car.Shifting > 0 ? 0 : x.Controls.Throttle
            e.boost = x.Boosting ? 1 : 0
            let to = car.Position - ear
            let d = to.Length()
            var gain: float32 = 1
            var pan: float32 = 0
            var pitch: float32 = 1
            if !x.IsPlayer || d > 12 {
                gain = 1 / math.Pow(1 + d / 9, 1.35)
                pan = d > 0.5 ? math.Clamp(to.Dot(right) / d, -1, 1) * 0.85 : 0
                // Doppler: closing raises the pitch.
                let closing = d > 0.5 ? -(car.Velocity.Dot(to) / d) : 0
                pitch = math.Clamp(343 / (343 - closing * 0.8), 0.75, 1.3)
            }
            e.voice.Gain = (x.IsPlayer ? 0.55 : 0.75) * gain * (Muted ? 0 : 1)
            e.voice.Pan = pan
            e.pitch = pitch
            // Tires: how hard each car slides, heard by distance.
            var skid: float32 = 0
            for w in car.Wheels { skid = math.Max(skid, w.Skid) }
            let heard = skid * (x.IsPlayer ? 1 : gain * 1.6)
            if heard > loudestSkid {
                loudestSkid = heard
                skidPan = pan
            }
            // Knocks: a car hitting a wall or another, heard by distance.
            if x.Impact > 900 && knockCooldown <= 0 {
                knock(math.Clamp(x.Impact / 9000, 0.15, 1) * (x.IsPlayer ? 1 : gain * 1.5), pan: pan)
                knockCooldown = 0.18
            }
        }
        knockCooldown -= dt
        screech.amount = math.Clamp(loudestSkid, 0, 1)
        screech.voice.Gain = Muted ? 0 : 0.34 * screech.amount
        screech.voice.Pan = skidPan
        // Wind with your speed, the rush with your nitro.
        let v = me.Car.Speed
        wind.amount = math.Clamp(v / 85, 0, 1)
        wind.voice.Gain = Muted ? 0 : 0.42 * wind.amount * wind.amount
        rush.amount = me.Boosting ? 1 : 0
        rush.voice.Gain = Muted ? 0 : (me.Boosting ? 0.22 : 0)
        // The crowd: loud by the grandstand, a murmur elsewhere, a roar at
        // the green light and the flag.
        let (stand, _) = r.Track.At(0, lateral: -r.Track.WallOutside - 12)
        let sd = (stand - ear).Length()
        var cheer: float32 = 0
        if r.Clock > 0 && r.Clock < 4 { cheer = 1 - r.Clock / 4 }
        if me.Finished { cheer = math.Max(cheer, 0.7) }
        crowd.amount = cheer
        crowd.voice.Gain = Muted ? 0 : (0.05 + 0.4 / (1 + sd / 40)) * (0.6 + 0.8 * cheer)
        crowd.voice.Pan = sd > 1 ? math.Clamp((stand - ear).Dot(right) / sd, -1, 1) * 0.7 : 0
        // The start: a beep with each light, a higher one on green.
        let (lit, green) = r.Lights
        if !green && lit > lastLights && lit >= 3 { beep(660, 0.22) }
        lastLights = lit
        if green && !wentGreen {
            wentGreen = true
            beep(1320, 0.55)
        }
        if me.Finished && !flagged {
            flagged = true
            fanfare(me.Position == 1)
        }
    }

    /// Pump writes ahead what the device will play next: about 120 ms.
    public func Pump() {
        guard let o = out else { return }
        let want = rate * 12 / 100 - o.Queued
        if want > 64 { o.Write(Mixer.Render(frames: want)) }
    }

    /// Render makes `frames` frames without a device (for the check).
    public func Render(frames: int) -> [float32] {
        return Mixer.Render(frames: frames)
    }

    /// Engine renders one engine alone (mono) at an rpm and throttle, for
    /// tests and tuning.
    public static func Engine(rpm: float32, load: float32, seconds: float32, rate: int = 48000) -> [float32] {
        let e = engine(rate, seed: 5, player: true)
        e.rpm = rpm
        e.load = load
        e.smoothRpm = rpm
        e.smoothLoad = load
        var out: [float32] = []
        var block = [float32](repeating: 0, count: 1024)
        var left = int(seconds * float32(rate))
        while left > 0 {
            let n = min(1024, left)
            _ = e.fill(&block, n)
            for k in 0..<n { out.append(block[k]) }
            left -= n
        }
        return out
    }

    /// Underruns is how often the device ran dry.
    public var Underruns: int { return out?.Underruns ?? 0 }

    /// Close stops the sound.
    public func Close() { out?.Close() }

    // ---- one-shots ----

    func beep(f: float32, seconds: float32) {
        if Muted { return }
        let v = Mixer.Add(mix.Tone(f, seconds: seconds, rate: rate, gain: 0.32, harmonic: 0.35))
        v.Gain = 0.9
    }

    func fanfare(won: bool) {
        if Muted { return }
        // Rising thirds for a win, a gentler pair otherwise.
        let notes: [(float32, float32)] = won ? [(523.25, 0), (659.25, 0.14), (783.99, 0.28), (1046.5, 0.42)] : [(392, 0), (523.25, 0.18)]
        for (f, delay) in notes {
            let v = Mixer.Add(mix.Tone(f, seconds: 0.55, rate: rate, gain: 0.22, harmonic: 0.4))
            v.Wait = int(delay * float32(rate))
            v.Gain = 0.9
        }
    }

    func knock(strength: float32, pan: float32) {
        if Muted { return }
        var noise = mix.Noise(seed: uint32(Mixer.Voices.count * 31 + 5))
        var lp = mix.Biquad(.lowpass, frequency: 420, q: 0.9, rate: rate)
        var t = 0
        let total = rate / 3
        let r = rate
        var phase: float32 = 0
        let v = Mixer.Add(mix.Voice { buf, n in
            for i in 0..<n {
                if t >= total { return false }
                let env = 1 / (1 + float32(t) / float32(r) * 14 + float32(t * t) / float32(r * r) * 60)
                phase += 55 / float32(r)
                buf[i] = (lp.Run(noise.Next()) * 1.6 + sine(phase) * 0.6) * env
                t += 1
            }
            return true
        })
        v.Gain = 0.8 * strength
        v.Pan = pan
    }
}

// engine is one car's engine voice: a V8 (four firings a turn), its
// pulses ringing through an exhaust resonance that rises with the revs
// and a low body resonance, intake noise with the throttle, a little
// crackle lifting off at high revs; all through a soft saturation.
final class engine {
    let rate: int
    var rpm: float32 = 900
    var load: float32 = 0
    var boost: float32 = 0
    var pitch: float32 = 1
    let player: bool
    var voice: mix.Voice! = nil
    // Running state, per sample.
    var phase: float32 = 0
    var crank: float32 = 0
    var smoothRpm: float32 = 900
    var smoothLoad: float32 = 0
    var cylinder = 0
    var noise: mix.Noise
    var exhaust = mix.Biquad()
    var body = mix.Biquad()
    var intake = mix.Biquad()
    var dc = mix.Biquad()
    var pop: float32 = 0
    var retune = 0

    init(rate: int, seed: uint32, player: bool) {
        self.rate = rate
        self.player = player
        noise = mix.Noise(seed: seed &+ 99)
        dc = mix.Biquad(.highpass, frequency: 28, q: 0.7, rate: rate)
        voice = mix.Voice { buf, n in self.fill(&buf, n) }
    }

    func fill(buf: inout [float32], n: int) -> bool {
        let sr = float32(rate)
        // Each cylinder a touch different: the uneven beat of a crossplane V8.
        let firing: [float32] = [1, 0.78, 0.93, 0.7, 0.96, 0.74, 0.88, 0.81]
        for i in 0..<n {
            smoothRpm += (rpm - smoothRpm) * 0.0008
            smoothLoad += (load - smoothLoad) * 0.0012
            // Retune the resonances every 64 samples.
            if retune <= 0 {
                let r = smoothRpm / 7800
                exhaust.Set(.bandpass, frequency: (180 + 950 * r) * pitch, q: 2.2 + 2 * smoothLoad, rate: rate)
                body.Set(.lowpass, frequency: (90 + 260 * r) * pitch, q: 1.4, rate: rate)
                intake.Set(.bandpass, frequency: (1400 + 2400 * r) * pitch, q: 1.2, rate: rate)
                retune = 64
            }
            retune -= 1
            let f = smoothRpm / 60 * 4 * pitch
            phase += f / sr
            var kick: float32 = 0
            if phase >= 1 {
                phase -= 1
                cylinder = (cylinder + 1) % 8
                kick = firing[cylinder] * (0.5 + 0.9 * smoothLoad)
                // Off the throttle at high revs: the odd pop.
                if smoothLoad < 0.15 && smoothRpm > 3500 && noise.Next() > 0.82 { pop = 1 }
            }
            // The crank's own turning: a low hum under the pulses.
            crank += smoothRpm / 60 / 2 * pitch / sr
            if crank >= 1 { crank -= 1 }
            let hum = sine(crank) * 0.18 + sine(phase) * 0.22
            let pulse = kick * 3
            var x = exhaust.Run(pulse) * 1.3 + body.Run(pulse) * 1.5 + hum * (0.4 + 0.6 * smoothLoad)
            x += intake.Run(noise.Next()) * (0.06 + 0.22 * smoothLoad * smoothRpm / 7800) + noise.Next() * 0.04 * boost
            if pop > 0.01 {
                x += noise.Next() * pop * 0.9
                pop *= 0.985
            }
            // Saturation: louder and rougher with load.
            let drive = 1.2 + 1.8 * smoothLoad
            x = tanh(x * drive) * (0.5 + 0.35 * smoothLoad)
            buf[i] = dc.Run(x)
        }
        return true
    }
}

enum noiseKind {
    case screech
    case wind
    case rush
    case crowd
}

// noiseVoice is a shaped noise: screeching tires (a whistle and a hiss),
// wind (low, rising with speed), the nitro's rush, a crowd's roar.
final class noiseVoice {
    let rate: int
    let kind: noiseKind
    var amount: float32 = 0
    var voice: mix.Voice! = nil
    var noise: mix.Noise
    var a = mix.Biquad()
    var b = mix.Biquad()
    var phase: float32 = 0
    var wobble: float32 = 0
    var retune = 0

    init(rate: int, seed: uint32, kind: noiseKind) {
        self.rate = rate
        self.kind = kind
        noise = mix.Noise(seed: seed)
        voice = mix.Voice { buf, n in self.fill(&buf, n) }
        voice.Gain = 0
    }

    func fill(buf: inout [float32], n: int) -> bool {
        let sr = float32(rate)
        for i in 0..<n {
            if retune <= 0 {
                switch kind {
                case .screech:
                    a.Set(.bandpass, frequency: 950 + 450 * amount + 120 * sine(wobble / 6.2832), q: 7, rate: rate)
                    b.Set(.bandpass, frequency: 2600, q: 2, rate: rate)
                case .wind:
                    a.Set(.lowpass, frequency: 250 + 1300 * amount, q: 0.8, rate: rate)
                    b.Set(.bandpass, frequency: 600 + 900 * amount, q: 1.5, rate: rate)
                case .rush:
                    a.Set(.highpass, frequency: 900, q: 0.7, rate: rate)
                    b.Set(.lowpass, frequency: 140, q: 1.2, rate: rate)
                case .crowd:
                    a.Set(.bandpass, frequency: 700 + 300 * sine(wobble * 0.3 / 6.2832), q: 0.9, rate: rate)
                    b.Set(.bandpass, frequency: 1800, q: 1.5, rate: rate)
                }
                retune = 128
            }
            retune -= 1
            wobble += 6 / sr
            let w = noise.Next()
            var x: float32 = 0
            switch kind {
            case .screech:
                phase += (1150 + 300 * amount + 80 * sine(wobble * 2.3 / 6.2832)) / sr
                if phase >= 1 { phase -= 1 }
                x = a.Run(w) * 2.2 + b.Run(w) * 0.5 + sine(phase) * 0.25 * amount
            case .wind:
                x = a.Run(w) * 1.4 + b.Run(w) * 0.35
            case .rush:
                x = a.Run(w) * 0.8 + b.Run(w) * 1.2
            case .crowd:
                // Many voices: a band of noise that swells and falls.
                let swell = 0.7 + 0.3 * sine(wobble * 0.7 / 6.2832) * sine(wobble * 0.23 / 6.2832)
                x = (a.Run(w) * 1.2 + b.Run(w) * 0.3) * swell
            }
            buf[i] = x
        }
        return true
    }
}

// tanh, near enough for a saturator (a Padé fit, exact at 0, flat
// past ±3): math.Exp per sample costs too much.
func tanh(x: float32) -> float32 {
    if x > 3 { return 1 }
    if x < -3 { return -1 }
    let x2 = x * x
    return x * (27 + x2) / (27 + 9 * x2)
}

// sine is sin(2π·phase) for a phase in turns, from a table: math.Sin per
// sample costs too much.
let sineTable: [float32] = makeSine()

func makeSine() -> [float32] {
    var t: [float32] = []
    for i in 0...1024 { t.append(math.Sin(float32(i) / 1024 * 2 * float32(math.Pi))) }
    return t
}

func sine(phase: float32) -> float32 {
    var p = phase - math.Floor(phase)
    p *= 1024
    let i = int(p)
    let f = p - float32(i)
    return sineTable[i] + (sineTable[i + 1] - sineTable[i]) * f
}
