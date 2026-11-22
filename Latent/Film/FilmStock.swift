import Foundation

typealias RGB = SIMD3<Double>

/// Per-hue-band adjustment. Bands are centred every 60°: red, yellow, green, cyan, blue, magenta.
/// A negative hue shift moves a band towards the previous hue (e.g. blue → cyan, green → yellow).
struct HueTweak {
    var hue: Double = 0   // degrees of rotation
    var sat: Double = 1   // saturation multiplier
    var lum: Double = 0   // brightness offset, scaled by pixel saturation
}

enum HueBand: Int, CaseIterable { case red, yellow, green, cyan, blue, magenta }

/// A film "emulation". Input is scene-linear light (mid grey = 0.18); the stock describes how the
/// emulsion responds (a per-channel log-exposure S-curve, like a film characteristic curve), its
/// colour rendering, and the optical/physical texture of the print. All looks are original.
struct FilmStock: Identifiable, Hashable {
    var id: String
    var name: String
    var iso: Int
    var blurb: String

    /// Channel weights for monochrome stocks (nil = colour stock).
    var mono: RGB? = nil

    // Response curve
    var exposureBias = 0.0
    var contrast = RGB(0.62, 0.62, 0.62)   // slope of each channel's log S-curve (per stop)
    var balance = RGB(0, 0, 0)             // per-channel shift in stops; unequal values give colour crossover
    var black = RGB(0.06, 0.06, 0.06)      // print black (lifted, often tinted)
    /// Shadow slope relative to `contrast` (< 1 = a longer, gentler toe that keeps detail in shade).
    var toe = 1.0
    var white = RGB(0.97, 0.96, 0.92)      // print white (creamy, never pure)

    // Colour (applied in scene-linear before the curve)
    var saturation = 1.0
    var temperature = 0.0     // -1 cool … +1 warm
    var tint = 0.0            // -1 green … +1 magenta
    var hues = Array(repeating: HueTweak(), count: 6)
    var shadowTint = RGB(0, 0, 0)
    var highlightTint = RGB(0, 0, 0)
    /// How much bright colours (skies) keep their hue instead of fading to the print's white. 0…1.
    var highlightColour = 0.6

    // Optics & texture
    var grain = 0.5
    var grainSize = 1.0
    var halation = 0.5
    var halationTint = RGB(1.0, 0.32, 0.10)
    var bloom = 0.35          // diffusion glow
    var softness = 0.35       // lens / scan softness
    var aberration = 0.4      // lateral chromatic aberration
    var flare = 0.5           // ghosting from bright point sources
    var vignette = 0.25

    var isMonochrome: Bool { mono != nil }
    var displayName: String { "\(name) \(iso)" }

    static func == (a: FilmStock, b: FilmStock) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    mutating func hue(_ band: HueBand, _ hue: Double = 0, sat: Double = 1, lum: Double = 0) {
        hues[band.rawValue] = HueTweak(hue: hue, sat: sat, lum: lum)
    }

    func with<T>(_ path: WritableKeyPath<FilmStock, T>, _ value: T) -> FilmStock {
        var s = self; s[keyPath: path] = value; return s
    }

    /// Raw scene light is much flatter than a phone's processed image. Calibrated on real iPhone ProRAW: give RAW
    /// prints more midtone contrast and slightly deeper (still tinted) blacks so they aren't milky — but a longer,
    /// gentler toe, so shade in harsh midday sun keeps its detail the way negative film does.
    func forRAW() -> FilmStock {
        var s = self
        s.contrast *= 1.15
        s.black *= 0.8
        s.toe *= 0.78
        return s
    }

    /// The stock's physical character scaled for a partial-strength print (colour is blended in the LUT).
    func scaled(by t: Double) -> FilmStock {
        guard t < 0.999 else { return self }
        var s = self
        s.exposureBias *= t
        s.grain *= 0.35 + 0.65 * t   // keep some grain: it's still film
        s.halation *= t; s.bloom *= t; s.softness *= t; s.aberration *= t; s.vignette *= t
        return s
    }
}

extension FilmStock {
    static let randomID = "random"

