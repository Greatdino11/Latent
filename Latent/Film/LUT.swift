import Foundation

/// Builds a 3D lookup table that turns scene-linear light into a film print.
///
/// The cube's input is the scene scaled by 1/`headroom` and sRGB-encoded (CIColorCubeWithColorSpace does
/// the encoding), so it covers +5.5 stops above mid grey without clipping. Output is sRGB-encoded print values.
enum LUT {
    static let dimension = 64
    static let headroom = 8.0          // scene-linear value mapped to cube input 1.0
    static let headroomEV = -3.0       // log2(1 / headroom), applied before the cube

    /// - Parameter expandSDR: the source is an already tone-mapped (display-referred) photo whose white is 1.0.
    ///   Expand it back toward scene light first so white lands ~+4.5 stops over grey instead of printing grey.
    static var byteCount: Int { dimension * dimension * dimension * 4 * MemoryLayout<Float>.size }

    /// Stable key for the cache file: changes whenever any stock parameter or the table layout changes.
    static func cacheKey(_ stock: FilmStock, expandSDR: Bool) -> String {
        let text = "v3|\(dimension)|\(headroom)|\(expandSDR)|\(String(describing: stock))"
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "\(stock.id)-\(String(hash, radix: 16))"
    }

    static func build(_ stock: FilmStock, expandSDR: Bool = false) -> Data {
        let stock = expandSDR ? stock : stock.forRAW()
        let d = dimension
        var buf = [Float](repeating: 0, count: d * d * d * 4)
        var axis = [Double](repeating: 0, count: d)
        for i in 0..<d {
            let x = srgbToLinear(Double(i) / Double(d - 1)) * headroom
            axis[i] = expandSDR ? expand(x) : x
        }
        var i = 0
        for b in 0..<d {
            for g in 0..<d {
                for r in 0..<d {
                    let c = transform(RGB(axis[r], axis[g], axis[b]), stock)
                    buf[i] = Float(c.x); buf[i + 1] = Float(c.y); buf[i + 2] = Float(c.z); buf[i + 3] = 1
                    i += 4
                }
            }
        }
        return buf.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Scene-linear RGB → sRGB-encoded print RGB.
    static func transform(_ input: RGB, _ s: FilmStock) -> RGB {
        var c = RGB(max(input.x, 0), max(input.y, 0), max(input.z, 0))
        var y: RGB
        if let w = s.mono {
            let l = (c * w).sum() / w.sum()
            let v = curve(l, s.contrast.x, s.balance.x, s.black.x, s.white.x)
            y = RGB(v, v, v) + (s.white - RGB(repeating: s.white.x)) * v   // let a tinted white tone the paper
        } else {
            c.x *= 1 + 0.12 * s.temperature
            c.z *= 1 - 0.12 * s.temperature
            c.y *= 1 - 0.06 * s.tint
            c = hueAdjust(c, s.hues)
            let l = RGB(repeating: luma(c))
            c = l + (c - l) * s.saturation
            c = RGB(max(c.x, 0), max(c.y, 0), max(c.z, 0))
            y = RGB(curve(c.x, s.contrast.x, s.balance.x, s.black.x, s.white.x),
                    curve(c.y, s.contrast.y, s.balance.y, s.black.y, s.white.y),
                    curve(c.z, s.contrast.z, s.balance.z, s.black.z, s.white.z))
            y = keepHighlightColour(y, scene: c, s)
        }
        let l = luma(y)
        y += s.shadowTint * ((1 - l) * (1 - l)) + s.highlightTint * (l * l)
        return clamp(y)
    }

    /// Per-channel curves pull every channel of a bright colour toward the same white, so skies wash out to cream.
    /// Blend in a hue-preserving version (tone-map the brightest channel, keep the scene's channel ratios) at the
    /// same brightness, more strongly the brighter the print.
    static func keepHighlightColour(_ y: RGB, scene c: RGB, _ s: FilmStock) -> RGB {
        let m = max(c.x, c.y, c.z)
        guard s.highlightColour > 0, m > 1e-6 else { return y }
        let mapped = srgbToLinear(curve(m, s.contrast.y, s.balance.y, s.black.y, s.white.y))
        let k = mapped / m
        var hp = RGB(linearToSrgb(c.x * k), linearToSrgb(c.y * k), linearToSrgb(c.z * k))
        let ly = luma(y), lh = luma(hp)
        if lh > 1e-4 { hp *= ly / lh }
        let w = smoothstep(0.3, 0.85, ly) * s.highlightColour
        return y + (hp - y) * w
    }

    /// Film characteristic curve: a sigmoid in log exposure (stops from mid grey), with a slightly
    /// steeper shoulder than toe, mapped between the print's black and white.
    static func curve(_ x: Double, _ k: Double, _ shift: Double, _ black: Double, _ white: Double) -> Double {
        guard x > 1e-7 else { return black }
        let e = log2(x / 0.18) + shift
        let slope = e < 0 ? k : k * 1.1
        let s = 1 / (1 + exp(-slope * e))
        return black + (white - black) * s
    }

    /// Hue/saturation tweaks per hue band. HSV hue and saturation don't depend on scale, so this works on linear light.
    static func hueAdjust(_ c: RGB, _ tweaks: [HueTweak]) -> RGB {
        var (h, sat, v) = rgbToHsv(c)
        guard sat > 0.0001, v > 0 else { return c }
        var shift = 0.0, satMul = 0.0, lum = 0.0
        for (i, t) in tweaks.enumerated() {
            var dh = abs(h - Double(i) * 60)
            if dh > 180 { dh = 360 - dh }
            let w = max(0, 1 - dh / 60)
            shift += w * t.hue; satMul += w * t.sat; lum += w * t.lum
        }
        let amt = smoothstep(0, 0.3, sat)   // leave near-neutrals alone
        h = (h + shift * amt).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        sat = min(1, sat * (1 + (satMul - 1) * amt))
        v = max(0, v * (1 + lum * sat))
        return hsvToRgb(h, sat, v)
    }

    /// Inverse of a simple display tone curve: 0.18 → ~0.20, 1.0 → 2.5.
    static func expand(_ x: Double) -> Double {
        let v = min(x, 0.995)
        return v / (1 - 0.6 * v)
    }

    // MARK: helpers

    static func linearToSrgb(_ x: Double) -> Double {
        let v = max(0, x)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
    static func srgbToLinear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    static func luma(_ c: RGB) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func clamp(_ c: RGB) -> RGB { RGB(clamp01(c.x), clamp01(c.y), clamp01(c.z)) }
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = clamp01((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
    }

    static func rgbToHsv(_ c: RGB) -> (Double, Double, Double) {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == c.x { h = 60 * ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = 60 * ((c.z - c.x) / d + 2) }
            else { h = 60 * ((c.x - c.y) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func hsvToRgb(_ h: Double, _ s: Double, _ v: Double) -> RGB {
        let c = v * s, x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let rgb: RGB
        switch h {
        case ..<60: rgb = RGB(c, x, 0)
        case ..<120: rgb = RGB(x, c, 0)
        case ..<180: rgb = RGB(0, c, x)
        case ..<240: rgb = RGB(0, x, c)
        case ..<300: rgb = RGB(x, 0, c)
        default: rgb = RGB(c, 0, x)
        }
        return rgb + RGB(repeating: m)
    }

    /// Sample colours (sRGB) for the little colour chart on each stock chip.
    static let chart: [RGB] = [
        RGB(0.86, 0.64, 0.52),  // skin
        RGB(0.42, 0.63, 0.90),  // sky
        RGB(0.36, 0.55, 0.26),  // foliage
        RGB(0.80, 0.20, 0.18),  // red
        RGB(0.95, 0.80, 0.30),  // yellow
    ]

    /// How an sRGB colour (treated as a scene at normal exposure) prints on a stock.
    static func preview(_ srgb: RGB, _ s: FilmStock) -> RGB {
        transform(RGB(srgbToLinear(srgb.x), srgbToLinear(srgb.y), srgbToLinear(srgb.z)), s)
    }
}
