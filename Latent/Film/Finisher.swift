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

    /// A full-border 35mm scan, built to real film dimensions (the frame's short side = 24 mm): 5.5 mm rebates
    /// with Kodak-standard perforations (2.79 × 1.98 mm, 4.75 mm pitch, 2 mm from the film edge), edge print in
    /// the outer strip of one rebate, a dark film base with gentle unevenness, a soft rounded gate edge, and
    /// scanner softness and grain over the whole border.
    static func filmScan(_ cg: CGImage, stock: FilmStock, rng: inout SeededRandom, context: CIContext) -> CGImage {
        let source = CIImage(cgImage: cg)
        let portrait = cg.height > cg.width
        // Lay the film horizontally; a portrait frame is rotated in, and the finished scan rotated back.
        var photo = portrait ? source.oriented(.left) : source
        photo = photo.transformed(by: CGAffineTransform(translationX: -photo.extent.minX, y: -photo.extent.minY))
        let w = photo.extent.width, h = photo.extent.height
        let mm = h / 24
        let rebate = (5.5 * mm).rounded(), holder = (0.6 * mm).rounded(), gap = (2.2 * mm).rounded()
        let size = CGSize(width: w + gap * 2, height: h + (rebate + holder) * 2)
        let window = CGRect(x: gap, y: holder + rebate, width: w, height: h)   // same rect in UIKit and CI (symmetric)

        let phase = CGFloat(rng.unit()), frameNo = 1 + Int(rng.unit() * 35)
        let tilt = (CGFloat(rng.unit()), CGFloat(rng.unit()))
        let layer = renderer(size).image { ctx in
            let c = ctx.cgContext
            // Scanner film holder, then the film base: near-black with a warm cast and slight unevenness.
            UIColor(white: 0.015, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
            let film = CGRect(x: 0, y: holder, width: size.width, height: size.height - holder * 2)
            let base = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
                UIColor(red: 0.095, green: 0.075, blue: 0.062, alpha: 1).cgColor,
                UIColor(red: 0.055, green: 0.044, blue: 0.038, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            c.saveGState(); c.clip(to: film)
            c.drawLinearGradient(base, start: CGPoint(x: size.width * tilt.0, y: 0), end: CGPoint(x: size.width * tilt.1, y: size.height),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            c.restoreGState()

            // Perforations: light straight through the film, so near-white and slightly warm.
            let holeW = 2.79 * mm, holeH = 1.98 * mm, pitch = 4.75 * mm, edge = 2.0 * mm
            let rows = [holder + edge, size.height - holder - edge - holeH]
            UIColor(red: 0.88, green: 0.86, blue: 0.81, alpha: 1).setFill()
            var x = pitch * phase - pitch
            while x < size.width {
                for y in rows { UIBezierPath(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH), cornerRadius: 0.5 * mm).fill() }
                x += pitch
            }

            // Edge print in the outer strip of the bottom rebate (between the film edge and the perforations).
            let font = UIFont.systemFont(ofSize: 1.0 * mm, weight: .medium, width: .condensed)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: UIColor(red: 1.0, green: 0.74, blue: 0.36, alpha: 0.68), .kern: 0.14 * mm,
            ]
            let stripMid = size.height - holder - edge / 2
            func print(_ text: String, at x: CGFloat) {
                let s = NSAttributedString(string: text, attributes: attrs)
                s.draw(at: CGPoint(x: x, y: stripMid - s.size().height / 2))
            }
            print("LATENT \(stock.name.uppercased()) \(stock.iso)", at: gap + w * 0.05)
            print("\(frameNo)", at: gap + w * 0.47)
            print("▸\(frameNo)A", at: gap + w * 0.86)
        }
        guard let layerCG = layer.cgImage else { return cg }

        // Scanner softness and grain on the border, then the frame through a soft, slightly rounded gate.
        let full = CGRect(origin: .zero, size: size)
        var border = CIImage(cgImage: layerCG).clampedToExtent().applyingGaussianBlur(sigma: 0.06 * mm).cropped(to: full)
        border = FilmPipeline.grain(on: border, stock: stock.with(\.grain, max(0.5, stock.grain)).with(\.grainSize, 1),
                                    user: 1, extent: full, short: h)
        let mask = renderer(size).image { ctx in
            UIColor.black.setFill(); ctx.fill(full)
            UIColor.white.setFill(); UIBezierPath(roundedRect: window, cornerRadius: 0.35 * mm).fill()
        }
        guard let maskCG = mask.cgImage else { return cg }
        let soft = CIImage(cgImage: maskCG).clampedToExtent().applyingGaussianBlur(sigma: 0.05 * mm).cropped(to: full)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = photo.transformed(by: CGAffineTransform(translationX: window.minX, y: window.minY))
        blend.backgroundImage = border
        blend.maskImage = soft
        guard var scan = blend.outputImage?.cropped(to: full) else { return cg }
        if portrait { scan = scan.oriented(.right) }
        scan = scan.transformed(by: CGAffineTransform(translationX: -scan.extent.minX, y: -scan.extent.minY))
        return context.createCGImage(scan, from: scan.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? cg
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
        props[kCGImageDestinationLossyCompressionQuality as String] = 0.92
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