    /// Reference print used to blend looks down: plain filmic tone, true colour, no texture.
    static let neutral: FilmStock = {
        var s = FilmStock(id: "neutral", name: "Neutral", iso: 100, blurb: "")
        s.contrast = RGB(repeating: 0.72); s.black = RGB(repeating: 0.035); s.white = RGB(repeating: 0.975)
        s.grain = 0; s.halation = 0; s.bloom = 0; s.softness = 0; s.aberration = 0; s.flare = 0; s.vignette = 0
        return s
    }()

    static let all: [FilmStock] = [honey, coast, valley, pine, dusk, twilight, night, reel, sunny, cross, bypass, clear,
                                   silver, umber, noir]

    /// Built-in and custom stocks.
    static func with(id: String) -> FilmStock? { builtIn(id: id) ?? StockRegistry.stock(id: id) }
    static func builtIn(id: String) -> FilmStock? { all.first { $0.id == id } }
    /// Every stock the user can pick: built-ins, then their own.
    static var available: [FilmStock] { all + StockRegistry.customs }

    /// Golden-hour colour negative: cream highlights, olive-teal shadows, glowing halation.
    static let honey: FilmStock = {
        var s = FilmStock(id: "honey", name: "Honey", iso: 200,
                          blurb: "Golden-hour colour. Cream highlights, olive shadows, warm glow around the light.")
        s.exposureBias = 0.2
        s.contrast = RGB(0.62, 0.60, 0.56); s.balance = RGB(0.14, 0.02, -0.16)
        s.black = RGB(0.075, 0.080, 0.070); s.white = RGB(0.98, 0.955, 0.875)
        s.saturation = 0.94; s.temperature = 0.22; s.tint = 0.04
        s.hue(.red, 3, sat: 1.05)
        s.hue(.yellow, -6, sat: 1.12, lum: 0.04)
        s.hue(.green, -22, sat: 0.78)
        s.hue(.cyan, -6, sat: 0.9)
        s.hue(.blue, -14, sat: 0.8)
        s.hue(.magenta, 0, sat: 0.8)
        s.shadowTint = RGB(-0.01, 0.008, 0.006)
        s.grain = 0.55; s.halation = 0.75; s.bloom = 0.5; s.softness = 0.45; s.aberration = 0.45; s.flare = 0.7
        s.vignette = 0.3
        return s
    }()

    /// Airy seaside negative: teal skies, warm sand, milky blacks.
    static let coast: FilmStock = {
        var s = FilmStock(id: "coast", name: "Coast", iso: 400,
                          blurb: "Airy and pastel. Teal skies, warm sand, soft milky blacks.")
        s.exposureBias = 0.35
        s.contrast = RGB(0.56, 0.56, 0.52); s.balance = RGB(0.05, 0.06, 0.0)
        s.black = RGB(0.085, 0.095, 0.095); s.white = RGB(0.97, 0.96, 0.90)
        s.saturation = 0.86; s.temperature = 0.08
        s.hue(.red, 0, sat: 1.12)
        s.hue(.yellow, -4, sat: 1.0, lum: 0.03)
        s.hue(.green, -10, sat: 0.8)
        s.hue(.cyan, 0, sat: 1.12)
        s.hue(.blue, -26, sat: 0.92, lum: 0.06)
        s.hue(.magenta, 0, sat: 0.75)
        s.grain = 0.6; s.halation = 0.45; s.bloom = 0.4; s.softness = 0.4; s.aberration = 0.35; s.flare = 0.5
        s.vignette = 0.22
        return s
    }()

    /// Bright daylight slide-ish negative: yellow-greens, teal sky, warm skin.
    static let valley: FilmStock = {
        var s = FilmStock(id: "valley", name: "Valley", iso: 160,
                          blurb: "Late-sun daylight. Yellow-green hills, teal sky, warm skin, red fringes.")
        s.exposureBias = 0.1
        s.contrast = RGB(0.70, 0.70, 0.64); s.balance = RGB(0.12, 0.04, -0.12)
        s.black = RGB(0.05, 0.065, 0.065); s.white = RGB(0.98, 0.965, 0.90)
        s.saturation = 1.04; s.temperature = 0.18
        s.hue(.red, 4, sat: 1.05)
        s.hue(.yellow, -4, sat: 1.1, lum: 0.04)
        s.hue(.green, -22, sat: 1.08, lum: 0.05)
        s.hue(.cyan, -4, sat: 1.05)
        s.hue(.blue, -22, sat: 0.95)
        s.hue(.magenta, -12, sat: 0.85)
        s.grain = 0.5; s.halation = 0.6; s.bloom = 0.3; s.softness = 0.3; s.aberration = 0.6; s.flare = 0.5
        return s
    }()

