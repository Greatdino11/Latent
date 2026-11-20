import AVFoundation
import UIKit

/// A contact sheet: frames laid out as strips of 35mm film (six to a strip, in shooting order) on photo paper,
/// with perforations, frame numbers and edge print — the way a lab hands back a roll.
enum ContactSheet {
    struct Frame {
        let image: CGImage
        let number: Int
        let stock: String
    }

    static let maxFrames = 36

    static func render(_ frames: [Frame], title: String, seed: UInt64) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        let perStrip = 6
        let fw: CGFloat = 720, fh: CGFloat = 480          // one 36 × 24 mm frame
        let mm = fh / 24
        let gap = (2 * mm).rounded(), rebate = (5.5 * mm).rounded()
        let stripW = CGFloat(perStrip) * fw + CGFloat(perStrip + 1) * gap
        let stripH = fh + rebate * 2
        let strips = (frames.count + perStrip - 1) / perStrip
        let margin = (16 * mm).rounded(), spacing = (5 * mm).rounded(), header = (14 * mm).rounded()
        let size = CGSize(width: (stripW + margin * 2).rounded(),
                          height: (margin * 2 + header + CGFloat(strips) * stripH + CGFloat(strips - 1) * spacing).rounded())
        var rng = SeededRandom(seed: seed)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let sheet = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1).setFill()        // photo paper
            c.fill(CGRect(origin: .zero, size: size))
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 4 * mm, weight: .medium),
                .foregroundColor: UIColor(white: 0.25, alpha: 1), .kern: 0.6 * mm,
            ]
            NSAttributedString(string: title, attributes: titleAttrs).draw(at: CGPoint(x: margin, y: margin))

            let edgeFont = UIFont.systemFont(ofSize: 1.25 * mm, weight: .medium, width: .condensed)
            for s in 0..<strips {
                let top = margin + header + CGFloat(s) * (stripH + spacing)
                c.saveGState()
                // Each strip lies slightly crooked on the paper.
                c.translateBy(x: margin + stripW / 2, y: top + stripH / 2)
                c.rotate(by: CGFloat(rng.range(-0.3...0.3)) * .pi / 180)
                c.translateBy(x: -stripW / 2, y: -stripH / 2)

                let strip = CGRect(x: 0, y: 0, width: stripW, height: stripH)
                UIColor(red: 0.075, green: 0.06, blue: 0.05, alpha: 1).setFill()
                c.fill(strip)

                // Perforations along both edges.
                let holeW = 2.79 * mm, holeH = 1.98 * mm, pitch = 4.75 * mm, edge = 2.0 * mm
                var x = pitch * CGFloat(rng.unit()) - pitch
                while x < stripW {
                    for y in [edge, stripH - edge - holeH] {
                        let v = rng.range(0.8...0.92)
                        UIColor(red: v, green: v * 0.98, blue: v * 0.93, alpha: 1).setFill()
                        UIBezierPath(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH), cornerRadius: 0.5 * mm).fill()
                    }
                    x += pitch
                }

                // Frames.
                for i in 0..<perStrip {
                    let index = s * perStrip + i
                    guard index < frames.count else { break }
                    let frame = frames[index]
                    let rect = CGRect(x: gap + CGFloat(i) * (fw + gap), y: rebate, width: fw, height: fh)
                    draw(frame.image, in: rect, context: c, corner: 0.35 * mm)

                    // Edge print in the bottom rebate's outer strip: frame number, and the half-frame mark.
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: edgeFont, .foregroundColor: UIColor(red: 1, green: 0.74, blue: 0.36, alpha: rng.range(0.55...0.75)),
                    ]
                    let stripMid = stripH - edge / 2
                    let num = NSAttributedString(string: "\(frame.number)", attributes: attrs)
                    num.draw(at: CGPoint(x: rect.midX - num.size().width / 2, y: stripMid - num.size().height / 2))
                    let half = NSAttributedString(string: "▸\(frame.number)A", attributes: attrs)
                    half.draw(at: CGPoint(x: rect.maxX - half.size().width / 2, y: stripMid - half.size().height / 2))
                    if i == 0 {
                        let name = NSAttributedString(string: "LATENT \(frame.stock.uppercased())", attributes: attrs)
                        name.draw(at: CGPoint(x: rect.minX + 4 * mm, y: edge / 2 - name.size().height / 2))
                    }
                }
                c.restoreGState()
            }
        }
        return sheet.cgImage
    }

    /// Fits a frame into its 3:2 slot; portrait frames are turned on their side, as they are on the film.
    private static func draw(_ image: CGImage, in rect: CGRect, context c: CGContext, corner: CGFloat) {
        let portrait = image.height > image.width
        c.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: corner).addClip()
        c.translateBy(x: rect.midX, y: rect.midY)
        if portrait { c.rotate(by: -.pi / 2) }
        let box = portrait ? CGSize(width: rect.height, height: rect.width) : rect.size
        let fit = AVMakeRect(aspectRatio: CGSize(width: image.width, height: image.height),
                             insideRect: CGRect(origin: .zero, size: box))
        UIImage(cgImage: image).draw(in: CGRect(x: -fit.width / 2, y: -fit.height / 2, width: fit.width, height: fit.height))
        c.restoreGState()
    }
}
