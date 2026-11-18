import CoreImage
import CoreImage.CIFilterBuiltins
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

    /// Develops a fresh capture and also returns its negative: the neutral scene in a 10-bit HEIF (see
    /// `NegativeCodec`), kept so the frame can be re-developed later.
    func develop(_ frame: CapturedFrame, stock: FilmStock, options: DevelopOptions) throws -> DevelopResult {
        var options = options
        let (scene, sceneReferred) = try decode(frame)
        options.sceneReferred = sceneReferred
        if frame.flashFired { options.flashFired = true }
        options.negativeFormat = NegativeCodec.current
        let negative = try context.heif10Representation(of: NegativeCodec.encode(scene), colorSpace: p3, options: [:])
        let jpeg = try print(scene, stock: stock, options: options, metadata: frame.metadata)
        return DevelopResult(jpeg: jpeg, negative: negative, options: options)
    }

    /// Prints a stored negative again, on any stock.
    func redevelop(negative: Data, metadata: [String: Any], stock: FilmStock, options: DevelopOptions) throws -> Data {
        guard let stored = CIImage(data: negative) else { throw DarkroomError.decode }
        let scene = NegativeCodec.decode(stored, format: options.negativeFormat)
        return try print(scene, stock: stock, options: options, metadata: metadata)
    }

    private func print(_ scene: CIImage, stock: FilmStock, options: DevelopOptions, metadata: [String: Any]) throws -> Data {
        let strength = min(1, max(0, options.strength ?? 1))
        let cube = mixedCube(stock, strength: strength, expandSDR: !options.sceneReferred)
        let effective = stock.scaled(by: strength)
        let lab = options.sceneReferred ? labCorrection(scene) : 0
        let image = FilmPipeline.apply(stock: effective, to: scene, options: options, cube: cube, context: context, labEV: lab)
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else {
            throw DarkroomError.render
        }
        let finished = Finisher.finish(cg, stock: stock, options: options)
        return try JPEGEncoder.encode(finished, metadata: metadata)
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
    private func decode(_ frame: CapturedFrame) throws -> (CIImage, Bool) {
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
            if pixels > 13_000_000 { raw.scaleFactor = Float((12_200_000 / pixels).squareRoot()) }
            raw.boostAmount = 0
            raw.extendedDynamicRangeAmount = 1
            if raw.isLocalToneMapSupported { raw.localToneMapAmount = 0 }
            if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
            if raw.isContrastSupported { raw.contrastAmount = 0 }
            guard let image = raw.outputImage else { throw DarkroomError.decode }
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
