import CoreImage
import CoreImage.CIFilterBuiltins

/// Depth-based background blur with a few lens characters. `depth` is a normalised grey map (near = 1) already
/// fitted and cropped to the frame; `focus` is the depth that stays sharp.
enum Portrait {
    static func blur(_ img: CIImage, depth: CIImage, lens: PortraitLens, amount: Double, focus: Double,
                     extent: CGRect, short: CGFloat) -> CIImage {
        guard let mask = blurMask(depth, focus: focus, extent: extent, short: short) else { return img }
        let a = CGFloat(min(1, max(0, amount)))
        let base = img.clampedToExtent()
        let blurred: CIImage?
        switch lens {
        case .classic:
            blurred = masked(base, mask: mask, radius: a * short * 0.03)
        case .bubble:
            // Soap-bubble bokeh: bright rims on out-of-focus highlights. Rendered at half size (it's costly).
            let half = base.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
                .cropped(to: CGRect(x: extent.minX / 2 - 64, y: extent.minY / 2 - 64, width: extent.width / 2 + 128, height: extent.height / 2 + 128))
            let b = CIFilter.bokehBlur()
            b.inputImage = half
            b.radius = Float(a * short * 0.014); b.ringAmount = 0.75; b.ringSize = 0.16; b.softness = 0.6
            blurred = b.outputImage?.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        case .swirl:
            // Swirly bokeh: average a few slightly rotated copies, so blur runs around the frame and grows
            // toward the edges, like an old Petzval-style lens.
            guard let soft = masked(base, mask: mask, radius: a * short * 0.018) else { return img }
            let c = CGPoint(x: extent.midX, y: extent.midY)
            let steps = 9, spread = Double(a) * 0.12            // radians end to end
            var sum: CIImage?
            for i in 0..<steps {
                let angle = CGFloat(spread * (Double(i) / Double(steps - 1) - 0.5))
                let turned = soft.transformed(by: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y))
                let part = turned.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1 / CGFloat(steps), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1 / CGFloat(steps), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1 / CGFloat(steps), w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
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

    /// 0 where the depth matches `focus`, rising to 1 away from it, softened so edges don't halo.
    static func blurMask(_ depth: CIImage, focus: Double, extent: CGRect, short: CGFloat) -> CIImage? {
        let f = CGFloat(focus), dead: CGFloat = 0.07, gain: CGFloat = 3.4
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
        return c.outputImage?.clampedToExtent().applyingGaussianBlur(sigma: short * 0.008).cropped(to: extent)
    }

    private static func masked(_ image: CIImage, mask: CIImage, radius: CGFloat) -> CIImage? {
        let f = CIFilter.maskedVariableBlur()
        f.inputImage = image; f.mask = mask.clampedToExtent(); f.radius = Float(radius)
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