    /// Dense, moody woodland stock.
    static let pine: FilmStock = {
        var s = FilmStock(id: "pine", name: "Pine", iso: 400,
                          blurb: "Moody and deep. Teal-green shadows, a warm sun breaking through.")
        s.exposureBias = -0.25
        s.contrast = RGB(0.74, 0.72, 0.66); s.balance = RGB(0.10, 0.04, -0.06)
        s.black = RGB(0.050, 0.060, 0.062); s.white = RGB(0.96, 0.94, 0.86)
        s.toe = 0.9                                   // keeps a little detail in deep shade instead of teal-black
        s.saturation = 0.84; s.temperature = 0.1
        s.hue(.yellow, -6, sat: 1.0)
        s.hue(.green, -12, sat: 0.78)
        s.hue(.blue, -12, sat: 0.78)
        s.hue(.magenta, 0, sat: 0.9)
        s.shadowTint = RGB(-0.006, 0.003, 0.006)
        s.grain = 0.6; s.halation = 0.65; s.bloom = 0.35; s.softness = 0.35; s.aberration = 0.4; s.flare = 0.9
        s.vignette = 0.35
        return s
    }()

    /// Faded, slightly expired look with pink highlights.
    static let dusk: FilmStock = {
        var s = FilmStock(id: "dusk", name: "Dusk", iso: 100,
                          blurb: "Faded and dreamy. Lifted plum blacks, rosy highlights, washed colour.")
        s.exposureBias = 0.3
        s.contrast = RGB(0.52, 0.50, 0.50); s.balance = RGB(0.10, -0.05, 0.05)
        s.black = RGB(0.095, 0.075, 0.095); s.white = RGB(0.98, 0.93, 0.90)
        s.saturation = 0.76; s.temperature = 0.12; s.tint = 0.18
        s.hue(.yellow, -8, sat: 0.85)
        s.hue(.green, -6, sat: 0.7)
        s.hue(.blue, -6, sat: 0.85)
        s.grain = 0.65; s.grainSize = 1.2; s.halation = 0.55; s.bloom = 0.55; s.softness = 0.55; s.aberration = 0.4
        s.flare = 0.6; s.vignette = 0.4
        return s
    }()

    /// Tungsten night stock: cool shadows, warm practicals, strong red halation.
    static let night: FilmStock = {
        var s = FilmStock(id: "night", name: "Night", iso: 800,
                          blurb: "After dark. Teal shadows, warm lamps, red halos and colour fringing.")
        s.exposureBias = 0.35
        // Tungsten film: warm room light prints near neutral and daylight goes cool. The warmth lives in the
        // highlights (lamps, windows), the teal in the shadows, rather than a cast over everything.
        s.contrast = RGB(0.72, 0.70, 0.66); s.balance = RGB(-0.02, 0.02, 0.06)
        s.black = RGB(0.045, 0.065, 0.075); s.white = RGB(0.97, 0.955, 0.93)
        s.saturation = 0.9; s.temperature = -0.45
        s.highlightTint = RGB(0.035, 0.01, -0.03); s.shadowTint = RGB(-0.01, 0.002, 0.012)
        s.hue(.red, 0, sat: 1.15)
        s.hue(.yellow, -8, sat: 1.05)
        s.hue(.green, 20, sat: 0.7)
        s.hue(.blue, -12, sat: 1.0)
        s.hue(.magenta, -12, sat: 0.85)
        s.grain = 0.85; s.grainSize = 1.35; s.halation = 1.0; s.halationTint = RGB(1.0, 0.25, 0.08)
        s.bloom = 0.4; s.softness = 0.4; s.aberration = 1.0; s.flare = 0.6; s.vignette = 0.4
        return s
    }()

