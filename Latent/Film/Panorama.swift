import CoreImage
import Foundation

/// Stitches overlapping frames (shot while turning on the spot) into one wide scene, before any film look is
/// applied, so the panorama is developed once as a single frame.
///
/// Each frame is first projected onto a cylinder around the camera: turning the camera then just slides the
/// picture sideways, so neighbours line up with a plain shift, found by correlating their brightness patterns.
enum Panorama {
    static let maxFrames = 5

    enum Failure: LocalizedError {
        case tooFew, noOverlap
        var errorDescription: String? {
            switch self {
            case .tooFew: "A panorama needs at least two shots."
            case .noOverlap: "Couldn't line the shots up. Overlap each one with the last by about a third, and turn on the spot rather than stepping sideways."
            }
        }
    }

    /// `frames` in shooting order. `focal35`: the lens's 35mm-equivalent focal length, for the cylinder (nil skips
    /// it: frames that are already flat crops of one view, as in tests).
    static func stitch(_ frames: [CIImage], focal35: Double?) throws -> CIImage {
        guard frames.count >= 2 else { throw Failure.tooFew }
        let flat = frames.map { $0.transformed(by: CGAffineTransform(translationX: -$0.extent.minX, y: -$0.extent.minY)) }
        let projected: [CIImage]
        if let focal35, focal35 > 0 {
            projected = flat.map { f in
                let e = f.extent
                let fpx = focal35 * hypot(e.width, e.height) / 43.27      // 35mm-equivalent → pixels
                return cylindrical(f, focalPixels: fpx)
            }
        } else {
            projected = flat
        }

        // Offsets of each frame relative to the first.
        var offsets: [CGPoint] = [.zero]
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .cacheIntermediates: false])
        for i in 1..<projected.count {
            let d = try shift(from: projected[i - 1], to: projected[i], context: ctx)
            offsets.append(CGPoint(x: offsets[i - 1].x + d.x, y: offsets[i - 1].y + d.y))
        }

        // Blend: each frame laid over the ones before through a mask that fades out towards its edges, so overlaps
        // cross-fade. Masks are opaque greys and frames opaque, so every pixel stays exactly opaque (adding frames
        // up would push alpha past 1, which prints as black).
        var acc: CIImage?
        for (i, (img, o)) in zip(projected, offsets).enumerated() {
            let t = CGAffineTransform(translationX: o.x, y: o.y)
            let placed = img.transformed(by: t)
            guard i > 0, let current = acc else { acc = placed; continue }
            // Where this shot overlaps the previous one, cut along the line where the two differ least (so a
            // nearby object or a passer-by comes from one shot, not both), with only a narrow blend across it.
            let previous = projected[i - 1].transformed(by: CGAffineTransform(translationX: offsets[i - 1].x, y: offsets[i - 1].y))
            let overlap = previous.extent.intersection(placed.extent).integral
            let base = CIImage(color: .white).cropped(to: placed.extent).composited(over: CIImage(color: .black))
            var mask = base
            if !overlap.isNull, overlap.width > 8,
               let seam = seamMask(previous: previous, next: placed, overlap: overlap, newOnRight: o.x >= offsets[i - 1].x, context: ctx) {
                mask = seam.cropped(to: overlap).composited(over: base)
            }
            acc = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: current, kCIInputMaskImageKey: mask])
        }
        guard let acc else { throw Failure.tooFew }

        // The clean rectangle: inside every frame vertically (and inside the cylinder's curved top and bottom),
        // from the leftmost frame's left edge to the rightmost frame's right edge.
        var x0 = CGFloat.infinity, x1 = -CGFloat.infinity, y0 = -CGFloat.infinity, y1 = CGFloat.infinity
        for (img, o) in zip(projected, offsets) {
            let inner = cleanRect(img).offsetBy(dx: o.x, dy: o.y)
            x0 = min(x0, inner.minX); x1 = max(x1, inner.maxX)
            y0 = max(y0, inner.minY); y1 = min(y1, inner.maxY)
        }
        let crop = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
        guard crop.width > 0, crop.height > projected[0].extent.height * 0.5 else { throw Failure.noOverlap }
        return acc.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
    }

    // MARK: projection

    /// Projects a frame onto a cylinder of radius `focalPixels`, in thin vertical strips (each a small perspective
    /// warp, close enough to the curve). Columns away from the centre move in and shrink vertically.
    static func cylindrical(_ img: CIImage, focalPixels f: Double) -> CIImage {
        let e = img.extent
        let W = Double(e.width), H = Double(e.height), cx = W / 2, cy = H / 2
        let half = f * atan(cx / f)
        func map(_ x: Double) -> (x: Double, k: Double) {
            let u = x - cx
            return (f * atan(u / f) + half, f / (u * u + f * f).squareRoot())
        }
        let n = 32
        var out: CIImage?
        for s in 0..<n {
            let xa = W * Double(s) / Double(n), xb = min(W, W * Double(s + 1) / Double(n) + 2)   // 2 px overlap: no hairline gaps
            let strip = img.cropped(to: CGRect(x: xa, y: 0, width: xb - xa, height: H))
            let (l, kl) = map(xa), (r, kr) = map(xb)
            let warped = strip.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(x: l, y: cy + (H - cy) * kl), "inputTopRight": CIVector(x: r, y: cy + (H - cy) * kr),
                "inputBottomRight": CIVector(x: r, y: cy - cy * kr), "inputBottomLeft": CIVector(x: l, y: cy - cy * kl)])
            out = out.map { warped.applyingFilter("CISourceOverCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? warped
        }
        let width = (2 * half).rounded(.down)
        return (out ?? img).cropped(to: CGRect(x: 0, y: 0, width: width, height: H))
    }

    /// The part of a (possibly cylindrical) frame with picture everywhere: its edges dip inward at the sides.
    static func cleanRect(_ img: CIImage) -> CGRect {
        let e = img.extent
        // Sample the alpha down the outer columns to find where picture starts (cylinder edges curve in).
        var inset: CGFloat = 0
        if let col = alphaColumn(img, x: e.minX + 1) { inset = col }
        return CGRect(x: e.minX, y: e.minY + inset, width: e.width, height: e.height - inset * 2)
    }

    private static func alphaColumn(_ img: CIImage, x: CGFloat) -> CGFloat? {
        let e = img.extent
        let h = Int(e.height)
        guard h > 0 else { return nil }
        var px = [Float](repeating: 0, count: h * 4)
        CIContext().render(img, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: e.minY, width: 1, height: e.height), format: .RGBAf, colorSpace: nil)
        // Rows run top to bottom; find the first fully covered row from the top.
        for r in 0..<h where px[r * 4 + 3] > 0.99 { return CGFloat(r) }
        return nil
    }

    // MARK: seams

    /// A mask over `overlap`: 1 where the new shot should show, 0 where the previous one should. The boundary is
    /// the top-to-bottom path of least difference between the two (dynamic programming on a small copy), softened
    /// by a couple of pixels.
    static func seamMask(previous: CIImage, next: CIImage, overlap: CGRect, newOnRight: Bool, context ctx: CIContext) -> CIImage? {
        let s = min(1, 360 / Double(overlap.width))
        let toOrigin = CGAffineTransform(translationX: -overlap.minX, y: -overlap.minY)
        let a = gray(previous.cropped(to: overlap).transformed(by: toOrigin), scale: s, context: ctx)
        let b = gray(next.cropped(to: overlap).transformed(by: toOrigin), scale: s, context: ctx)
        let w = min(a.w, b.w), h = min(a.h, b.h)
        guard w >= 3, h >= 3 else { return nil }
        var cost = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let va = a.px[y * a.w + x], vb = b.px[y * b.w + x]
                // Difference, a nudge towards the middle of the overlap, and "no picture" counts as very different.
                var d: Float = va.isNaN || vb.isNaN ? 1 : abs(va - vb)
                d += 0.03 * abs(Float(x) - Float(w) / 2) / Float(w)
                if y > 0 {
                    var m = cost[(y - 1) * w + x]
                    if x > 0 { m = min(m, cost[(y - 1) * w + x - 1]) }
                    if x < w - 1 { m = min(m, cost[(y - 1) * w + x + 1]) }
                    d += m
                }
                cost[y * w + x] = d
            }
        }
        // Walk back up from the cheapest end.
        var seam = [Int](repeating: 0, count: h)
        var x = (0..<w).min { cost[(h - 1) * w + $0] < cost[(h - 1) * w + $1] } ?? w / 2
        for y in stride(from: h - 1, through: 0, by: -1) {
            seam[y] = x
            guard y > 0 else { break }
            var best = x
            for c in [x - 1, x, x + 1] where c >= 0 && c < w && cost[(y - 1) * w + c] < cost[(y - 1) * w + best] { best = c }
            x = best
        }
        var px = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v: Float = newOnRight ? (x > seam[y] ? 1 : 0) : (x < seam[y] ? 1 : 0)
                let i = (y * w + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 1
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let small = CIImage(bitmapData: data, bytesPerRow: w * 16, size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        return small.clampedToExtent().applyingGaussianBlur(sigma: 1.2).cropped(to: small.extent)
            .transformed(by: CGAffineTransform(scaleX: overlap.width / CGFloat(w), y: overlap.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: overlap.minX, y: overlap.minY))
            .cropped(to: overlap)
    }

    // MARK: alignment

    /// How far frame `b` sits from frame `a` (in `a`'s pixels): coarse-to-fine search of the shift that best
    /// correlates their brightness over the overlap.
    static func shift(from a: CIImage, to b: CIImage, context ctx: CIContext) throws -> CGPoint {
        var best: (dx: Int, dy: Int)?
        var bestScore = -1.0
        for (level, width) in [64, 256, 1024].enumerated() {
            let s = Double(width) / Double(a.extent.width)
            let ga = gray(a, scale: s, context: ctx), gb = gray(b, scale: s, context: ctx)
            let range: (x: ClosedRange<Int>, y: ClosedRange<Int>)
            if let best {
                let cx = best.dx * 4, cy = best.dy * 4                        // previous level was 4× smaller
                range = ((cx - 5)...(cx + 5), (cy - 5)...(cy + 5))
            } else {
                range = ((-Int(Double(ga.w) * 0.9))...Int(Double(ga.w) * 0.9), (-Int(Double(ga.h) * 0.12))...Int(Double(ga.h) * 0.12))
            }
            var levelBest = (dx: 0, dy: 0), levelScore = -2.0
            for dy in range.y { for dx in range.x {
                guard let c = correlation(ga, gb, dx: dx, dy: dy) else { continue }
                if c > levelScore { levelScore = c; levelBest = (dx, dy) }
            } }
            best = levelBest; bestScore = levelScore
            if level == 0, levelScore < 0.5 { throw Failure.noOverlap }
        }
        guard let best, bestScore > 0.6 else { throw Failure.noOverlap }
        let s = 1024 / Double(a.extent.width)
        return CGPoint(x: Double(best.dx) / s, y: Double(best.dy) / s)
    }

    struct Gray { let w: Int; let h: Int; let px: [Float] }

    static func gray(_ img: CIImage, scale s: Double, context ctx: CIContext) -> Gray {
        let small = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let e = small.extent.integral
        let w = max(1, Int(e.width)), h = max(1, Int(e.height))
        var rgba = [Float](repeating: 0, count: w * h * 4)
        ctx.render(small, toBitmap: &rgba, rowBytes: w * 16, bounds: CGRect(x: e.minX, y: e.minY, width: CGFloat(w), height: CGFloat(h)),
                   format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var px = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            // Brightness where there's picture; NaN marks "no picture" (cylinder corners) so it's left out.
            px[i] = rgba[i * 4 + 3] > 0.99 ? 0.2126 * rgba[i * 4] + 0.7152 * rgba[i * 4 + 1] + 0.0722 * rgba[i * 4 + 2] : .nan
        }
        return Gray(w: w, h: h, px: px)
    }

    /// Normalised cross-correlation of `b` placed at (dx, dy) over `a` (bitmap rows run top to bottom, so +dy in
    /// image space is −dy in rows). nil when the overlap is too small or flat.
    static func correlation(_ a: Gray, _ b: Gray, dx: Int, dy: Int) -> Double? {
        let rowShift = -dy
        let x0 = max(0, dx), x1 = min(a.w, dx + b.w)
        let y0 = max(0, rowShift), y1 = min(a.h, rowShift + b.h)
        guard x1 - x0 >= a.w / 10, y1 - y0 >= a.h / 2 else { return nil }
        // Visit a grid of about 6000 points over the overlap (not every pixel).
        let st = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 6000).squareRoot()))
        var n = 0.0, sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
        a.px.withUnsafeBufferPointer { pa in b.px.withUnsafeBufferPointer { pb in
            for y in stride(from: y0, to: y1, by: st) {
                let ra = y * a.w, rb = (y - rowShift) * b.w - dx
                for x in stride(from: x0, to: x1, by: st) {
                    let va = Double(pa[ra + x]), vb = Double(pb[rb + x])
                    if va.isNaN || vb.isNaN { continue }
                    n += 1; sa += va; sb += vb; saa += va * va; sbb += vb * vb; sab += va * vb
                }
            }
        } }
        guard n > 50 else { return nil }
        let cov = sab / n - (sa / n) * (sb / n)
        let varA = saa / n - (sa / n) * (sa / n), varB = sbb / n - (sb / n) * (sb / n)
        guard varA > 1e-6, varB > 1e-6 else { return nil }
        return cov / (varA * varB).squareRoot()
    }
}
