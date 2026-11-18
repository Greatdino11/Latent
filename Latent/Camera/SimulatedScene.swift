import CoreImage
import UIKit

/// A procedurally drawn test scene used when no camera exists (iOS Simulator).
/// It has a bright sun (for halation), skin, foliage, sky, colour swatches and a grey ramp.
enum SimulatedScene {
    static let preview: UIImage = render(CGSize(width: 750, height: 1000))
    static let capture: CIImage = {
        let ui = render(CGSize(width: 3024, height: 4032))
        return CIImage(cgImage: ui.cgImage!)
    }()

    static func render(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true; format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            let c = r.cgContext
            let W = size.width, H = size.height
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

            // Sky
            let sky = CGGradient(colorsSpace: space, colors: [col(0.16, 0.33, 0.66), col(0.45, 0.62, 0.86), col(0.98, 0.76, 0.55)] as CFArray, locations: [0, 0.55, 1])!
            c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: H * 0.56), options: [.drawsAfterEndLocation])

            // Sun with glow
            let sun = CGPoint(x: W * 0.72, y: H * 0.26)
            let glow = CGGradient(colorsSpace: space, colors: [col(1, 0.97, 0.88, 1), col(1, 0.9, 0.7, 0.55), col(1, 0.85, 0.6, 0)] as CFArray, locations: [0, 0.3, 1])!
            c.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: W * 0.3, options: [])
            c.setFillColor(col(1, 1, 1)); c.fillEllipse(in: CGRect(x: sun.x - W * 0.055, y: sun.y - W * 0.055, width: W * 0.11, height: W * 0.11))

            // Clouds
            c.setFillColor(col(1, 1, 1, 0.75))
            for (x, y, w) in [(0.12, 0.14, 0.30), (0.25, 0.12, 0.22), (0.45, 0.36, 0.26), (0.58, 0.38, 0.18)] as [(CGFloat, CGFloat, CGFloat)] {
                c.fillEllipse(in: CGRect(x: W * x, y: H * y, width: W * w, height: W * w * 0.32))
            }

            // Hills and field
            c.setFillColor(col(0.30, 0.42, 0.40))
            c.move(to: CGPoint(x: 0, y: H * 0.56))
            c.addCurve(to: CGPoint(x: W, y: H * 0.52), control1: CGPoint(x: W * 0.3, y: H * 0.46), control2: CGPoint(x: W * 0.6, y: H * 0.6))
            c.addLine(to: CGPoint(x: W, y: H)); c.addLine(to: CGPoint(x: 0, y: H)); c.fillPath()
            let field = CGGradient(colorsSpace: space, colors: [col(0.42, 0.60, 0.25), col(0.22, 0.38, 0.14)] as CFArray, locations: [0, 1])!
            c.saveGState(); c.clip(to: CGRect(x: 0, y: H * 0.6, width: W, height: H * 0.22))
            c.drawLinearGradient(field, start: CGPoint(x: 0, y: H * 0.6), end: CGPoint(x: 0, y: H * 0.82), options: [])
            c.restoreGState()

            // Red house
            c.setFillColor(col(0.74, 0.16, 0.12)); c.fill(CGRect(x: W * 0.06, y: H * 0.52, width: W * 0.26, height: H * 0.12))
            c.setFillColor(col(0.22, 0.12, 0.10))
            c.move(to: CGPoint(x: W * 0.04, y: H * 0.52)); c.addLine(to: CGPoint(x: W * 0.19, y: H * 0.45)); c.addLine(to: CGPoint(x: W * 0.34, y: H * 0.52)); c.fillPath()
            c.setFillColor(col(0.95, 0.93, 0.88)); c.fill(CGRect(x: W * 0.10, y: H * 0.555, width: W * 0.06, height: W * 0.06))
            c.setFillColor(col(0.12, 0.25, 0.45)); c.fill(CGRect(x: W * 0.21, y: H * 0.57, width: W * 0.06, height: H * 0.07))

            // Person
            c.setFillColor(col(0.15, 0.32, 0.58)); c.fill(CGRect(x: W * 0.53, y: H * 0.64, width: W * 0.16, height: H * 0.17))
            c.setFillColor(col(0.86, 0.64, 0.52)); c.fillEllipse(in: CGRect(x: W * 0.545, y: H * 0.555, width: W * 0.13, height: W * 0.15))
            c.setFillColor(col(0.25, 0.16, 0.10)); c.fillEllipse(in: CGRect(x: W * 0.54, y: H * 0.548, width: W * 0.14, height: W * 0.06))

            // Colour swatches
            let sw: [CGColor] = [col(0.85, 0.15, 0.15), col(0.95, 0.55, 0.15), col(0.95, 0.85, 0.2), col(0.25, 0.65, 0.3), col(0.2, 0.7, 0.75), col(0.2, 0.35, 0.8), col(0.7, 0.25, 0.65)]
            let sh = H * 0.07, swW = W / CGFloat(sw.count)
            for (i, s) in sw.enumerated() { c.setFillColor(s); c.fill(CGRect(x: CGFloat(i) * swW, y: H * 0.82, width: swW + 1, height: sh)) }

            // Grey ramp
            let steps = 11, gw = W / CGFloat(steps)
            for i in 0..<steps {
                let v = CGFloat(i) / CGFloat(steps - 1)
                c.setFillColor(col(v, v, v)); c.fill(CGRect(x: CGFloat(i) * gw, y: H * 0.89, width: gw + 1, height: H * 0.11))
            }
        }
    }
}
