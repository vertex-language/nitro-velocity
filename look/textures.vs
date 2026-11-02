package look

import (
    "image"
    "image/draw"
    "math"
    "text/font"
)

// The textures painted by code: kerbs, the finish line's checker, the
// wall's band, the crowd, banners, the soft shadow under a car. All
// sRGB, as the renderer reads base colors.

// grain is a little per-pixel noise, -1…1.
func grain(x: int, y: int, seed: int) -> float32 {
    var h = uint32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ seed &* 2147483647)
    h = (h ^ (h >> 13)) &* 1274126177
    h ^= h >> 16
    return float32(h & 0xFFFF) / 32768 - 1
}

func put(px: inout [uint8], i: int, r: float32, g: float32, b: float32, a: float32 = 1) {
    px[i * 4] = uint8(math.Clamp(r * 255 + 0.5, 0, 255))
    px[i * 4 + 1] = uint8(math.Clamp(g * 255 + 0.5, 0, 255))
    px[i * 4 + 2] = uint8(math.Clamp(b * 255 + 0.5, 0, 255))
    px[i * 4 + 3] = uint8(math.Clamp(a * 255 + 0.5, 0, 255))
}

/// kerbTexture is a kerb's paint: red then white down V (one of each per
/// repeat), with concrete block joints, rubber tire scuffs near the inner
/// bevel, and surface grain.
func kerbTexture() -> image.RGBA {
    let w = 64, h = 256
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        let red = y < h / 2
        let localY = y % (h / 2)
        let seam = localY < 2 || localY >= (h / 2 - 2)
        for x in 0..<w {
            let n = grain(x, y, 3) * 0.035
            let u = float32(x) / float32(w - 1)
            let edge = math.Min(u, 1 - u)
            // Tire rubber scuffing along the inner bevel (u ~ 0.05..0.35).
            let scuff = math.Exp(-((u - 0.18) * (u - 0.18)) / 0.018) * (0.18 + 0.08 * grain(x / 2, y / 8, 19))
            var wear: float32 = (0.84 + 0.16 * math.Clamp(edge * 6, 0, 1)) * (1 - scuff)
            if seam { wear *= 0.58 }
            if red { put(&px, y * w + x, (0.78 + n) * wear, (0.06 + n) * wear, (0.05 + n) * wear) }
            else { put(&px, y * w + x, (0.92 + n) * wear, (0.92 + n) * wear, (0.9 + n) * wear) }
        }
    }
    return image.RGBA(width: w, height: h, pixels: px)
}

/// checker is the finish line: 32 squares across, 4 along.
func checker() -> image.RGBA {
    let sq = 16, w = 32 * sq, h = 4 * sq
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let white = ((x / sq) + (y / sq)) % 2 == 0
            let n = grain(x, y, 9) * 0.02
            let v: float32 = white ? 0.9 + n : 0.04 + n
            put(&px, y * w + x, v, v, v)
        }
    }
    return image.RGBA(width: w, height: h, pixels: px)
}

/// band is the wall's painted top: red and white blocks along U with vertical
/// expansion joints.
func band() -> image.RGBA {
    let w = 256, h = 32
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        let wy = 0.88 + 0.12 * math.Sin(float32(y) / float32(h) * 3.14159)
        for x in 0..<w {
            let n = grain(x, y, 5) * 0.025
            let joint = (x % 128 < 2) ? float32(0.62) : float32(1.0)
            let k = wy * joint
            if x < w / 2 { put(&px, y * w + x, (0.75 + n) * k, (0.07 + n) * k, (0.06 + n) * k) }
            else { put(&px, y * w + x, (0.93 + n) * k, (0.93 + n) * k, (0.92 + n) * k) }
        }
    }
    return image.RGBA(width: w, height: h, pixels: px)
}

/// brakeBoard paints a corner distance marker ("150", "100", "50"): crisp
/// white numerals on a dark racing-green and black panel.
func brakeBoard(text: string) -> image.RGBA {
    let w = 256, h = 192
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let border = x < 8 || x >= w - 8 || y < 8 || y >= h - 8
            if border { put(&px, y * w + x, 0.92, 0.92, 0.90) }
            else if y < 38 { put(&px, y * w + x, 0.78, 0.08, 0.06) }
            else { put(&px, y * w + x, 0.04, 0.06, 0.05) }
        }
    }
    let face = font.Load(font.Spec(families: ["DIN Condensed", "Avenir Next Condensed", "Helvetica Neue"], size: 112, weight: 800))
    let run = face.Shape(text)
    let tw = face.Measure(text)
    draw.WithCanvas(&px, width: int32(w), height: int32(h)) { c in
        font.DrawRun(c, run, x: (float32(w) - tw) / 2, baseline: 152, scale: 1, color: draw.Color(245, 245, 242, 255))
    }
    return image.RGBA(width: w, height: h, pixels: px)
}

