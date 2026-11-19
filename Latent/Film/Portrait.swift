import CoreImage
import CoreImage.CIFilterBuiltins

/// Depth-based background blur with a few lens characters. `depth` is the frame's normalised depth map at its own
/// (low) resolution, cropped like the frame (near = 1); `focus` is the depth that stays sharp.
///
/// Three things keep it from looking fake: the depth map is upsampled against the photo so the sharp/blurred
/// boundary follows real edges; the background is blurred only from background pixels (a normalised blur), so the
/// sharp subject never smears into the blur behind it; and Swirl is a smooth rotational smear of that background
/// rather than overlapping copies.
enum Portrait {
    static func blur(_ img: CIImage, depth: CIImage, lens: PortraitLens, amount: Double, focus: Double,
                     extent: CGRect, short: CGFloat) -> CIImage {
        let refined = upsample(depth, guide: img, extent: extent)
        guard let mask = blurMask(refined, focus: focus, extent: extent, short: short) else { return img }
        let a = CGFloat(min(1, max(0, amount)))
        let blurred: CIImage?
        switch lens {
        case .classic:
            blurred = backgroundBlur(img, weight: mask, extent: extent) { masked($0, mask: mask, radius: a * short * 0.028) }
        case .bubble:
            // Ring bokeh, rendered at half size (it's costly) and scaled back.
            let r = Float(a * short * 0.013)
            blurred = backgroundBlur(img, weight: mask, extent: extent) { image in
                let half = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
                    .cropped(to: CGRect(x: -64, y: -64, width: extent.width / 2 + 128, height: extent.height / 2 + 128))
                let b = CIFilter.bokehBlur()
                b.inputImage = half; b.radius = r; b.ringAmount = 0.7; b.ringSize = 0.15; b.softness = 0.6
                return b.outputImage?.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
            }
        case .swirl:
            // A soft background blur, then a rotational smear about the centre (Gaussian-weighted, so no double
            // images) — the arc grows toward the edges, like the swirling bokeh of an old Petzval lens.
            guard let soft = backgroundBlur(img, weight: mask, extent: extent, blur: { masked($0, mask: mask, radius: a * short * 0.016) })
            else { return img }
            let c = CGPoint(x: extent.midX, y: extent.midY)
            let steps = 15, spread = Double(a) * 0.075
            var sum: CIImage?, total = 0.0
            let weights = (0..<steps).map { i -> Double in let t = Double(i) / Double(steps - 1) - 0.5; return exp(-t * t * 8) }
            total = weights.reduce(0, +)
            for i in 0..<steps {
                let angle = CGFloat(spread * (Double(i) / Double(steps - 1) - 0.5))
                let k = CGFloat(weights[i] / total)
                let part = soft.clampedToExtent()
                    .transformed(by: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y))
                    .applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
                sum = sum.map { FilmPipeline.add(part, onto: $0) } ?? part
            }
            blurred = sum
        }
        guard let blurred else { return img }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = blurred.cropped(to: extent)
        blend.backgroundImage = img
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: extent) ?? img
    }

    /// The low-res depth map brought up to the photo's size, following the photo's own edges.
    static func upsample(_ depth: CIImage, guide: CIImage, extent: CGRect) -> CIImage {
        let de = depth.extent
        if let f = CIFilter(name: "CIEdgePreserveUpsampleFilter") {
            f.setValue(guide.applyingFilter("CILinearToSRGBToneCurve").cropped(to: extent), forKey: kCIInputImageKey)
            f.setValue(depth, forKey: "inputSmallImage")
            f.setValue(4.0, forKey: "inputSpatialSigma")
            f.setValue(0.12, forKey: "inputLumaSigma")
            if let out = f.outputImage { return out.cropped(to: extent) }
        }
        return depth.transformed(by: CGAffineTransform(scaleX: extent.width / de.width, y: extent.height / de.height)).cropped(to: extent)
    }

    /// Blurs `img` using only the pixels `weight` marks as background: blur(img·w) ÷ blur(w). Where almost no
    /// background is in reach, it falls back to a plain blur (those pixels stay sharp in the final blend anyway).
    static func backgroundBlur(_ img: CIImage, weight: CIImage, extent: CGRect, blur: (CIImage) -> CIImage?) -> CIImage? {
        let w = weight.clampedToExtent()
        guard let weighted = CIFilter(name: "CIMultiplyCompositing", parameters: [kCIInputImageKey: w, kCIInputBackgroundImageKey: img.clampedToExtent()])?.outputImage,
              let num = blur(weighted), let den = blur(w), let plain = blur(img.clampedToExtent()) else { return nil }
        let safe = den.applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.002, y: 0.002, z: 0.002, w: 1),
                                                                  "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        let divide = CIFilter.divideBlendMode()        // background ÷ input
        divide.inputImage = safe; divide.backgroundImage = num
        guard let normalised = divide.outputImage else { return plain }
        let trust = den.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 6, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 6, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 6, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        let mix = CIFilter.blendWithMask()
        mix.inputImage = normalised; mix.backgroundImage = plain; mix.maskImage = trust
        return mix.outputImage?.cropped(to: extent)
    }

    /// 0 where the depth matches `focus`, rising to 1 away from it. Only lightly softened: the edge-aware depth
    /// already follows object outlines, and more softening would bring the halo back.
    static func blurMask(_ depth: CIImage, focus: Double, extent: CGRect, short: CGFloat) -> CIImage? {
        let f = CGFloat(focus), dead: CGFloat = 0.08, gain: CGFloat = 4.0
        func shifted(_ sign: CGFloat) -> CIImage? {
            let m = CIFilter.colorMatrix(); m.inputImage = depth
            let v = CIVector(x: sign, y: 0, z: 0, w: 0)
            m.rVector = v; m.gVector = v; m.bVector = v
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            m.biasVector = CIVector(x: -sign * f, y: -sign * f, z: -sign * f, w: 0)
            let c = CIFilter.colorClamp(); c.inputImage = m.outputImage
            c.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1); c.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
            return c.outputImage
        }
        guard let nearer = shifted(1), let farther = shifted(-1) else { return nil }
        let distance = FilmPipeline.add(nearer, onto: farther)            // |depth − focus|
        let m = CIFilter.colorMatrix(); m.inputImage = distance
        let v = CIVector(x: gain, y: 0, z: 0, w: 0)
        m.rVector = v; m.gVector = v; m.bVector = v
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: -dead * gain, y: -dead * gain, z: -dead * gain, w: 0)
        let c = CIFilter.colorClamp(); c.inputImage = m.outputImage
        c.minComponents = CIVector(x: 0, y: 0, z: 0, w: 1); c.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return c.outputImage?.clampedToExtent().applyingGaussianBlur(sigma: short * 0.0015).cropped(to: extent)
    }

    private static func masked(_ image: CIImage, mask: CIImage, radius: CGFloat) -> CIImage? {
        let f = CIFilter.maskedVariableBlur()
        f.inputImage = image.clampedToExtent(); f.mask = mask.clampedToExtent(); f.radius = Float(radius)
        return f.outputImage
    }
}

