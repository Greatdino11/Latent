import AVFoundation
import CoreImage
import Vision

/// Exposures longer than the sensor allows in one go (about 1 s on iPhone), made by stacking a continuous run of
/// video frames — the way Night mode and long-exposure apps do it.
enum LongExposure {
    /// The shutter speeds offered, in seconds; 0 means automatic.
    static let choices: [Double] = [0, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 15, 30]

    static func label(_ s: Double) -> String {
        if s <= 0 { return "AUTO" }
        if s < 1 { return "1/\(Int((1 / s).rounded()))" }
        return "\(Int(s))\""
    }

    /// Combines the stack. The mean is a true long exposure (moving things blur, water smooths); with `trails`,
    /// wherever a pixel was ever bright (a passing headlight) it keeps that brightest moment, so moving lights draw
    /// solid lines instead of fading into the average.
    static func blend(sum: CIImage, max: CIImage, count: Int, trails: Bool) -> CIImage {
        // Aligned frames don't all cover the edges, so each pixel is divided by how many frames reached it: the sum's
        // alpha counts them (every frame adds 1 where it landed, 0 where it didn't).
        let mean = sum.applyingFilter("CIUnpremultiply").settingAlphaOne(in: sum.extent)
        guard trails else { return mean }
        // Weight: 0 below 0.3 luminance, 1 above 0.75 (a ramp on the brightest moment).
        let a = 1 / 0.45, b = -0.3 / 0.45
        let luma = CIVector(x: 0.2126 * a, y: 0.7152 * a, z: 0.0722 * a, w: 0)
        let weight = max.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0)])
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                         "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
        return max.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: mean, kCIInputMaskImageKey: weight])
            .cropped(to: sum.extent)
    }
}

/// Lines each frame of a handheld long exposure up with the first one, so the shake of a hand cancels out and only
/// what really moved (water, people, car lights) blurs — the way handheld long-exposure apps such as ReeHeld work.
/// Registration runs on a small greyscale copy and the shift it finds is scaled back up. Only shifts are corrected:
/// over a few seconds a hand mostly drifts and jitters, and Vision's shift estimate is far steadier than its full
/// perspective one on real scenes.
final class FrameAligner {
    /// Width of the copy registration runs on: small enough to keep up with the frame rate, big enough that its
    /// whole-pixel steps are about 2 full-size pixels.
    private let workWidth: CGFloat
    private var reference: CGImage?
    private(set) var last = CGAffineTransform.identity
    private(set) var failures = 0
    private let ctx = CIContext(options: [.cacheIntermediates: false])

    init(workWidth: CGFloat = 768) { self.workWidth = workWidth }

    /// The frame moved onto the first frame's position. Clear where the moved frame doesn't reach.
    func align(_ frame: CIImage) -> CIImage {
        let e = frame.extent
        let s = min(1, workWidth / e.width)
        // Rendered to a whole-pixel greyscale bitmap (Vision rejects a fractional region of a CIImage).
        let box = CGRect(x: 0, y: 0, width: (e.width * s).rounded(.down), height: (e.height * s).rounded(.down))
        let small = frame.transformed(by: CGAffineTransform(scaleX: s, y: s).translatedBy(x: -e.minX, y: -e.minY))
            .applyingFilter("CIPhotoEffectMono")
        guard let bitmap = ctx.createCGImage(small, from: box) else { failures += 1; return Self.shift(frame, by: last) }
        guard let reference else { self.reference = bitmap; return frame }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: bitmap)
        if (try? VNImageRequestHandler(cgImage: reference).perform([request])) != nil,
           let t = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform,
           abs(t.tx) < 0.12 * box.width, abs(t.ty) < 0.12 * box.height {
            last = CGAffineTransform(translationX: t.tx / s, y: t.ty / s)
        } else {
            failures += 1                                  // a blank or blurred frame: assume it sits like the last
        }
        return Self.shift(frame, by: last)
    }

    static func shift(_ frame: CIImage, by t: CGAffineTransform) -> CIImage {
        frame.transformed(by: t).cropped(to: frame.extent)
    }
}

/// Collects video frames for a set time, keeping a running sum and per-pixel maximum in half-float buffers.
final class FrameStacker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let seconds: Double
    private let onProgress: (Double) -> Void
    private let onDone: (Result<(sum: CIImage, max: CIImage, count: Int), Error>) -> Void
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var ctx = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
    /// Frames before this time were exposed with the old settings.
    var notBefore: CMTime = .invalid
    private var first: CMTime?
    private var sum: CIImage?, peak: CIImage?
    private var buffers: [CVPixelBuffer] = []
    private var flip = 0
    private(set) var count = 0
    private var finished = false
    /// Lines frames up when handheld; nil for a frame-for-frame stack (tests, a phone on a tripod).
    private let aligner: FrameAligner?

    init(seconds: Double, align: Bool = true, progress: @escaping (Double) -> Void, done: @escaping (Result<(sum: CIImage, max: CIImage, count: Int), Error>) -> Void) {
        self.seconds = seconds
        self.aligner = align ? FrameAligner() : nil
        self.onProgress = progress
        self.onDone = done
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if notBefore.isValid, t < notBefore { return }
        if first == nil { first = t }
        let raw = CIImage(cvPixelBuffer: pb)
        let e = raw.extent
        let frame = aligner?.align(raw) ?? raw
        if buffers.isEmpty {
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            // Even slots hold the running sum in 32-bit float (half floats drift after hundreds of frames); odd
            // slots hold the per-pixel maximum, where half precision is plenty.
            for slot in 0..<4 {
                var b: CVPixelBuffer?
                let format = slot % 2 == 0 ? kCVPixelFormatType_128RGBAFloat : kCVPixelFormatType_64RGBAHalf
                CVPixelBufferCreate(nil, Int(e.width), Int(e.height), format, attrs as CFDictionary, &b)
                guard let b else { fail(CameraError.noData); return }
                buffers.append(b)
            }
        }
        // Ping-pong: write the new sum and max into the pair not being read.
        let newSum = sum.map { frame.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? frame
        let newMax = peak.map { frame.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: $0]) } ?? frame
        let (sb, mb) = (buffers[flip * 2], buffers[flip * 2 + 1])
        ctx.render(newSum.cropped(to: e), to: sb, bounds: e, colorSpace: linear)
        ctx.render(newMax.cropped(to: e), to: mb, bounds: e, colorSpace: linear)
        sum = CIImage(cvPixelBuffer: sb, options: [.colorSpace: linear])
        peak = CIImage(cvPixelBuffer: mb, options: [.colorSpace: linear])
        flip ^= 1
        count += 1
        let elapsed = (t - first!).seconds
        onProgress(min(1, elapsed / seconds))
        if elapsed >= seconds, let sum, let peak {
            finished = true
            // Copy out of the ping-pong buffers so they can be released.
            onDone(.success((sum: sum, max: peak, count: count)))
        }
    }

    /// Stops now and keeps what's been collected (the shutter pressed again, or the app leaving the screen).
    func finishNow() {
        guard !finished else { return }
        if count > 0, let sum, let peak {
            finished = true
            onDone(.success((sum: sum, max: peak, count: count)))
        } else {
            fail(CameraError.stopped)
        }
    }

    func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        onDone(.failure(error))
    }
}