/// catchFenceTexture paints an alpha-masked FIA debris catch fence: steel
/// horizontal arrestor cables and diamond wire mesh.
func catchFenceTexture() -> image.RGBA {
    let w = 128, h = 128
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        let cable = (y % 24 < 3) || y < 5 || y >= h - 4
        for x in 0..<w {
            let d1 = (x + y) % 12
            let d2 = (x - y + 1200) % 12
            let wire = d1 < 2 || d2 < 2
            if cable {
                put(&px, y * w + x, 0.24, 0.26, 0.28, 0.95)
            } else if wire {
                put(&px, y * w + x, 0.32, 0.34, 0.37, 0.58)
            } else {
                put(&px, y * w + x, 0.28, 0.30, 0.33, 0.0)
            }
        }
    }
    return image.RGBA(width: w, height: h, pixels: px)
}

/// banner is a sign: words in heavy italic, white on a deep gradient, a
/// stripe of the accent color under them.
func banner(text: string, accent: draw.Color, width: int = 1024, height: int = 160) -> image.RGBA {
    var px = [uint8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let t = float32(y) / float32(height)
        for x in 0..<width {
            put(&px, y * width + x, 0.02 + 0.03 * t, 0.03 + 0.05 * t, 0.12 + 0.12 * t)
        }
    }
    let face = font.Load(font.Spec(families: ["Avenir Next Condensed", "Avenir Next", "Helvetica Neue"], size: float32(height) * 0.5, weight: 800, italic: true))
    let run = face.Shape(text)
    let tw = face.Measure(text)
    draw.WithCanvas(&px, width: int32(width), height: int32(height)) { c in
        c.Fill(draw.IRect(0, int32(height) - int32(height / 8), int32(width), int32(height / 8)), accent)
        font.DrawRun(c, run, x: (float32(width) - tw) / 2, baseline: float32(height) * 0.66, scale: 1, color: draw.Color(255, 255, 255, 255))
    }
    return image.RGBA(width: width, height: height, pixels: px)
}

/// shadowBlob is the soft dark under a car: a rounded rectangle fading
/// out at its edges (white, its alpha the darkness).
func shadowBlob() -> image.RGBA {
    let w = 64, h = 128
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let u = math.Abs((float32(x) + 0.5) / float32(w) * 2 - 1)
            let v = math.Abs((float32(y) + 0.5) / float32(h) * 2 - 1)
            let d = math.Max(math.Max(u - 0.55, 0) / 0.45, math.Max(v - 0.7, 0) / 0.3)
            let a = math.Clamp(1 - d * d * (3 - 2 * d), 0, 1) * (1 - 0.25 * math.Max(u, v))
            put(&px, y * w + x, 1, 1, 1, a)
        }
    }
    return image.RGBA(width: w, height: h, pixels: px)
}

/// flat is a texture of one color.
func flat(r: float32, g: float32, b: float32) -> image.RGBA {
    var px = [uint8](repeating: 0, count: 16)
    for i in 0..<4 { put(&px, i, r, g, b) }
    return image.RGBA(width: 2, height: 2, pixels: px)
}

/// plateTexture is a license plate: dark letters on white, a blue band.
func plateTexture() -> image.RGBA {
    let w = 512, h = 128
    var px = [uint8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let edge = x < 6 || x >= w - 6 || y < 6 || y >= h - 6
            if edge { put(&px, y * w + x, 0.1, 0.1, 0.12) }
            else if x < 52 { put(&px, y * w + x, 0.05, 0.2, 0.7) }
            else { put(&px, y * w + x, 0.94, 0.94, 0.92) }
        }
    }
    let face = font.Load(font.Spec(families: ["DIN Condensed", "Avenir Next Condensed", "Helvetica Neue"], size: 82, weight: 700))
    let text = "NITRO 01"
    let run = face.Shape(text)
    let tw = face.Measure(text)
    draw.WithCanvas(&px, width: int32(w), height: int32(h)) { c in
        font.DrawRun(c, run, x: 52 + (float32(w - 52) - tw) / 2, baseline: 98, scale: 1, color: draw.Color(20, 22, 28, 255))
    }
    return image.RGBA(width: w, height: h, pixels: px)
}
