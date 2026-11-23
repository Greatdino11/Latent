import AVFoundation
import CoreImage

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
        let k = CGFloat(1) / CGFloat(Swift.max(count, 1))
        let mean = sum.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
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

    init(seconds: Double, progress: @escaping (Double) -> Void, done: @escaping (Result<(sum: CIImage, max: CIImage, count: Int), Error>) -> Void) {
        self.seconds = seconds
        self.onProgress = progress
        self.onDone = done
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if notBefore.isValid, t < notBefore { return }
        if first == nil { first = t }
        let frame = CIImage(cvPixelBuffer: pb)
        let e = frame.extent
        if buffers.isEmpty {
            let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            for _ in 0..<4 {
                var b: CVPixelBuffer?
                CVPixelBufferCreate(nil, Int(e.width), Int(e.height), kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &b)
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
