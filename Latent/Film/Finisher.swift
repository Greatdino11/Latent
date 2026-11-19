import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Finishing (dust, date stamp, print border, 35mm scan border)

enum Finisher {
    static func finish(_ cg: CGImage, stock: FilmStock, options: DevelopOptions) -> CGImage {
        let dust = options.dust == true
        guard options.dateStamp || options.frame != .none || dust else { return cg }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), short = min(w, h)
        let portrait = h > w
        var rng = SeededRandom(seed: options.seed)

        // Insets around the photo, in whole pixels (a fractional canvas leaves an unpainted dark edge).
        var inset = (left: CGFloat(0), right: CGFloat(0), top: CGFloat(0), bottom: CGFloat(0))
        switch options.frame {
        case .none: break
        case .white, .black:
            let border = (short * 0.045).rounded(), footer = (short * 0.09).rounded()
            inset = (border, border, border, border + footer)
        case .film:
            // 35mm: sprocket rebate along the long sides, a thin margin on the short sides.
            let rebate = (short * 0.11).rounded(), side = (short * 0.03).rounded()
            inset = portrait ? (rebate, rebate, side, side) : (side, side, rebate, rebate)
        }
        let size = CGSize(width: w + inset.left + inset.right, height: h + inset.top + inset.bottom)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let paper: UIColor = switch options.frame {
            case .black: UIColor(white: 0.06, alpha: 1)
            case .film: UIColor(red: 0.07, green: 0.055, blue: 0.045, alpha: 1)
            default: UIColor(white: 0.97, alpha: 1)
            }
            paper.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let photo = CGRect(x: inset.left, y: inset.top, width: w, height: h)
            UIImage(cgImage: cg).draw(in: photo)

            if dust { drawDust(ctx.cgContext, in: photo, short: short, rng: &rng) }
            if options.dateStamp { drawDate(options.date, in: photo, short: short) }

            switch options.frame {
            case .white, .black:
                let ink: UIColor = options.frame == .black ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.18, alpha: 1)
                let font = UIFont.monospacedSystemFont(ofSize: short * 0.022, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: short * 0.003]
                let left = NSAttributedString(string: "LATENT", attributes: attrs)
                let right = NSAttributedString(string: stock.displayName.uppercased(), attributes: attrs)
                let y = photo.maxY + (size.height - photo.maxY) / 2 - left.size().height / 2
                left.draw(at: CGPoint(x: photo.minX, y: y))
                right.draw(at: CGPoint(x: photo.maxX - right.size().width, y: y))
            case .film:
                let frameNo = 1 + Int(rng.unit() * 36)
                let first = portrait ? CGRect(x: 0, y: 0, width: inset.left, height: size.height)
                                     : CGRect(x: 0, y: 0, width: size.width, height: inset.top)
                let second = portrait ? CGRect(x: photo.maxX, y: 0, width: inset.right, height: size.height)
                                      : CGRect(x: 0, y: photo.maxY, width: size.width, height: inset.bottom)
                let phase = CGFloat(rng.unit())
                drawRebate(ctx.cgContext, band: first, vertical: portrait, outerAtStart: true, phase: phase,
                           text: "LATENT \(stock.name.uppercased()) \(stock.iso)", number: "\(frameNo)", short: short)
                drawRebate(ctx.cgContext, band: second, vertical: portrait, outerAtStart: false, phase: phase,
                           text: "▸ \(frameNo)A", number: "\(frameNo + 1)", short: short)
            case .none:
                break
            }
        }
        return image.cgImage ?? cg
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

    /// One sprocket band of a 35mm scan: backlit holes near the outer edge, orange edge print near the image.
    /// Drawn horizontally; vertical bands (portrait frames) are the same drawing rotated a quarter turn.
    static func drawRebate(_ c: CGContext, band: CGRect, vertical: Bool, outerAtStart: Bool, phase: CGFloat,
                           text: String, number: String, short: CGFloat) {
        c.saveGState()
        c.translateBy(x: band.midX, y: band.midY)
        if vertical { c.rotate(by: .pi / 2) }
        let length = vertical ? band.height : band.width, depth = vertical ? band.width : band.height
        // Local band: x along the film, y across; `outer` is the side away from the image.
        let outerSign: CGFloat = (outerAtStart != vertical) ? -1 : 1
        let holeW = short * 0.034, holeH = depth * 0.34, pitch = holeW * 1.75
        let holeY = outerSign * depth * 0.18 - holeH / 2
        let hole = UIColor(red: 0.93, green: 0.91, blue: 0.86, alpha: 1)
        hole.setFill()
        var x = -length / 2 + pitch * phase - pitch
        while x < length / 2 {
            UIBezierPath(roundedRect: CGRect(x: x, y: holeY, width: holeW, height: holeH), cornerRadius: holeH * 0.16).fill()
            x += pitch
        }
        let ink = UIColor(red: 1.0, green: 0.58, blue: 0.22, alpha: 0.88)
        let font = UIFont.monospacedSystemFont(ofSize: depth * 0.17, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: depth * 0.02]
        let label = NSAttributedString(string: text, attributes: attrs)
        let num = NSAttributedString(string: number, attributes: attrs)
        let textY = -outerSign * depth * 0.22 - label.size().height / 2
        label.draw(at: CGPoint(x: -length / 2 + length * 0.08, y: textY))
        num.draw(at: CGPoint(x: length / 2 - length * 0.12 - num.size().width, y: textY))
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
