import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Finishing (dust, date stamp, print border, 35mm scan)

enum Finisher {
    static func finish(_ cg: CGImage, stock: FilmStock, options: DevelopOptions, context: CIContext? = nil) -> CGImage {
        let dust = options.dust == true
        guard options.dateStamp || options.frame != .none || dust else { return cg }
        var rng = SeededRandom(seed: options.seed)
        var photo = cg
        if dust || options.dateStamp { photo = decorate(cg, dust: dust, date: options.dateStamp ? options.date : nil, rng: &rng) }
        switch options.frame {
        case .none: return photo
        case .white, .black: return printBorder(photo, stock: stock, black: options.frame == .black)
        case .film: return filmScan(photo, stock: stock, rng: &rng, context: context ?? CIContext(options: [.cacheIntermediates: false]))
        }
    }

    private static func renderer(_ size: CGSize) -> UIGraphicsImageRenderer {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format)
    }

    /// Dust and the date stamp, drawn on the photo itself.
    private static func decorate(_ cg: CGImage, dust: Bool, date: Date?, rng: inout SeededRandom) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height), short = min(w, h)
        let photo = CGRect(x: 0, y: 0, width: w, height: h)
        var local = rng
        let image = renderer(photo.size).image { ctx in
            UIImage(cgImage: cg).draw(in: photo)
            if dust { drawDust(ctx.cgContext, in: photo, short: short, rng: &local) }
            if let date { drawDate(date, in: photo, short: short) }
        }
        rng = local
        return image.cgImage ?? cg
    }

    /// White or black print border with a caption.
    private static func printBorder(_ cg: CGImage, stock: FilmStock, black: Bool) -> CGImage {
        let w = CGFloat(cg.width), h = CGFloat(cg.height), short = min(w, h)
        // Whole pixels: a fractional canvas gets rounded up and its last column/row is never painted (a dark sliver).
        let border = (short * 0.045).rounded(), footer = (short * 0.09).rounded()
        let size = CGSize(width: w + border * 2, height: h + border * 2 + footer)
        let image = renderer(size).image { ctx in
            (black ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.97, alpha: 1)).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let photo = CGRect(x: border, y: border, width: w, height: h)
            UIImage(cgImage: cg).draw(in: photo)
            let ink: UIColor = black ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.18, alpha: 1)
            let font = UIFont.monospacedSystemFont(ofSize: short * 0.022, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: short * 0.003]
            let left = NSAttributedString(string: "LATENT", attributes: attrs)
            let right = NSAttributedString(string: stock.displayName.uppercased(), attributes: attrs)
            let y = photo.maxY + (size.height - photo.maxY) / 2 - left.size().height / 2
            left.draw(at: CGPoint(x: photo.minX, y: y))
            right.draw(at: CGPoint(x: photo.maxX - right.size().width, y: y))
        }
        return image.cgImage ?? cg
    }

    /// A full-border 35mm scan, built to real film dimensions (the frame's short side = 24 mm) and then roughed up
    /// the way real scans are: slivers of the neighbouring frames, perforations that vary slightly in place and
    /// brightness with scanner-lens fringing and glow, blotchy film-base density, hairline scratches and dust on the
    /// base, edge print and DX code that fade unevenly, a slightly wavy gate edge, and the strip sitting a fraction
    /// of a degree crooked in the holder. Fixed per frame by `rng`, so re-developing reproduces it.
    static func filmScan(_ cg: CGImage, stock: FilmStock, rng: inout SeededRandom, context: CIContext) -> CGImage {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let source = CIImage(cgImage: cg)
        let portrait = cg.height > cg.width
        // Lay the film horizontally; a portrait frame is rotated in, and the finished scan rotated back.
        var photo = portrait ? source.oriented(.left) : source
        photo = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX, y: -photo.extent.minY))
        guard let flat = context.createCGImage(photo, from: photo.extent, format: .RGBA8, colorSpace: sRGB) else { return cg }
        let w = photo.extent.width, h = photo.extent.height, mm = h / 24
        let rebate = (5.5 * mm).rounded(), holder = (1.0 * mm).rounded()
        let frameGap = (1.7 * mm).rounded(), sliver = (2.0 * mm).rounded(), ends = frameGap + sliver
        let size = CGSize(width: w + ends * 2, height: h + (rebate + holder) * 2)
        let full = CGRect(origin: .zero, size: size)
        let window = CGRect(x: ends, y: holder + rebate, width: w, height: h)   // same rect in UIKit and CI (symmetric)

        var r = rng
        let phase = CGFloat(r.unit()), frameNo = 1 + Int(r.unit() * 35)
        let tilt = (CGFloat(r.unit()), CGFloat(r.unit()))
        let layer = renderer(size).image { ctx in
            let c = ctx.cgContext
            // Scanner film holder, then the film base: near-black with a warm cast and slight unevenness.
            UIColor(white: 0.012, alpha: 1).setFill(); c.fill(full)
            let film = CGRect(x: 0, y: holder, width: size.width, height: size.height - holder * 2)
            let base = CGGradient(colorsSpace: sRGB, colors: [
                UIColor(red: 0.10, green: 0.078, blue: 0.064, alpha: 1).cgColor,
                UIColor(red: 0.052, green: 0.042, blue: 0.037, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.saveGState(); c.clip(to: film)
            c.drawLinearGradient(base, start: CGPoint(x: size.width * tilt.0, y: 0), end: CGPoint(x: size.width * tilt.1, y: size.height),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()

            // Slivers of the neighbouring frames (mirrored copies, exposed a little differently).
            for (frameRect, visible) in [
                (CGRect(x: sliver - w, y: window.minY, width: w, height: h), CGRect(x: 0, y: window.minY, width: sliver, height: h)),
                (CGRect(x: size.width - sliver, y: window.minY, width: w, height: h), CGRect(x: size.width - sliver, y: window.minY, width: sliver, height: h)),
            ] {
                c.saveGState()
                c.clip(to: visible)
                UIBezierPath(roundedRect: frameRect, cornerRadius: 0.35 * mm).addClip()
                c.translateBy(x: frameRect.midX, y: frameRect.midY); c.scaleBy(x: -1, y: 1); c.translateBy(x: -frameRect.midX, y: -frameRect.midY)
                UIImage(cgImage: flat).draw(in: frameRect)
                UIColor(white: 0, alpha: r.range(0.12...0.45)).setFill(); c.fill(frameRect)
                c.restoreGState()
            }

            // Perforations: light straight through the film. Each one sits and glows a little differently, with
            // the scanner lens fringing red/cyan toward the strip's ends.
            let holeW = 2.79 * mm, holeH = 1.98 * mm, pitch = 4.75 * mm, edge = 2.0 * mm, corner = 0.5 * mm
            let rows = [holder + edge, size.height - holder - edge - holeH]
            var x = pitch * phase - pitch
            while x < size.width {
                for y in rows {
                    let rect = CGRect(x: x + CGFloat(r.range(-0.05...0.05)) * mm, y: y + CGFloat(r.range(-0.04...0.04)) * mm,
                                      width: holeW, height: holeH)
                    let fringe = (rect.midX - size.width / 2) / (size.width / 2) * 0.09 * mm
                    UIColor(red: 0.95, green: 0.32, blue: 0.22, alpha: 0.45).setFill()
                    UIBezierPath(roundedRect: rect.offsetBy(dx: fringe, dy: 0), cornerRadius: corner).fill()
                    UIColor(red: 0.22, green: 0.62, blue: 0.95, alpha: 0.45).setFill()
                    UIBezierPath(roundedRect: rect.offsetBy(dx: -fringe, dy: 0), cornerRadius: corner).fill()
                    let v = r.range(0.78...0.93), warm = r.range(-0.015...0.035)
                    UIColor(red: v + warm, green: v, blue: v - warm - 0.03, alpha: 1).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: corner).fill()
                    if r.unit() < 0.12 {   // a fleck of dust caught in the hole
                        let d = CGFloat(r.range(0.06...0.18)) * mm
                        UIColor(white: 0.25, alpha: 0.6).setFill()
                        c.fillEllipse(in: CGRect(x: rect.minX + rect.width * CGFloat(r.unit()), y: rect.minY + rect.height * CGFloat(r.unit()), width: d, height: d * 0.7))
                    }
                }
                x += pitch
            }

            // Edge print in the outer strip of the bottom rebate, each character fading a little differently.
            let font = UIFont.systemFont(ofSize: 1.0 * mm, weight: .medium, width: .condensed)
            let stripMid = size.height - holder - edge / 2
            func edgePrint(_ text: String, at x0: CGFloat) {
                var x = x0
                for ch in text {
                    let glyph = NSAttributedString(string: String(ch), attributes: [
                        .font: font, .foregroundColor: UIColor(red: 1.0, green: 0.74, blue: 0.36, alpha: r.range(0.42...0.72))])
                    let sz = glyph.size()
                    glyph.draw(at: CGPoint(x: x, y: stripMid - sz.height / 2 + CGFloat(r.range(-0.03...0.03)) * mm))
                    x += sz.width + 0.14 * mm
                }
            }
            edgePrint("LATENT \(stock.name.uppercased()) \(stock.iso)", at: ends + w * CGFloat(r.range(0.03...0.08)))
            edgePrint("\(frameNo)", at: ends + w * CGFloat(r.range(0.44...0.50)))
            edgePrint("▸\(frameNo)A", at: ends + w * CGFloat(r.range(0.83...0.88)))

            // DX code in the top rebate's outer strip.
            var bx = ends + w * CGFloat(r.range(0.15...0.45))
            for _ in 0..<22 {
                let bw = (r.unit() < 0.5 ? 0.17 : 0.34) * mm
                if r.unit() < 0.62 {
                    UIColor(red: 1.0, green: 0.72, blue: 0.34, alpha: r.range(0.3...0.55)).setFill()
                    c.fill(CGRect(x: bx, y: holder + edge * 0.25, width: bw, height: edge * 0.5))
                }
                bx += bw + 0.17 * mm
            }

            // Hairline scratches along the film and dust on the base.
            c.setLineCap(.round)
            for _ in 0..<(1 + Int(r.unit() * 3)) {
                let y = film.minY + film.height * CGFloat(r.unit())
                let x0 = size.width * CGFloat(r.range(0...0.5)), x1 = x0 + size.width * CGFloat(r.range(0.25...0.7))
                c.setStrokeColor(UIColor(white: 1, alpha: r.range(0.05...0.13)).cgColor)
                c.setLineWidth(CGFloat(r.range(0.02...0.05)) * mm)
                c.move(to: CGPoint(x: x0, y: y)); c.addLine(to: CGPoint(x: x1, y: y + CGFloat(r.range(-0.2...0.2)) * mm)); c.strokePath()
            }
            for _ in 0..<(10 + Int(r.unit() * 16)) {
                let p = CGPoint(x: size.width * CGFloat(r.unit()), y: film.minY + film.height * CGFloat(r.unit()))
                guard !window.contains(p) else { continue }
                let d = CGFloat(0.04 + pow(r.unit(), 3) * 0.2) * mm
                UIColor(white: 1, alpha: r.range(0.2...0.6)).setFill()
                c.fillEllipse(in: CGRect(x: p.x, y: p.y, width: d, height: d * 0.8))
            }
        }
        guard let layerCG = layer.cgImage else { rng = r; return cg }

        // Scanner light: perforations bloom into the base, the base density is blotchy, and everything is a touch soft.
        var border = CIImage(cgImage: layerCG)
        let glow = border.clampedToExtent().applyingGaussianBlur(sigma: 0.55 * mm).cropped(to: full)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.22, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.2, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.17, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        border = FilmPipeline.add(glow, onto: border)
        if let blotch = lowFrequency(size: size, cells: (28, 10), amplitude: 0.22, rng: &r) {
            border = border.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: blotch]).cropped(to: full)
        }
        border = border.clampedToExtent().applyingGaussianBlur(sigma: 0.07 * mm).cropped(to: full)
        border = FilmPipeline.grain(on: border, stock: stock.with(\.grain, max(0.55, stock.grain)).with(\.grainSize, 1),
                                    user: 1, extent: full, short: h)

        // The frame through a soft, slightly rounded and slightly wavy gate.
        let mask = renderer(size).image { ctx in
            UIColor.black.setFill(); ctx.fill(full)
            UIColor.white.setFill(); UIBezierPath(roundedRect: window, cornerRadius: 0.35 * mm).fill()
        }
        guard let maskCG = mask.cgImage else { rng = r; return cg }
        var gate = CIImage(cgImage: maskCG).clampedToExtent()
        if let wobble = lowFrequency(size: size, cells: (120, 40), amplitude: 0.5, rng: &r) {
            gate = gate.applyingFilter("CIDisplacementDistortion", parameters: [
                "inputDisplacementImage": wobble.clampedToExtent(), kCIInputScaleKey: 0.22 * mm])
                .transformed(by: CGAffineTransform(translationX: -0.11 * mm, y: -0.11 * mm))
        }
        let soft = gate.applyingGaussianBlur(sigma: 0.05 * mm).cropped(to: full)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = photo.transformed(by: CGAffineTransform(translationX: window.minX, y: window.minY))
        blend.backgroundImage = border
        blend.maskImage = soft
        guard var scan = blend.outputImage?.cropped(to: full) else { rng = r; return cg }

        // The strip sits a fraction of a degree crooked in the holder.
        let angle = CGFloat(r.range(-0.45...0.45)) * .pi / 180
        let mid = CGPoint(x: full.midX, y: full.midY)
        scan = scan.transformed(by: CGAffineTransform(translationX: mid.x, y: mid.y).rotated(by: angle).translatedBy(x: -mid.x, y: -mid.y))
            .composited(over: CIImage(color: CIColor(red: 0.012, green: 0.012, blue: 0.012)).cropped(to: full))
            .cropped(to: full)
        rng = r
        if portrait { scan = scan.oriented(.right) }
        scan = scan.transformed(by: CGAffineTransform(translationX: -scan.extent.minX, y: -scan.extent.minY))
        return context.createCGImage(scan, from: scan.extent, format: .RGBA8, colorSpace: sRGB) ?? cg
    }

    /// Smooth random variation across `size`: a coarse grid of random values, upscaled and blurred, mapped to
    /// 1 ± amplitude (for multiplying) — or, with amplitude 0.5, to 0…1 (for displacement).
    private static func lowFrequency(size: CGSize, cells: (Int, Int), amplitude: Double, rng: inout SeededRandom) -> CIImage? {
        let (cw, ch) = cells
        var bytes = [UInt8](repeating: 255, count: cw * ch * 4)
        for i in 0..<(cw * ch) {
            bytes[i * 4] = UInt8(r: rng.unit()); bytes[i * 4 + 1] = UInt8(r: rng.unit()); bytes[i * 4 + 2] = UInt8(r: rng.unit())
        }
        let small = CIImage(bitmapData: Data(bytes), bytesPerRow: cw * 4, size: CGSize(width: cw, height: ch), format: .RGBA8, colorSpace: nil)
        let sx = size.width / CGFloat(cw), sy = size.height / CGFloat(ch)
        let smooth = small.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .applyingGaussianBlur(sigma: min(sx, sy) * 0.7)
            .cropped(to: CGRect(origin: .zero, size: size))
        let a = CGFloat(amplitude * 2)
        let mono = amplitude != 0.5
        return smooth.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": mono ? CIVector(x: a, y: 0, z: 0, w: 0) : CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": mono ? CIVector(x: a, y: 0, z: 0, w: 0) : CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": mono ? CIVector(x: 1 - a / 2, y: 1 - a / 2, z: 1 - a / 2, w: 0) : CIVector(x: 0, y: 0, z: 0, w: 0)])
    }

    private static func drawDate(_ date: Date, in photo: CGRect, short: CGFloat) {
        let f = DateFormatter(); f.dateFormat = "''yy MM dd"
        let orange = UIColor(red: 1.0, green: 0.52, blue: 0.16, alpha: 0.92)
        let shadow = NSShadow()
        shadow.shadowColor = orange; shadow.shadowBlurRadius = short * 0.008; shadow.shadowOffset = .zero
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: short * 0.038, weight: .bold),
            .foregroundColor: orange, .shadow: shadow, .kern: short * 0.004,
        ]
        let str = NSAttributedString(string: f.string(from: date), attributes: attrs)
        let ts = str.size()
        str.draw(at: CGPoint(x: photo.maxX - ts.width - short * 0.06, y: photo.maxY - ts.height - short * 0.05))
    }

    /// Specks of dust (mostly bright, like dust on a scanned negative), a few hairs and sometimes a faint scratch.
    static func drawDust(_ c: CGContext, in photo: CGRect, short: CGFloat, rng: inout SeededRandom) {
        let unit = short / 1500
        c.saveGState(); c.clip(to: photo)
        for _ in 0..<(18 + Int(rng.unit() * 22)) {
            let p = CGPoint(x: photo.minX + photo.width * rng.unit(), y: photo.minY + photo.height * rng.unit())
            let r = unit * CGFloat(0.5 + pow(rng.unit(), 3) * 2.8)
            let bright = rng.unit() < 0.8
            c.setFillColor(UIColor(white: bright ? 1 : 0.05, alpha: bright ? rng.range(0.3...0.8) : rng.range(0.25...0.55)).cgColor)
            c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r * 0.8, width: r * 2, height: r * 1.6))
        }
        c.setLineCap(.round)
        for _ in 0..<(1 + Int(rng.unit() * 3)) {
            let a = CGPoint(x: photo.minX + photo.width * rng.unit(), y: photo.minY + photo.height * rng.unit())
            let len = short * CGFloat(rng.range(0.02...0.07)), angle = rng.range(0...(2 * .pi))
            let b = CGPoint(x: a.x + len * CGFloat(cos(angle)), y: a.y + len * CGFloat(sin(angle)))
            let mid = CGPoint(x: (a.x + b.x) / 2 + len * CGFloat(rng.range(-0.4...0.4)), y: (a.y + b.y) / 2 + len * CGFloat(rng.range(-0.4...0.4)))
            c.setStrokeColor(UIColor(white: 1, alpha: rng.range(0.35...0.6)).cgColor)
            c.setLineWidth(unit * 0.7)
            c.move(to: a); c.addQuadCurve(to: b, control: mid); c.strokePath()
        }
        if rng.unit() < 0.35 {
            let x = photo.minX + photo.width * CGFloat(rng.range(0.1...0.9))
            c.setStrokeColor(UIColor(white: 1, alpha: 0.16).cgColor)
            c.setLineWidth(unit * 0.6)
            c.move(to: CGPoint(x: x, y: photo.minY + photo.height * CGFloat(rng.range(0...0.3))))
            c.addLine(to: CGPoint(x: x + unit * CGFloat(rng.range(-6...6)), y: photo.maxY - photo.height * CGFloat(rng.range(0...0.3))))
            c.strokePath()
        }
        c.restoreGState()
    }
}

// MARK: - Encoding

enum JPEGEncoder {
    /// Writes a JPEG carrying the capture's EXIF/GPS (only the metadata dictionaries; sizes and orientation are reset).
    static func encode(_ cg: CGImage, metadata: [String: Any]) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw DarkroomError.encode
        }
        var props: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = metadata[key as String] { props[key as String] = v }
        }
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "Latent"
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
            props[kCGImagePropertyExifDictionary as String] = exif
        }
        props[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DarkroomError.encode }
        return data as Data
    }

    /// The metadata dictionaries of an encoded image (EXIF, GPS…).
    static func metadata(of data: Data) -> [String: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return props
    }

    /// The metadata of an existing developed frame, for re-developing it.
    static func metadata(of url: URL) -> [String: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        return props
    }
}

private extension UInt8 {
    init(r: Double) { self = UInt8(Swift.max(0, Swift.min(255, (r * 255).rounded()))) }
}
