import ImageIO
import UIKit
import UniformTypeIdentifiers

// MARK: - Finishing (date stamp + print frame)

enum Finisher {
    static func finish(_ cg: CGImage, stock: FilmStock, options: DevelopOptions) -> CGImage {
        guard options.dateStamp || options.frame != .none else { return cg }
        let w = CGFloat(cg.width), h = CGFloat(cg.height), short = min(w, h)
        let framed = options.frame != .none
        // Whole pixels: a fractional canvas gets rounded up and its last column/row is never painted (a dark sliver).
        let border = framed ? (short * 0.045).rounded() : 0
        let footer = framed ? (short * 0.09).rounded() : 0
        let size = CGSize(width: w + border * 2, height: h + border * 2 + footer)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let paper: UIColor = options.frame == .black ? UIColor(white: 0.06, alpha: 1) : UIColor(white: 0.97, alpha: 1)
            paper.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let photo = CGRect(x: border, y: border, width: w, height: h)
            UIImage(cgImage: cg).draw(in: photo)

            if options.dateStamp {
                let f = DateFormatter(); f.dateFormat = "''yy MM dd"
                let text = f.string(from: options.date)
                let orange = UIColor(red: 1.0, green: 0.52, blue: 0.16, alpha: 0.92)
                let shadow = NSShadow()
                shadow.shadowColor = orange; shadow.shadowBlurRadius = short * 0.008; shadow.shadowOffset = .zero
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: short * 0.038, weight: .bold),
                    .foregroundColor: orange, .shadow: shadow, .kern: short * 0.004,
                ]
                let str = NSAttributedString(string: text, attributes: attrs)
                let ts = str.size()
                str.draw(at: CGPoint(x: photo.maxX - ts.width - short * 0.06, y: photo.maxY - ts.height - short * 0.05))
            }

            if framed {
                let ink: UIColor = options.frame == .black ? UIColor(white: 0.85, alpha: 1) : UIColor(white: 0.18, alpha: 1)
                let font = UIFont.monospacedSystemFont(ofSize: short * 0.022, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .kern: short * 0.003]
                let left = NSAttributedString(string: "LATENT", attributes: attrs)
                let right = NSAttributedString(string: stock.displayName.uppercased(), attributes: attrs)
                let y = photo.maxY + (border + footer) / 2 - left.size().height / 2
                left.draw(at: CGPoint(x: photo.minX, y: y))
                right.draw(at: CGPoint(x: photo.maxX - right.size().width, y: y))
            }
        }
        return image.cgImage ?? cg
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
