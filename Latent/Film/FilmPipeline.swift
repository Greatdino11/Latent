import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Pipeline

enum FilmPipeline {
    static func apply(stock: FilmStock, to scene: CIImage, options: DevelopOptions, cube: Data, context: CIContext, labEV: Double = 0,
                      cubeDimension: Int = LUT.dimension, depth: CIImage? = nil) -> CIImage {
        var img = crop(scene, to: options.aspect, shift: options.cropShift ?? 0)
        let extent = img.extent
        let short = min(extent.width, extent.height)

        // 1. Exposure (scene-linear): capture compensation, stock bias, and any push/pull chosen afterwards.
        let ev = options.exposure + stock.exposureBias + (options.pushPull ?? 0) + labEV
        if ev != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]) }

        // Portrait blur in scene light, so out-of-focus highlights bloom into proper bokeh.
        if let lens = options.portraitLens, let depth, (options.blurAmount ?? 0.6) > 0.01 {
            // Crop the (small) depth map the same way as the frame, keeping its own resolution: the blur
            // upsamples it against the photo so its edges follow real object edges.
            let d = scene.extent, de = depth.extent
            let r = cropRect(d, to: options.aspect, shift: options.cropShift ?? 0)
            let kx = de.width / d.width, ky = de.height / d.height
            let small = CGRect(x: de.minX + (r.minX - d.minX) * kx, y: de.minY + (r.minY - d.minY) * ky,
                               width: r.width * kx, height: r.height * ky)
            let depthSmall = depth.cropped(to: small).transformed(by: CGAffineTransform(translationX: -small.minX, y: -small.minY))
            img = Portrait.blur(img, depth: depthSmall, lens: lens, amount: options.blurAmount ?? 0.6,
                                focus: options.focusDepth ?? 0.8, extent: extent, short: short)
        }

        let exposedScene = img

        // 2. Highlight mask from scene light: drives halation.
        let threshold: CGFloat = options.sceneReferred ? 0.9 : 0.62
        let mask = highlightMask(img, threshold: threshold, extent: extent)

        // 3. Print through the stock's characteristic curves (3D LUT over +5.5 stops).
        let grade = CIFilter.colorCubeWithColorSpace()
        grade.inputImage = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: LUT.headroomEV])
        grade.cubeDimension = Float(cubeDimension)
        grade.cubeData = cube
        grade.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        img = grade.outputImage ?? img

        // Expired film ages the emulsion itself: before glow, leaks and grain sit on top.
        if let e = options.expired, e > 0.01 { img = expire(img, amount: e, seed: options.seed) }

        // Direct flash on film: harder contrast and a hot halo on the lit subject.
        let flash = options.flashFired == true
        if flash {
            img = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.07, kCIInputSaturationKey: 1.04])
        }

        // 4. Halation: light scattering back through the emulsion, red-orange around bright edges.
        if options.halation, stock.halation > 0, let mask,
           let glow = halation(mask, stock: flash ? stock.with(\.halation, stock.halation * 1.35) : stock, short: short, extent: extent) {
            img = add(glow, onto: img)
        }

        // 5. Diffusion bloom.
        if stock.bloom > 0 {
            let b = CIFilter.bloom()
            b.inputImage = img.clampedToExtent()
            b.radius = Float(short * 0.012)
            // Gentler on RAW: big bright skies otherwise haze the whole frame.
            b.intensity = Float((options.sceneReferred ? 0.2 : 0.3) * stock.bloom)
            img = b.outputImage?.cropped(to: extent) ?? img
        }

        // 6. Softness: no phone sharpening, a little lens/scan blur instead.
        if stock.softness > 0 {
            let soft = img.clampedToExtent().applyingGaussianBlur(sigma: short * 0.0011).cropped(to: extent)
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = img; mix.targetImage = soft; mix.time = Float(min(1, stock.softness * 0.9 * (options.crisp == true ? 0.45 : 1)))
            img = mix.outputImage ?? img
        }

        // 7. Lateral chromatic aberration.
        if stock.aberration > 0 { img = aberration(img, amount: 0.0012 * stock.aberration * (options.crisp == true ? 0.5 : 1), extent: extent) }

        // 8. Lens flare ghosts from a bright point source.
        if options.flareStrength > 0, stock.flare > 0, let hot = highlightMask(exposedScene, threshold: options.sceneReferred ? 2.5 : 0.93, extent: extent) {
            img = flare(img, mask: hot, amount: options.flareStrength, sceneReferred: options.sceneReferred, stock: stock, extent: extent, short: short, context: context)
        }

        // 9. Vignette (deeper falloff with flash: the light drops off toward the corners).
        let vignette = stock.vignette + (flash ? 0.3 : 0)
        if vignette > 0 {
            let v = CIFilter.vignetteEffect()
            v.inputImage = img
            v.center = CGPoint(x: extent.midX, y: extent.midY)
            v.radius = Float(hypot(extent.width, extent.height) * 0.5 * 0.62)
            v.intensity = Float(vignette * 0.85)
            v.falloff = 0.65
            img = v.outputImage ?? img
        }

        // 9b. Light leak: light fogging the film from one edge.
        if let leak = options.lightLeak, leak > 0 {
            img = lightLeak(img, amount: leak, seed: options.seed, extent: extent, short: short)
        }

        // 10. Grain last, on top of everything, like real silver.
        // A Process Zero frame already carries real sensor noise: add less synthetic grain on top.
        // Expired film is grainier too.
        let grainUser = options.grainAmount * (options.processZero == true ? 0.75 : 1) * (1 + 0.8 * (options.expired ?? 0))
        img = grain(on: img, stock: stock, user: grainUser, push: options.pushPull ?? 0, iso: options.iso, extent: extent, short: short)

        // 11. The lab scanner reads the whole frame, grain included.
        if let scanner = options.scanner { img = scan(img, scanner) }

        return img.cropped(to: extent)
    }

    /// Expired film: base fog lifts and tints the blacks, contrast and saturation fade, and the colour drifts. Which
    /// way it drifts (magenta, green, warm or cyan) is fixed per frame by `seed`, like a batch of old film.
    static func expire(_ img: CIImage, amount e: Double, seed: UInt64) -> CIImage {
        var rng = SeededRandom(seed: seed ^ 0xE891_2ED0)
        let casts: [RGB] = [RGB(0.05, -0.04, 0.04), RGB(-0.04, 0.04, -0.03), RGB(0.05, 0.02, -0.06), RGB(-0.04, 0.0, 0.05)]
        let cast = casts[Int(rng.unit() * Double(casts.count)) % casts.count] * (e * (0.6 + 0.4 * rng.unit()))
        // Core Image works in linear light here: a little lift goes a long way once encoded for display.
        let fog = RGB(0.030, 0.021, 0.017) * e                      // orange-brown base fog
        let k = 1 - 0.25 * e
        let faded = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 - 0.15 * e, kCIInputSaturationKey: 1 - 0.3 * e])
        return faded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k * (1 + cast.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k * (1 + cast.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k * (1 + cast.z), w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: fog.x + 0.012 * e, y: fog.y + 0.012 * e, z: fog.z + 0.012 * e, w: 0)])
    }

    /// The lab scanner's character. Frontier: punchier, warmer, richer colour. Noritsu: flatter and truer, more open
    /// shadows, slightly cooler.
    static func scan(_ img: CIImage, _ s: ScannerLook) -> CIImage {
        switch s {
        case .frontier:
            return img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.07, kCIInputSaturationKey: 1.08])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.12])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.02, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.97, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0, y: 0.0012, z: 0.002, w: 0)])   // a hint of cyan-green in the blacks
        case .noritsu:
            return img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.93, kCIInputSaturationKey: 0.96])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.985, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.985, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0.003, y: 0.003, z: 0.003, w: 0)])
        }
    }

    /// The largest whole-pixel rectangle inside `r`. Scaled RAW decodes have fractional edges; rounding outward
    /// (`.integral`) would keep a half-covered edge column that prints as a dark line.
    static func wholePixels(_ r: CGRect) -> CGRect {
        let x0 = ceil(r.minX - 0.001), y0 = ceil(r.minY - 0.001)
        let x1 = floor(r.maxX + 0.001), y1 = floor(r.maxY + 0.001)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Crop to the aspect ratio, matching the frame's own orientation, slid by `shift` along its free direction.
    static func crop(_ image: CIImage, to aspect: AspectRatio?, shift: Double = 0) -> CIImage {
        let rect = cropRect(image.extent, to: aspect, shift: shift)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Which way a crop has room to slide, if any.
    enum SlideAxis { case horizontal, vertical }

    static func slideAxis(width: CGFloat, height: CGFloat, aspect: AspectRatio?) -> SlideAxis? {
        guard let aspect, width > 0, height > 0 else { return nil }
        let target = height > width ? 1 / aspect.longOverShort : aspect.longOverShort
        let r = width / height
        if abs(r - target) < 0.005 { return nil }
        return r > target ? .horizontal : .vertical
    }

    /// The rectangle of `e` with the aspect ratio (in the frame's own orientation), centred and then slid by `shift`
    /// (−1 … 1) across the spare room; `e` itself for nil.
    static func cropRect(_ e: CGRect, to aspect: AspectRatio?, shift: Double = 0) -> CGRect {
        guard let aspect else { return e }
        let portrait = e.height > e.width
        let target = portrait ? 1 / aspect.longOverShort : aspect.longOverShort   // width / height
        var w = e.width, h = e.height
        if w / h > target { w = (h * target).rounded() } else { h = (w / target).rounded() }
        let t = CGFloat(min(1, max(-1, shift)))
        let x = e.midX - w / 2 + t * (e.width - w) / 2
        let y = e.midY - h / 2 + t * (e.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h).integral.intersection(e.integral)
    }

    /// Additive blend that keeps the background's alpha.
    static func add(_ light: CIImage, onto img: CIImage) -> CIImage {
        let f = CIFilter.linearDodgeBlendMode(); f.inputImage = light; f.backgroundImage = img
        return f.outputImage ?? img
    }

    /// Grey image: how far each pixel's luminance is above `threshold`, in units of the threshold.
    static func highlightMask(_ img: CIImage, threshold t: CGFloat, extent: CGRect) -> CIImage? {
        let k = 1 / t
        let m = CIFilter.colorMatrix()
        m.inputImage = img
        let luma = CIVector(x: 0.2126 * k, y: 0.7152 * k, z: 0.0722 * k, w: 0)
        m.rVector = luma; m.gVector = luma; m.bVector = luma
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: -1, y: -1, z: -1, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = m.outputImage
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1)
        clamp.maxComponents = CIVector(x: 6, y: 6, z: 6, w: 1)
        return clamp.outputImage?.cropped(to: extent)
    }

    static func tinted(_ i: CIImage, _ c: RGB, _ amount: Double) -> CIImage? {
        let f = CIFilter.colorMatrix(); f.inputImage = i
        f.rVector = CIVector(x: c.x * amount, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: c.y * amount, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: c.z * amount, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage
    }

    static func halation(_ mask: CIImage, stock: FilmStock, short: CGFloat, extent: CGRect) -> CIImage? {
        let base = mask.clampedToExtent()
        let wide = base.applyingGaussianBlur(sigma: short * 0.014)
        let tight = base.applyingGaussianBlur(sigma: short * 0.0035)
        let s = stock.halation * 0.22
        guard let a = tinted(wide, stock.halationTint, s * 0.8), let b = tinted(tight, stock.halationTint, s * 0.6) else { return nil }
        return add(a, onto: b).cropped(to: extent)
    }

    /// Red and blue planes scaled slightly about the centre, like an uncorrected lens.
    static func aberration(_ img: CIImage, amount: CGFloat, extent: CGRect) -> CIImage {
        let c = CGPoint(x: extent.midX, y: extent.midY)
        func scaled(_ k: CGFloat) -> CGAffineTransform {
            CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: k, y: k).translatedBy(x: -c.x, y: -c.y)
        }
        let base = img.clampedToExtent()
        func plane(_ i: CIImage, _ ch: Int) -> CIImage? {
            let f = CIFilter.colorMatrix(); f.inputImage = i
            let zero = CIVector(x: 0, y: 0, z: 0, w: 0)
            f.rVector = ch == 0 ? CIVector(x: 1, y: 0, z: 0, w: 0) : zero
            f.gVector = ch == 1 ? CIVector(x: 0, y: 1, z: 0, w: 0) : zero
            f.bVector = ch == 2 ? CIVector(x: 0, y: 0, z: 1, w: 0) : zero
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return f.outputImage
        }
        guard let r = plane(base.transformed(by: scaled(1 + amount)), 0),
              let g = plane(base, 1),
              let b = plane(base.transformed(by: scaled(1 - amount)), 2) else { return img }
        let rg = CIFilter.maximumCompositing(); rg.inputImage = r; rg.backgroundImage = g
        let rgb = CIFilter.maximumCompositing(); rgb.inputImage = rg.outputImage; rgb.backgroundImage = b
        return rgb.outputImage?.cropped(to: extent) ?? img
    }

    /// Finds the brightest compact light source; if there is one, adds veiling glare and aperture ghosts
    /// along the line from the source through the centre of the frame.
    /// How strongly the brightest spot throws ghosts. `peak` is the blurred hot-spot mask value (scene luma ÷ 2.5 − 1
    /// for RAW). In a RAW the sun clips near the top of its range (≈ 20–32), while sunlit whites, bright bark and
    /// gaps of sky through branches sit around 3–10: those must not throw ghosts, or a lone green disc lands in the
    /// middle of a frame with no light source in it. Processed photos have no headroom, so any clipped spot counts.
    static func flareIntensity(peak: Float, sceneReferred: Bool) -> Double {
        guard sceneReferred else { return Double(min(1, peak / 0.03)) }
        let luma = (Double(peak) + 1) * 2.5
        return LUT.smoothstep(9, 16, luma)
    }

    static func flare(_ img: CIImage, mask: CIImage, amount: Double, sceneReferred: Bool, stock: FilmStock, extent: CGRect, short: CGFloat, context: CIContext) -> CIImage {
        // Blur then shrink the hot-spot mask so the biggest bright blob wins, then find its peak.
        let w = 64, h = max(8, Int((CGFloat(w) * extent.height / extent.width).rounded()))
        let small = mask.clampedToExtent().applyingGaussianBlur(sigma: short * 0.01).cropped(to: extent)
            .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / extent.width, y: CGFloat(h) / extent.height))
        var buf = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)

        var peak: Float = 0, pi = 0, pj = 0
        for j in 0..<h { for i in 0..<w { let v = buf[(j * w + i) * 4]; if v > peak { peak = v; pi = i; pj = j } } }
        guard peak > (sceneReferred ? 0.05 : 0.004) else { return img }
        var lit = 0
        for k in 0..<(w * h) where buf[k * 4] > peak * 0.3 { lit += 1 }
        let coverage = Double(lit) / Double(w * h)
        guard coverage < 0.08 else { return img }   // a broad bright area (sky) isn't a point source

        // Bitmap rows run top to bottom; Core Image's y axis runs bottom to top.
        let src = CGPoint(x: extent.minX + (CGFloat(pi) + 0.5) / CGFloat(w) * extent.width,
                          y: extent.maxY - (CGFloat(pj) + 0.5) / CGFloat(h) * extent.height)
        let intensity = flareIntensity(peak: peak, sceneReferred: sceneReferred)
        guard intensity > 0.01 else { return img }
        // A pin-point glint (a reflection) throws far weaker ghosts than the sun: scale by the source's size.
        let size = min(1, Double(lit) / 8)
        let strength = intensity * size * stock.flare * amount * (1 - coverage * 8)
        let centre = CGPoint(x: extent.midX, y: extent.midY)
        let dir = CGPoint(x: centre.x - src.x, y: centre.y - src.y)

        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        func disc(at p: CGPoint, radius r: CGFloat, hardness: CGFloat, color c: RGB, _ a: Double) -> CIImage? {
            let g = CIFilter.radialGradient()
            g.center = p; g.radius0 = Float(r * hardness); g.radius1 = Float(r)
            // Linear-light colours: plain CIColor(red:green:blue:) would treat these as gamma-encoded.
            g.color0 = CIColor(red: c.x * a, green: c.y * a, blue: c.z * a, alpha: 1, colorSpace: linear) ?? .black
            g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: linear) ?? .black
            return g.outputImage
        }
        var light: CIImage? = disc(at: src, radius: short * 0.55, hardness: 0, color: RGB(1, 0.62, 0.32), strength * 0.06)
        let ghosts: [(t: CGFloat, r: CGFloat, hard: CGFloat, c: RGB, a: Double)] = [
            (0.55, 0.035, 0.6, RGB(1.0, 0.6, 0.25), 0.16),
            (1.25, 0.075, 0.75, RGB(0.45, 1.0, 0.7), 0.09),
            (1.55, 0.045, 0.5, RGB(0.75, 0.5, 1.0), 0.12),
            (1.85, 0.13, 0.35, RGB(1.0, 0.45, 0.2), 0.14),
        ]
        for g in ghosts {
            let p = CGPoint(x: src.x + dir.x * g.t, y: src.y + dir.y * g.t)
            let tint = stock.isMonochrome ? RGB(repeating: g.c.sum() / 3) : g.c
            guard let d = disc(at: p, radius: short * g.r, hardness: g.hard, color: tint, strength * g.a) else { continue }
            light = light.map { add(d, onto: $0) } ?? d
        }
        guard let light else { return img }
        return add(light.cropped(to: extent), onto: img)
    }

    /// Fresh uniform RGB noise as large as the frame. CIRandomGenerator tiles a small texture, which shows up as a
    /// repeating pattern once grain is coarse and strong; a full-size buffer from the system RNG never repeats.
    /// Same statistics as before (uniform 0…1, std ≈ 0.289), so the grain calibration below still holds.
    static func whiteNoise(covering rect: CGRect) -> CIImage {
        let w = Int(rect.width), h = Int(rect.height)
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        // Alpha bytes are random too; force alpha to 1 so the colour matrix (which unpremultiplies) sees raw values.
        return CIImage(bitmapData: data, bytesPerRow: w * 4, size: CGSize(width: w, height: h), format: .RGBA8, colorSpace: nil)
            .settingAlphaOne(in: CGRect(x: 0, y: 0, width: w, height: h))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// A warm fog of light spilling in from one edge (which edge and where is fixed per frame by `seed`).
    static func lightLeak(_ img: CIImage, amount: Double, seed: UInt64, extent: CGRect, short: CGFloat) -> CIImage {
        var rng = SeededRandom(seed: seed ^ 0x51ED_1EAC)
        let edge = Int(rng.unit() * 4)
        let along = CGFloat(rng.range(0.15...0.85))
        // Real leaks hug the frame edge: the source sits well outside the frame, so only a band of glow enters.
        let reach = short * CGFloat(rng.range(0.55...0.8))
        let p: CGPoint
        switch edge {
        case 0: p = CGPoint(x: extent.minX - short * 0.22, y: extent.minY + extent.height * along)
        case 1: p = CGPoint(x: extent.maxX + short * 0.22, y: extent.minY + extent.height * along)
        case 2: p = CGPoint(x: extent.minX + extent.width * along, y: extent.minY - short * 0.22)
        default: p = CGPoint(x: extent.minX + extent.width * along, y: extent.maxY + short * 0.22)
        }
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        func glow(_ c: RGB, _ a: Double, radius: CGFloat) -> CIImage? {
            let g = CIFilter.radialGradient()
            g.center = p; g.radius0 = 0; g.radius1 = Float(radius)
            g.color0 = CIColor(red: c.x * a, green: c.y * a, blue: c.z * a, alpha: 1, colorSpace: linear) ?? .black
            g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: linear) ?? .black
            return g.outputImage
        }
        guard let wide = glow(RGB(1.0, 0.28, 0.06), amount * 0.26, radius: reach),
              let hot = glow(RGB(1.0, 0.62, 0.28), amount * 0.16, radius: reach * 0.5) else { return img }
        // Stretch along the edge so it reads as a streak, not a disc.
        let stretch: CGAffineTransform = edge < 2
            ? CGAffineTransform(translationX: p.x, y: p.y).scaledBy(x: 1, y: 2.4).translatedBy(x: -p.x, y: -p.y)
            : CGAffineTransform(translationX: p.x, y: p.y).scaledBy(x: 2.4, y: 1).translatedBy(x: -p.x, y: -p.y)
        let light = add(hot, onto: wide).transformed(by: stretch).cropped(to: extent)
        return add(light, onto: img)
    }

    /// Adaptive film grain, built the way grain behaves on real film rather than as an even noise overlay:
    /// - Tone: strongest in the midtones, fading in the brightest highlights and the deepest shadows (where a print
    ///   is almost all or almost no developed silver).
    /// - Structure: two layers, fine specks and coarser clumps, sized from the stock and the frame (so it looks the
    ///   same at 12MP and 48MP); colour films get partly independent dye clouds per layer, the blue coarsest.
    /// - Development: pushing coarsens and strengthens it; pulling softens it.
    /// - Light: high-ISO captures already carry sensor noise, so less grain is added on top.
    static func grain(on img: CIImage, stock: FilmStock, user: Double, push: Double = 0, iso: Double? = nil,
                      extent: CGRect, short: CGFloat) -> CIImage {
        var strength = stock.grain * user * pow(2, 0.35 * push)
        strength *= grainLightFactor(iso: iso)
        guard strength > 0.001 else { return img }

        let size = max(1, short / 2400) * stock.grainSize * (1 + 0.15 * max(0, push))
        let target = 0.008 + 0.05 * strength                    // overall std, in gamma space
        let base = img.applyingFilter("CILinearToSRGBToneCurve")
        let weight = toneWeight(base, extent: extent)
        let mid = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1,
                                         colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!).cropped(to: extent)
        let padded = extent.insetBy(dx: -24, dy: -24).integral

        // (scale of the clumps, share of the grain, colour mix rows R/G/B over the three noise channels)
        let layers: [(scale: CGFloat, share: Double, rows: [(Double, Double, Double)])] = [
            (1.0, 0.85, [(0.82, 0.18, 0), (0.82, 0, 0.18), (0.82, 0.09, 0.09)]),
            (2.6, 0.53, [(0.75, 0.25, 0), (0.75, 0, 0.25), (0.6, 0.15, 0.4)]),     // coarser, blue the coarsest
        ]
        var out = base
        for layer in layers {
            // Blurred uniform noise has std ≈ 0.078 / σ (measured). Layer centred on 0.5 for Linear Light.
            // The coarse layer is made at half size and scaled up (a quarter of the memory at 48MP); its blur is
            // measured in those half-size pixels.
            let coarse = layer.scale > 1.5
            let k: CGFloat = coarse ? 2 : 1
            let sigma = max(0.6, 0.55 * size * layer.scale / k)
            let h = CGFloat(target * layer.share * Double(sigma) / 0.078) / 2
            let region = coarse ? CGRect(x: padded.minX / 2, y: padded.minY / 2, width: padded.width / 2, height: padded.height / 2).integral : padded
            let m = CIFilter.colorMatrix()
            m.inputImage = whiteNoise(covering: region)
            if stock.isMonochrome {
                let v = CIVector(x: h, y: 0, z: 0, w: 0)
                m.rVector = v; m.gVector = v; m.bVector = v
            } else {
                let r = layer.rows
                m.rVector = CIVector(x: r[0].0 * h, y: r[0].1 * h, z: r[0].2 * h, w: 0)
                m.gVector = CIVector(x: r[1].0 * h, y: r[1].1 * h, z: r[1].2 * h, w: 0)
                m.bVector = CIVector(x: r[2].0 * h, y: r[2].1 * h, z: r[2].2 * h, w: 0)
            }
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            let bias = 0.5 - 0.5 * h
            m.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
            guard let blurred = m.outputImage?.applyingGaussianBlur(sigma: sigma) else { continue }
            let raw = (coarse ? blurred.transformed(by: CGAffineTransform(scaleX: k, y: k)) : blurred).cropped(to: extent)
            // Fade the layer towards neutral (0.5) where the tone carries little grain.
            let shaped = raw.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: mid, kCIInputMaskImageKey: weight])
            let blend = CIFilter.linearLightBlendMode()
            blend.inputImage = shaped
            blend.backgroundImage = out
            out = blend.outputImage ?? out
        }
        return out.applyingFilter("CISRGBToneCurveToLinear").cropped(to: extent)
    }

    /// How much grain each tone carries (gamma-encoded luminance in, weight out): a tent peaking at 0.45,
    /// ~0.3 in deep shadow and ~0.2 in clipped white, smoothed by working on a quarter-size copy.
    static func toneWeight(_ gammaImage: CIImage, extent: CGRect) -> CIImage {
        let luma = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        func line(_ k: CGFloat, _ c: CGFloat) -> CIImage {
            let v = CIVector(x: luma.x * k, y: luma.y * k, z: luma.z * k, w: 0)
            return gammaImage.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v, "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: c, y: c, z: c, w: 0)])
        }
        let rising = line(2.0, 0.1)                 // (L + 0.05) · 2
        let falling = line(-1.818, 1.818)           // (1 − L) · 1.818
        let tent = rising.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: falling])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                         "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        let w = tent.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.78, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.78, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.78, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0.22, y: 0.22, z: 0.22, w: 0)])
        return w.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
            .applyingGaussianBlur(sigma: 1.5)
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            .cropped(to: extent)
    }

    /// Less added grain at high ISO, where the capture's own noise already reads as grain.
    static func grainLightFactor(iso: Double?) -> Double {
        guard let iso, iso > 200 else { return 1 }
        return 1 / (1 + 0.18 * log2(iso / 200))
    }
}
