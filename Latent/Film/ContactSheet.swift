import UIKit

/// A contact sheet: the roll's negative strips (six frames each, in shooting order) laid on photo paper and
/// printed through. As on a real contact print, wherever light passed straight through — sprocket holes, the
/// gaps between strips — prints black; the film's clear base prints a slightly lighter brown-black; the edge
/// print and frame numbers, dense on the negative, come out pale. Strips are cut by hand and laid a little
/// crooked, and a red grease pencil marks how each frame was cropped.
enum ContactSheet {
    struct Frame {
        let image: CGImage
        let number: Int
        let stock: String
        /// The frame's own crop inside the full negative (normalised, top-left origin), if it's tighter.
        var mark: CGRect? = nil
    }

    static let maxFrames = 36
    static let perStrip = 6

    // Geometry in millimetres of real 35mm film, drawn at 20 px per mm.
    private static let mm: CGFloat = 20
    private static let frameW: CGFloat = 36, frameH: CGFloat = 24, gap: CGFloat = 2, filmW: CGFloat = 35
    private static let holeW: CGFloat = 2.79, holeH: CGFloat = 1.98, pitch: CGFloat = 4.75, holeInset: CGFloat = 2.0

    static func render(_ frames: [Frame], title: String, seed: UInt64) -> CGImage? {
        guard !frames.isEmpty else { return nil }
        var rng = SeededRandom(seed: seed)
        let strips = (frames.count + perStrip - 1) / perStrip

        let margin: CGFloat = 12, header: CGFloat = 13, pad: CGFloat = 7, spacing: CGFloat = 4.5
        let fullStrip = 6 * frameW + 5 * gap + 2 * 5          // longest strip, with its cut ends
        let exposed = CGRect(x: margin, y: margin + header, width: fullStrip + pad * 2,
                             height: CGFloat(strips) * filmW + CGFloat(strips - 1) * spacing + pad * 2)
        let size = CGSize(width: ((exposed.maxX + margin) * mm).rounded(), height: ((exposed.maxY + margin) * mm).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let sheet = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext
            UIColor(red: 0.955, green: 0.95, blue: 0.935, alpha: 1).setFill()          // paper, masked by the easel
            c.fill(CGRect(origin: .zero, size: size))
            NSAttributedString(string: title, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 3.6 * mm, weight: .medium),
                .foregroundColor: UIColor(white: 0.28, alpha: 1), .kern: 0.5 * mm,
            ]).draw(at: CGPoint(x: margin * mm, y: (margin + 2) * mm))

            c.scaleBy(x: mm, y: mm)                                                       // work in millimetres
            UIColor(red: 0.022, green: 0.02, blue: 0.019, alpha: 1).setFill()            // full exposure
            c.fill(exposed)