    /// Punchy consumer colour film.
    static let sunny: FilmStock = {
        var s = FilmStock(id: "sunny", name: "Sunny", iso: 200,
                          blurb: "Holiday snapshot colour. Saturated warm tones, deep blues, gentle fade.")
        s.exposureBias = 0.1
        s.contrast = RGB(0.80, 0.78, 0.74); s.balance = RGB(0.12, 0.04, -0.14)
        s.black = RGB(0.045, 0.045, 0.05); s.white = RGB(0.99, 0.96, 0.88)
        s.saturation = 1.12; s.temperature = 0.22
        s.hue(.red, -2, sat: 1.15)
        s.hue(.yellow, -6, sat: 1.15)
        s.hue(.green, -14, sat: 0.95)
        s.hue(.blue, -8, sat: 1.1, lum: -0.05)
        s.hue(.magenta, -12, sat: 0.85)
        s.grain = 0.5; s.halation = 0.55; s.bloom = 0.3; s.softness = 0.3; s.aberration = 0.35; s.flare = 0.5
        s.vignette = 0.3
        return s
    }()

    /// The cleanest colour stock: fine grain, natural colour, still filmic highlights.
    static let clear: FilmStock = {
        var s = FilmStock(id: "clear", name: "Clear", iso: 100,
                          blurb: "Fine-grain and natural. True colour with soft, filmic highlights.")
        s.contrast = RGB(0.72, 0.72, 0.70); s.balance = RGB(0.04, 0.0, -0.04)
        s.black = RGB(0.035, 0.035, 0.038); s.white = RGB(0.98, 0.97, 0.94)
        s.saturation = 1.0; s.temperature = 0.06
        s.hue(.green, -6, sat: 0.92)
        s.hue(.blue, -6, sat: 0.95)
        s.hue(.magenta, -10, sat: 0.88)
        s.grain = 0.3; s.halation = 0.3; s.bloom = 0.2; s.softness = 0.2; s.aberration = 0.2; s.flare = 0.4
        s.vignette = 0.18
        return s
    }()

    /// Blue-hour stock: keeps a deep blue sky over a glowing warm horizon, with cool shadows.
    static let twilight: FilmStock = {
        var s = FilmStock(id: "twilight", name: "Twilight", iso: 400,
                          blurb: "Blue hour. Deep blue skies over a glowing horizon, cool shadows, warm lights.")
        s.exposureBias = 0.1
        s.contrast = RGB(0.70, 0.68, 0.62); s.balance = RGB(0.02, -0.02, 0.10)
        s.black = RGB(0.035, 0.045, 0.07); s.white = RGB(0.98, 0.95, 0.92)
        s.saturation = 1.06; s.temperature = -0.1
        s.hue(.red, 0, sat: 1.1)
        s.hue(.yellow, -8, sat: 1.15, lum: 0.03)
        s.hue(.cyan, 10, sat: 1.1)
        s.hue(.blue, 0, sat: 1.2, lum: -0.06)
        s.hue(.magenta, -10, sat: 1.0)
        s.shadowTint = RGB(-0.01, 0, 0.015)
        s.highlightColour = 0.85
        s.grain = 0.55; s.halation = 0.8; s.bloom = 0.35; s.softness = 0.3; s.aberration = 0.5; s.flare = 0.6
        s.vignette = 0.3
        return s
    }()

    /// Motion-picture look: teal shadows, orange skin and lights, gentle contrast.
    static let reel: FilmStock = {
        var s = FilmStock(id: "reel", name: "Reel", iso: 500,
                          blurb: "Cinema stock. Teal shadows, orange skin and lamps, low contrast, soft glow.")
        s.exposureBias = 0.15
        s.contrast = RGB(0.62, 0.60, 0.56); s.balance = RGB(0.18, 0.0, -0.10)
        s.black = RGB(0.035, 0.07, 0.085); s.white = RGB(0.98, 0.95, 0.86)
        s.saturation = 0.92
        s.hue(.red, 8, sat: 1.1)
        s.hue(.yellow, -12, sat: 1.12)
        s.hue(.green, 38, sat: 0.55)
        s.hue(.cyan, 0, sat: 1.15)
        s.hue(.blue, -22, sat: 0.95)
        s.shadowTint = RGB(-0.04, 0.012, 0.035); s.highlightTint = RGB(0.035, 0.012, -0.03)
        s.grain = 0.45; s.grainSize = 1.1; s.halation = 0.7; s.bloom = 0.4; s.softness = 0.45; s.aberration = 0.3
        s.flare = 0.5; s.vignette = 0.35
        return s
    }()

