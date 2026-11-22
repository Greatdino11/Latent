import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import ImageIO
import UIKit

/// Develops frames one at a time (keeps memory bounded on rapid shooting).
actor Darkroom {
    static let shared = Darkroom()

    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Darkroom"])
    private var cubes: [String: Data] = [:]
    private var cubeOrder: [String] = []
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// Develops a fresh capture and also returns its negative: the neutral scene in a 10-bit HEIF (see
    /// `NegativeCodec`), kept so the frame can be re-developed later.
    func develop(_ frame: CapturedFrame, stock: FilmStock, options: DevelopOptions) throws -> DevelopResult {
        var clock = Stopwatch("develop \(stock.id)")
        var options = options
        let (decoded, sceneReferred) = try decode(frame, fullResolution: options.fullResolution == true)
        // Decode once: the negative, lab exposure, flare detection and the print all read this buffer instead
        // of each re-running the (expensive) RAW demosaic.
        let scene = try materialize(decoded)
        clock.lap("decode")
        options.sceneReferred = sceneReferred
        if frame.flashFired { options.flashFired = true }
        if frame.singleFrame { options.processZero = true }
        options.negativeFormat = NegativeCodec.current
        // Depth (portrait captures, iPhone Portrait-mode imports): kept so blur and focus can change later.
        var depth: (image: CIImage, png: Data)?
        if let given = frame.depth { depth = try? storeDepth(given) }
        else if case .processed(let data) = frame.source, let found = DepthMap.extract(from: data, context: context) {
            depth = try? storeDepth(found.image)
            if options.focusDepth == nil { options.focusDepth = found.focus }
        }
        if depth != nil, options.focusDepth == nil, let d = depth { options.focusDepth = DepthMap.autoFocus(d.image, matte: nil, context: context) }
        if depth == nil { options.portraitLens = nil }
        // Encode the negative (mostly the HEVC encoder) while the GPU prints, rather than one after the other.
        let negativeDone = DispatchGroup()
        var negativeResult: Result<Data, Error> = .failure(DarkroomError.encode)
        let (ctx, p3, toStore) = (context, p3, NegativeCodec.encode(scene))
        DispatchQueue.global(qos: .userInitiated).async(group: negativeDone) {
            negativeResult = Result { try ctx.heif10Representation(of: toStore, colorSpace: p3, options: [:]) }
        }
        let jpeg = try print(scene, stock: stock, options: options, metadata: frame.metadata, depth: depth?.image, clock: &clock)
        negativeDone.wait()
        let negative = try negativeResult.get()
        clock.lap("negative (overlapped)")
        clock.done()
        return DevelopResult(jpeg: jpeg, negative: negative, options: options, depth: depth?.png)
    }

    /// One pano shot, decoded to scene light and held in memory until the panorama is stitched. Scaled so five fit
    /// comfortably (long side ≤ 3024 px).
    func panoScene(of frame: CapturedFrame) throws -> (image: CIImage, sceneReferred: Bool) {
        let (decoded, sceneReferred) = try decode(frame)
        let long = max(decoded.extent.width, decoded.extent.height)
        let k = min(1, 3024 / long)
        let scaled = k < 0.999 ? decoded.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: k]) : decoded
        return (try materialize(scaled), sceneReferred)
    }

    /// A small plain rendering of a pano shot, for lining up the next one.
    func panoGhost(_ scene: CIImage) -> CGImage? {
        let long = max(scene.extent.width, scene.extent.height)
        let small = scene.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 700 / long])
        return context.createCGImage(small, from: small.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// Stitches the pano shots and develops the result as one frame.
    func developPanorama(_ scenes: [CIImage], sceneReferred: Bool, focal35: Double?, metadata: [String: Any],
                         stock: FilmStock, options: DevelopOptions) throws -> DevelopResult {
        let stitched = try materialize(Panorama.stitch(scenes, focal35: focal35))
        var o = options
        o.aspect = nil; o.cropShift = nil; o.portraitLens = nil
        return try develop(CapturedFrame(source: .image(stitched, sceneReferred: sceneReferred), metadata: metadata), stock: stock, options: o)
    }

    /// Prints a stored negative again, on any stock.
    func redevelop(negative: Data, depth: Data? = nil, metadata: [String: Any], stock: FilmStock, options: DevelopOptions) throws -> Data {
        guard let stored = CIImage(data: negative) else { throw DarkroomError.decode }
        var clock = Stopwatch("redevelop \(stock.id)")
        let scene = try materialize(NegativeCodec.decode(stored, format: options.negativeFormat))
        clock.lap("decode")
        defer { clock.done() }
        let depthImage = depth.flatMap { CIImage(data: $0, options: [.colorSpace: NSNull()]) }
        return try print(scene, stock: stock, options: options, metadata: metadata, depth: depthImage, clock: &clock)
    }

    /// Where auto-focus would put a frame's focus, from its stored depth map.
    func autoFocus(depth: Data) -> Double? {
        guard let image = CIImage(data: depth, options: [.colorSpace: NSNull()]) else { return nil }
        return DepthMap.autoFocus(image, matte: nil, context: context)
    }

    /// Saves a normalised depth map as an 8-bit grey PNG (stored values, no colour management) and returns the
    /// image read back from it, so the first print and every re-develop use identical depth.
    private func storeDepth(_ depth: CIImage) throws -> (image: CIImage, png: Data) {
        let e = depth.extent
        let grey = depth.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        guard let png = context.pngRepresentation(of: grey, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!),
              let back = CIImage(data: png, options: [.colorSpace: NSNull()]) else { throw DarkroomError.encode }
        return (back, png)
    }

    private func print(_ scene: CIImage, stock: FilmStock, options: DevelopOptions, metadata: [String: Any],
                       depth: CIImage? = nil, clock: inout Stopwatch) throws -> Data {
        let strength = min(1, max(0, options.strength ?? 1))
        let cube = mixedCube(stock, strength: strength, expandSDR: !options.sceneReferred)
        let effective = stock.scaled(by: strength)
        clock.lap("lut")
        let lab = options.sceneReferred ? labCorrection(scene) : 0
        clock.lap("lab")
        let image = FilmPipeline.apply(stock: effective, to: scene, options: options, cube: cube, context: context, labEV: lab,
                                       depth: depth)
        clock.lap("graph+flare")
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw DarkroomError.render
        }
        clock.lap("render")
        let finished = Finisher.finish(cg, stock: stock, options: options, context: context)
        let jpeg = try JPEGEncoder.encode(finished, metadata: metadata)
        clock.lap("finish+jpeg")
        return jpeg
    }

    /// Two negatives on one frame, like winding the film back: each at half exposure, added in scene light, the
    /// second scaled to fill the first. Printed as a new frame on `stock`, with its own negative.
    func doubleExposure(_ a: Data, _ ra: DevelopOptions, _ b: Data, _ rb: DevelopOptions, balance: Double = 0.5,
                        stock: FilmStock, options: DevelopOptions, metadata: [String: Any]) throws -> DevelopResult {
        guard let sa = CIImage(data: a), let sb = CIImage(data: b) else { throw DarkroomError.decode }
        let combined = Self.superimpose(NegativeCodec.decode(sa, format: ra.negativeFormat),
                                        NegativeCodec.decode(sb, format: rb.negativeFormat), balance: balance)
        let frame = CapturedFrame(source: .image(combined, sceneReferred: ra.sceneReferred), metadata: metadata)
        return try develop(frame, stock: stock, options: options)
    }

    /// Two scene-linear exposures on one frame, each given half the light (−1 EV) so the sum is exposed like a
    /// single shot. The second is scaled to fill the first frame and centred.
    static func superimpose(_ first: CIImage, _ second: CIImage, balance: Double = 0.5) -> CIImage {
        let e = first.extent, f = second.extent
        let k = max(e.width / f.width, e.height / f.height)
        let fitted = second
            .transformed(by: CGAffineTransform(translationX: -f.midX, y: -f.midY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
            .transformed(by: CGAffineTransform(translationX: e.midX, y: e.midY))
            .cropped(to: e)
        let b = CGFloat(min(1, max(0, balance)))
        let weigh: (CIImage, CGFloat) -> CIImage = { image, w in
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: w, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: w, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: w, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        return FilmPipeline.add(weigh(fitted, b), onto: weigh(first, 1 - b)).cropped(to: e)
    }

    /// The frame as it came out of the camera: same crop and exposure, but a plain neutral print with none of the
    /// film's colour, grain, glow, leaks, flare or lens blur. For "hold to compare" in the roll.
    func original(negative: Data, recipe: DevelopOptions, maxPixel: CGFloat = 2000) throws -> CGImage {
        var o = recipe
        o.portraitLens = nil; o.lightLeak = nil; o.dust = nil; o.flareAmount = 0; o.halation = false; o.grainAmount = 0
        o.frame = .none; o.dateStamp = false
        return try preview(negative: negative, recipe: o, stock: .neutral, maxPixel: maxPixel)
    }

    /// A frame for the contact sheet: the whole 3:2 negative (as it sits on the film, uncropped), plus where the
    /// frame's own crop falls inside it — normalised, top-left origin — when it's tighter than the full frame.
    func contactFrame(negative: Data, recipe: DevelopOptions, stock: FilmStock, maxPixel: CGFloat) throws -> (CGImage, CGRect?) {
        guard let stored = CIImage(data: negative) else { throw DarkroomError.decode }
        let e = NegativeCodec.decode(stored, format: recipe.negativeFormat).extent
        var o = recipe
        o.aspect = .r3x2; o.cropShift = nil; o.lightLeak = nil
        let image = try preview(negative: negative, recipe: o, stock: stock, maxPixel: maxPixel)
        let full = FilmPipeline.cropRect(e, to: .r3x2)
        let chosen = FilmPipeline.cropRect(e, to: recipe.aspect, shift: recipe.cropShift ?? 0).intersection(full)
        guard !chosen.isNull, chosen.width * chosen.height < full.width * full.height * 0.97 else { return (image, nil) }
        let mark = CGRect(x: (chosen.minX - full.minX) / full.width, y: (full.maxY - chosen.maxY) / full.height,
                          width: chosen.width / full.width, height: chosen.height / full.height)
        return (image, mark)
    }

    /// A quick, small print for the stock editor: the negative (or the test scene) scaled down, printed through a
    /// coarse 25³ table that's built fresh each time and never cached.
    func preview(negative: Data?, recipe: DevelopOptions?, stock: FilmStock, maxPixel: CGFloat = 900) throws -> CGImage {
        var options = recipe ?? DevelopOptions()
        let source: CIImage
        if let negative, let stored = CIImage(data: negative) {
            source = NegativeCodec.decode(stored, format: options.negativeFormat)
        } else {
            source = SimulatedScene.capture; options.sceneReferred = false; options.negativeFormat = nil
        }
        return try previewPrint(source, options: options, stock: stock, maxPixel: maxPixel)
    }

    /// A small print of a double exposure, for choosing the order and balance before exposing it for real.
    func doubleExposurePreview(_ a: Data, _ ra: DevelopOptions, _ b: Data, _ rb: DevelopOptions, balance: Double,
                               stock: FilmStock, options: DevelopOptions, maxPixel: CGFloat = 1000) throws -> CGImage {
        guard let sa = CIImage(data: a), let sb = CIImage(data: b) else { throw DarkroomError.decode }
        let combined = Self.superimpose(NegativeCodec.decode(sa, format: ra.negativeFormat),
                                        NegativeCodec.decode(sb, format: rb.negativeFormat), balance: balance)
        var o = options; o.sceneReferred = ra.sceneReferred; o.negativeFormat = nil
        return try previewPrint(combined, options: o, stock: stock, maxPixel: maxPixel)
    }

    private func previewPrint(_ source: CIImage, options: DevelopOptions, stock: FilmStock, maxPixel: CGFloat) throws -> CGImage {
        var options = options
        let long = max(source.extent.width, source.extent.height)
        let small = try materialize(source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: min(1, maxPixel / long)]))
        options.dateStamp = false; options.frame = .none; options.dust = nil
        let cube = LUT.build(stock, expandSDR: !options.sceneReferred, dimension: 25)
        let lab = options.sceneReferred ? labCorrection(small) : 0
        let image = FilmPipeline.apply(stock: stock, to: small, options: options, cube: cube, context: context, labEV: lab, cubeDimension: 25)
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else { throw DarkroomError.render }
        return cg
    }

    /// Renders an image once into a GPU-resident half-float buffer (extended linear, so highlights above 1.0
    /// survive) and returns an image backed by it. ~8 bytes a pixel: ~100 MB for a 12MP frame, freed after the develop.
    private func materialize(_ image: CIImage) throws -> CIImage {
        let e = FilmPipeline.wholePixels(image.extent)
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(e.width), Int(e.height), kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &buffer)
        guard let buffer else { throw DarkroomError.render }
        context.render(image.cropped(to: e).transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)), to: buffer,
                       bounds: CGRect(origin: .zero, size: e.size), colorSpace: linear)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: linear])
    }

    /// Printer correction, like a film lab: RAW frames are exposed to protect highlights, so a backlit scene comes
    /// out dark. Measure the frame's (centre-weighted) log-average brightness and print it partway toward normal.
    /// Deterministic for a given negative, so re-developing gives the same result.
    private func labCorrection(_ scene: CIImage) -> Double {
        let e = scene.extent
        guard e.width > 0, e.height > 0 else { return 0 }
        let w = 48, h = max(8, Int((48 * e.height / e.width).rounded()))
        let small = scene
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: CGFloat(w) / e.width,
                                                                    kCIInputAspectRatioKey: (CGFloat(h) / e.height) / (CGFloat(w) / e.width)])
        var buf = [Float](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
        var sum = 0.0, weights = 0.0
        for j in 0..<h {
            for i in 0..<w {
                let k = (j * w + i) * 4
                let l = 0.2126 * Double(buf[k]) + 0.7152 * Double(buf[k + 1]) + 0.0722 * Double(buf[k + 2])
                let dx = (Double(i) + 0.5) / Double(w) - 0.5, dy = (Double(j) + 0.5) / Double(h) - 0.5
                let wt = 1 - 1.2 * (dx * dx + dy * dy)          // gentle centre weighting
                sum += wt * log2(min(max(l, 0.0005), 8)); weights += wt
            }
        }
        guard weights > 0 else { return 0 }
        let logAverage = sum / weights
        let target = log2(0.15)
        return min(1.4, max(-0.6, (target - logAverage) * 0.8))
    }

    // MARK: LUT cache

    /// Builds (or loads from disk) the look tables for these stocks so the first frame on each develops quickly.
    /// Yields between tables so a photo being developed never waits behind the whole batch.
    func prewarm(_ stocks: [FilmStock], expandSDR: Bool) async {
        for stock in stocks + [.neutral] {
            _ = cube(stock, expandSDR: expandSDR)
            await Task.yield()
        }
    }

    /// The stock's table blended toward a neutral print by `strength`.
    private func mixedCube(_ stock: FilmStock, strength: Double, expandSDR: Bool) -> Data {
        let full = cube(stock, expandSDR: expandSDR)
        guard strength < 0.999 else { return full }
        let neutral = cube(.neutral, expandSDR: expandSDR)
        let t = Float(strength)
        var out = [Float](repeating: 0, count: full.count / 4)
        full.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            neutral.withUnsafeBytes { (n: UnsafeRawBufferPointer) in
                let fa = a.bindMemory(to: Float.self), fn = n.bindMemory(to: Float.self)
                for i in 0..<out.count { out[i] = fn[i] + (fa[i] - fn[i]) * t }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A stock's table from memory, then disk (Caches/LUT), else built and stored. Keyed by a hash of every
    /// stock parameter, so editing a stock invalidates its cache automatically.
    private func cube(_ stock: FilmStock, expandSDR: Bool) -> Data {
        let key = LUT.cacheKey(stock, expandSDR: expandSDR)
        if let hit = cubes[key] { touch(key); return hit }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LUT", isDirectory: true)
        let file = dir.appendingPathComponent(key + ".cube")
        let data: Data
        if let disk = try? Data(contentsOf: file), disk.count == LUT.byteCount {
            data = disk
        } else {
            data = LUT.build(stock, expandSDR: expandSDR)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        cubes[key] = data
        touch(key)
        while cubeOrder.count > 4 { cubes.removeValue(forKey: cubeOrder.removeFirst()) }   // ~4 MB each
        return data
    }

    private func touch(_ key: String) {
        cubeOrder.removeAll { $0 == key }
        cubeOrder.append(key)
    }

    /// Turns the capture into scene-linear light. ProRAW is decoded neutrally: no local tone mapping, no
    /// sharpening, no "boost" curve. That removes the phone look; the film curve does the tone instead.
    private func decode(_ frame: CapturedFrame, fullResolution: Bool = false) throws -> (CIImage, Bool) {
        switch frame.source {
        case .image(let image, let sceneReferred):
            return (image, sceneReferred)
        case .raw(let data, let hint):
            // Camera RAWs need their type: ImageIO reads e.g. a Nikon NEF as plain TIFF and would decode only the
            // embedded thumbnail.
            guard let raw = CIRAWFilter(imageData: data, identifierHint: hint) else { throw DarkroomError.decode }
            // Decode big RAWs (48MP ProRAW imports) at ~12MP: same as Latent's own frames, a quarter of the memory.
            let native = raw.nativeSize
            let pixels = native.width * native.height
            if pixels > 13_000_000, !fullResolution { raw.scaleFactor = Float((12_200_000 / pixels).squareRoot()) }
            raw.boostAmount = 0
            raw.extendedDynamicRangeAmount = 1
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            if frame.singleFrame {
                // Process Zero: keep the sensor's own luminance noise (it reads as grain); calm only the colour
                // speckle, which film doesn't have.
                if raw.isLuminanceNoiseReductionSupported { raw.luminanceNoiseReductionAmount = 0 }
                if raw.isColorNoiseReductionSupported { raw.colorNoiseReductionAmount = 0.6 }
            }
            if raw.isContrastSupported { raw.contrastAmount = 0 }
            guard var image = raw.outputImage else { throw DarkroomError.decode }
            // A scaled decode's last row/column is only partly covered (e.g. 8064 × 0.5001 = 4033.2 of 4034 px)
            // and would print as a dark line; trim one pixel all round.
            if raw.scaleFactor < 0.999 { image = image.cropped(to: image.extent.insetBy(dx: 1, dy: 1)) }
            return (image, true)
        case .processed(let data):
            guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                throw DarkroomError.decode
            }
            return (image, false)
        }
    }
}

/// How negatives are stored. Version 2 scales the scene so +6.5 stops over mid grey fits, then applies a 1/4
/// power before the HEIF's own sRGB curve. Together that is close to logarithmic: about 48 code values per stop
/// from deep shadow to highlight, so pushing a dark frame doesn't band. Version 1 (nil) was linear ÷8 + sRGB.
enum NegativeCodec {
    static let current = 2
    private static let headroomEV = -4.0     // ÷16
    private static let power = 0.25

    static func encode(_ scene: CIImage) -> CIImage {
        scene
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: headroomEV])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                                                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": power])
    }

    static func decode(_ stored: CIImage, format: Int?) -> CIImage {
        guard format == 2 else {
            return stored.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -LUT.headroomEV])
        }
        return stored
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / power])
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -headroomEV])
    }
}

/// Per-stage develop timings, printed when the app is launched with `-timing`.
struct Stopwatch {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-timing")
    private let name: String
    private let start = Date()
    private var last = Date()
    private var parts: [String] = []

    init(_ name: String) { self.name = name }

    mutating func lap(_ label: String) {
        guard Self.enabled else { return }
        let now = Date()
        parts.append("\(label) \(Int(now.timeIntervalSince(last) * 1000))ms")
        last = now
    }

    func done() {
        guard Self.enabled else { return }
        print("TIMING \(name): \(Int(Date().timeIntervalSince(start) * 1000))ms — " + parts.joined(separator: ", "))
    }
}