            for s in 0..<strips {
                let slice = Array(frames[(s * perStrip)..<min(frames.count, (s + 1) * perStrip)])
                drawStrip(slice, origin: CGPoint(x: exposed.minX + pad, y: exposed.minY + pad + CGFloat(s) * (filmW + spacing)),
                          isLast: s == strips - 1, context: c, rng: &rng)
            }
        }
        return sheet.cgImage
    }

    private static func drawStrip(_ frames: [Frame], origin: CGPoint, isLast: Bool, context c: CGContext, rng: inout SeededRandom) {
        // Hand-cut: a little leader before the first frame, a tail after the last, ends not quite square.
        let lead = CGFloat(rng.range(1.2...4.5))
        let tail = isLast && frames.count < perStrip ? CGFloat(rng.range(5...14)) : CGFloat(rng.range(1.2...4.5))
        let length = lead + CGFloat(frames.count) * frameW + CGFloat(frames.count - 1) * gap + tail
        let skewL = CGFloat(rng.range(-0.5...0.5)), skewR = CGFloat(rng.range(-0.5...0.5))

        c.saveGState()
        c.translateBy(x: origin.x + CGFloat(rng.range(-1.2...1.2)) + length / 2, y: origin.y + CGFloat(rng.range(-0.6...0.6)) + filmW / 2)
        c.rotate(by: CGFloat(rng.range(-0.35...0.35)) * .pi / 180)
        c.translateBy(x: -length / 2, y: -filmW / 2)

        let outline = UIBezierPath()
        outline.move(to: CGPoint(x: skewL, y: 0)); outline.addLine(to: CGPoint(x: length + skewR, y: 0))
        outline.addLine(to: CGPoint(x: length - skewR, y: filmW)); outline.addLine(to: CGPoint(x: -skewL, y: filmW))
        outline.close()
        c.saveGState()
        outline.addClip()

        // Clear base, printed: dark brown-black with gentle density drift along the strip.
        let base = UIColor(red: 0.125, green: 0.105, blue: 0.092, alpha: 1)
        base.setFill(); c.fill(CGRect(x: -2, y: 0, width: length + 4, height: filmW))
        let drift = (0..<4).map { _ in UIColor(white: rng.unit() < 0.5 ? 0 : 1, alpha: CGFloat(rng.range(0...0.05))).cgColor }
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: drift as CFArray, locations: [0, 0.35, 0.7, 1]) {
            c.drawLinearGradient(g, start: .zero, end: CGPoint(x: length, y: 0), options: [])
        }

        // Sprocket holes print black; each is a touch different.
        var x = lead - CGFloat(rng.range(0...Double(pitch)))
        while x > -pitch { x -= pitch }
        while x < length {
            for y in [holeInset, filmW - holeInset - holeH] {
                let j = CGFloat(rng.range(-0.04...0.04))
                UIColor(white: CGFloat(rng.range(0.012...0.03)), alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: x + j, y: y + j, width: holeW, height: holeH),
                             cornerRadius: CGFloat(rng.range(0.42...0.55))).fill()
            }
            x += pitch
        }

        // Frames, edge print and grease pencil.
        let edgeFont = UIFont.systemFont(ofSize: 1.2, weight: .semibold, width: .condensed)
        let pale = UIColor(red: 0.93, green: 0.89, blue: 0.78, alpha: 1)
        let image = (filmW - frameH) / 2
        for (i, frame) in frames.enumerated() {
            let rect = CGRect(x: lead + CGFloat(i) * (frameW + gap), y: image, width: frameW, height: frameH)
            draw(frame, in: rect, context: c, rng: &rng)

            let ink: [NSAttributedString.Key: Any] = [.font: edgeFont, .foregroundColor: pale.withAlphaComponent(CGFloat(rng.range(0.55...0.8)))]
            let band = filmW - holeInset / 2                          // between the holes and the bottom edge
            let num = NSAttributedString(string: "\(frame.number)", attributes: ink)
            num.draw(at: CGPoint(x: rect.midX - num.size().width / 2, y: band - num.size().height / 2))
            let half = NSAttributedString(string: "▸\(frame.number)A", attributes: ink)
            half.draw(at: CGPoint(x: rect.maxX + gap / 2 - half.size().width / 2, y: band - half.size().height / 2))
            drawBarcode(at: CGPoint(x: rect.minX + 4, y: band - 0.45), context: c, color: pale.withAlphaComponent(0.28), rng: &rng)
            if i % 2 == 0 {
                let name = NSAttributedString(string: "LATENT \(frame.stock.uppercased())", attributes: ink)
                name.draw(at: CGPoint(x: rect.minX + 6, y: holeInset / 2 - name.size().height / 2))
            }
        }
        c.restoreGState()
        c.restoreGState()
    }

    /// The frame fills its 36 × 24 slot, as exposures do on film; vertical frames lie on their side.
    private static func draw(_ frame: Frame, in rect: CGRect, context c: CGContext, rng: inout SeededRandom) {
        let image = frame.image
        let portrait = image.height > image.width
        c.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 0.3).addClip()
        c.translateBy(x: rect.midX, y: rect.midY)
        if portrait { c.rotate(by: -.pi / 2) }
        let box = portrait ? CGSize(width: rect.height, height: rect.width) : rect.size
        let k = max(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let w = CGFloat(image.width) * k, h = CGFloat(image.height) * k
        let drawn = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        UIImage(cgImage: image).draw(in: drawn)
        if let m = frame.mark {
            let target = CGRect(x: drawn.minX + m.minX * w, y: drawn.minY + m.minY * h, width: m.width * w, height: m.height * h)
            greasePencil(target, context: c, rng: &rng)
        }
        c.restoreGState()
    }

    /// A hand-drawn crop box in red china marker: wobbly sides that overshoot the corners, waxy and uneven.
    private static func greasePencil(_ r: CGRect, context c: CGContext, rng: inout SeededRandom) {
        let inset = r.insetBy(dx: 0.6, dy: 0.6)
        let corners = [CGPoint(x: inset.minX, y: inset.minY), CGPoint(x: inset.maxX, y: inset.minY),
                       CGPoint(x: inset.maxX, y: inset.maxY), CGPoint(x: inset.minX, y: inset.maxY)]
        c.setLineCap(.round); c.setLineJoin(.round)
        for pass in 0..<2 {
            UIColor(red: 0.86, green: 0.12, blue: 0.1, alpha: pass == 0 ? 0.85 : 0.35).setStroke()
            c.setLineWidth(pass == 0 ? 0.55 : 0.8)
            for side in 0..<4 {
                let a = corners[side], b = corners[(side + 1) % 4]
                let dx = b.x - a.x, dy = b.y - a.y, len = max(hypot(dx, dy), 0.001)
                let ux = dx / len, uy = dy / len
                let over0 = CGFloat(rng.range(0.3...1.6)), over1 = CGFloat(rng.range(0.3...1.6))
                let path = UIBezierPath()
                let steps = 6
                for k in 0...steps {
                    let t = CGFloat(k) / CGFloat(steps)
                    let along = -over0 + t * (len + over0 + over1)
                    let wobble = CGFloat(rng.range(-0.12...0.12))
                    let p = CGPoint(x: a.x + ux * along - uy * wobble, y: a.y + uy * along + ux * wobble)
                    k == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                c.addPath(path.cgPath); c.strokePath()
            }
        }
    }

    /// A short run of DX-style bars beside the frame number.
    private static func drawBarcode(at p: CGPoint, context c: CGContext, color: UIColor, rng: inout SeededRandom) {
        color.setFill()
        var x = p.x
        for _ in 0..<14 {
            let w = CGFloat(rng.unit() < 0.5 ? 0.18 : 0.36)
            if rng.unit() < 0.6 { c.fill(CGRect(x: x, y: p.y + 0.1, width: w, height: 0.7)) }
            x += w + 0.18
        }
    }
}