/// Reading depth out of a captured or imported photo.
enum DepthMap {
    /// The photo's disparity map, normalised to 0 (far) … 1 (near), and where to focus.
    static func extract(from data: Data, context: CIContext) -> (image: CIImage, focus: Double)? {
        guard let disparity = CIImage(data: data, options: [.auxiliaryDisparity: true, .applyOrientationProperty: true]),
              disparity.extent.width > 8 else { return nil }
        let e = disparity.extent, w = Int(e.width), h = Int(e.height)
        var raw = [Float](repeating: 0, count: w * h * 4)
        context.render(disparity, toBitmap: &raw, rowBytes: w * 16, bounds: e, format: .RGBAf, colorSpace: nil)
        var values = (0..<(w * h)).map { raw[$0 * 4] }.filter { $0.isFinite }
        guard values.count > 16 else { return nil }
        values.sort()
        let lo = values[values.count * 2 / 100], hi = values[values.count * 98 / 100]
        guard hi > lo else { return nil }
        let scale = 1 / CGFloat(hi - lo)
        let m = CIFilter.colorMatrix(); m.inputImage = disparity
        let v = CIVector(x: scale, y: 0, z: 0, w: 0)
        m.rVector = v; m.gVector = v; m.bVector = v; m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        m.biasVector = CIVector(x: -CGFloat(lo) * scale, y: -CGFloat(lo) * scale, z: -CGFloat(lo) * scale, w: 0)
        guard let normalised = m.outputImage?
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                        "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            .cropped(to: e) else { return nil }
        let matte = CIImage(data: data, options: [.auxiliaryPortraitEffectsMatte: true, .applyOrientationProperty: true])
        return (normalised, autoFocus(normalised, matte: matte, context: context))
    }

    /// Focus on the person (portrait matte) if there is one, otherwise on the nearest thing near the centre.
    static func autoFocus(_ depth: CIImage, matte: CIImage?, context: CIContext) -> Double {
        let e = depth.extent, w = 48, h = max(8, Int(48 * e.height / e.width))
        func sample(_ image: CIImage) -> [Float] {
            let ie = image.extent
            let small = image.transformed(by: CGAffineTransform(translationX: -ie.minX, y: -ie.minY))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(w) / ie.width, y: CGFloat(h) / ie.height))
            var buf = [Float](repeating: 0, count: w * h * 4)
            context.render(small, toBitmap: &buf, rowBytes: w * 16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: nil)
            return (0..<(w * h)).map { buf[$0 * 4] }
        }
        let d = sample(depth)
        if let matte {
            let m = sample(matte)
            var sum: Float = 0, weight: Float = 0
            for i in 0..<d.count where m[i] > 0.5 { sum += d[i] * m[i]; weight += m[i] }
            if weight > 4 { return Double(sum / weight) }
        }
        var centre: [Float] = []
        for j in (h * 3 / 10)..<(h * 7 / 10) { for i in (w * 3 / 10)..<(w * 7 / 10) { centre.append(d[j * w + i]) } }
        centre.sort()
        return centre.isEmpty ? 0.8 : Double(centre[centre.count * 85 / 100])
    }
}