    /// Slide film developed as a negative: yellow-green highlights, blue shadows, loud colour.
    static let cross: FilmStock = {
        var s = FilmStock(id: "cross", name: "Cross", iso: 100,
                          blurb: "Cross-processed. Yellow-green highlights, blue shadows, loud, punchy colour.")
        s.exposureBias = 0.15
        s.contrast = RGB(0.80, 0.86, 1.05); s.balance = RGB(0.05, 0.12, -0.25)
        s.black = RGB(0.03, 0.055, 0.10); s.white = RGB(0.98, 1.0, 0.80)
        s.saturation = 1.2; s.tint = -0.15
        s.hue(.red, 0, sat: 1.2)
        s.hue(.yellow, -4, sat: 1.2)
        s.hue(.green, -10, sat: 1.1)
        s.hue(.blue, 0, sat: 1.1)
        s.highlightColour = 0.4
        s.grain = 0.4; s.halation = 0.4; s.bloom = 0.25; s.softness = 0.2; s.aberration = 0.5; s.flare = 0.5
        s.vignette = 0.4
        return s
    }()

    /// Bleach bypass: silver left in the print — desaturated, contrasty, metallic.
    static let bypass: FilmStock = {
        var s = FilmStock(id: "bypass", name: "Bypass", iso: 200,
                          blurb: "Bleach bypass. Silvery, desaturated and contrasty, with hard shadows.")
        s.contrast = RGB(0.95, 0.95, 0.92)
        s.black = RGB(0.03, 0.032, 0.035); s.white = RGB(0.96, 0.96, 0.95)
        s.saturation = 0.5; s.temperature = -0.05
        s.hue(.red, 0, sat: 0.8)
        s.highlightColour = 0.3
        s.grain = 0.55; s.grainSize = 1.1; s.halation = 0.25; s.bloom = 0.3; s.softness = 0.2; s.aberration = 0.2
        s.flare = 0.4; s.vignette = 0.45
        return s
    }()

    static let silver: FilmStock = {
        var s = FilmStock(id: "silver", name: "Silver", iso: 100,
                          blurb: "Fine-grain monochrome. Smooth tones and bright skies.")
        s.mono = RGB(0.30, 0.55, 0.15)
        s.contrast = RGB(repeating: 0.72)
        s.black = RGB(repeating: 0.045); s.white = RGB(0.97, 0.965, 0.95)
        s.grain = 0.4; s.halation = 0.2; s.halationTint = RGB(1, 1, 1); s.bloom = 0.3; s.softness = 0.3
        s.aberration = 0; s.flare = 0.4; s.vignette = 0.28
        return s
    }()

    /// Warm-toned black & white: brown shadows, cream highlights.
    static let umber: FilmStock = {
        var s = FilmStock(id: "umber", name: "Umber", iso: 400,
                          blurb: "Toned black & white. Warm brown shadows, cream highlights, soft grain.")
        s.mono = RGB(0.40, 0.45, 0.15)
        s.contrast = RGB(repeating: 0.78)
        s.black = RGB(0.06, 0.045, 0.03); s.white = RGB(0.98, 0.93, 0.84)
        s.shadowTint = RGB(0.03, 0.01, -0.02)
        s.grain = 0.45; s.halation = 0.2; s.halationTint = RGB(1, 0.85, 0.65); s.bloom = 0.3; s.softness = 0.35
        s.aberration = 0; s.flare = 0.4; s.vignette = 0.45
        return s
    }()

    static let noir: FilmStock = {
        var s = FilmStock(id: "noir", name: "Noir", iso: 3200,
                          blurb: "Push-processed black & white. Gritty, contrasty, red-filtered skies.")
        s.mono = RGB(0.55, 0.40, 0.05)
        s.exposureBias = 0.2
        s.contrast = RGB(repeating: 0.95)
        s.black = RGB(repeating: 0.03); s.white = RGB(repeating: 0.96)
        s.grain = 1.0; s.grainSize = 1.9; s.halation = 0.3; s.halationTint = RGB(1, 1, 1); s.bloom = 0.3
        s.softness = 0.35; s.aberration = 0; s.flare = 0.5; s.vignette = 0.5
        return s
    }()
}
