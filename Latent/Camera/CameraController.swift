import AVFoundation
import CoreLocation
import CoreImage
import UIKit

struct LensOption: Identifiable, Hashable {
    let id: Int
    let label: String
    let zoomFactor: CGFloat
}

enum FlashSetting: String, CaseIterable {
    case off, auto, on
    var next: FlashSetting { self == .off ? .auto : self == .auto ? .on : .off }
    var icon: String { self == .off ? "bolt.slash" : self == .auto ? "bolt.badge.automatic" : "bolt.fill" }
    var avMode: AVCaptureDevice.FlashMode { self == .off ? .off : self == .auto ? .auto : .on }
}

enum CameraError: LocalizedError {
    case unavailable, noData, stopped
    var errorDescription: String? {
        switch self {
        case .unavailable: "The camera isn't available."
        case .noData: "The camera returned no image."
        case .stopped: "The exposure stopped before any light was collected."
        }
    }
}

/// Owns the AVCaptureSession. On the simulator (no camera) it serves a generated test scene instead.
@Observable
final class CameraController: NSObject {
    enum Status { case idle, unauthorized, running, simulated, failed }

    private(set) var status: Status = .idle
    private(set) var lenses: [LensOption] = []
    private(set) var selectedLens = 0
    private(set) var hasFlash = false
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var hasFrontCamera = false
    /// The current camera can capture depth (for portrait blur).
    private(set) var depthSupported = false
    /// Focus and exposure are locked (long-press in the viewfinder); a tap unlocks.
    private(set) var aeafLocked = false

    /// What the light meter shows: the camera's current shutter and ISO, and how far the exposure is from what it
    /// meters as right (in stops; + is too bright).
    struct Meter: Equatable { var shutter: Double; var iso: Float; var offset: Float }
    private(set) var meter = Meter(shutter: 1.0 / 125, iso: 100, offset: 0)
    @ObservationIgnored private var meterTimer: Timer?

    /// The session is actually delivering frames (not paused behind the roll or in the background).
    private(set) var sessionRunning = false
    @ObservationIgnored private var stopWhenIdle = false

    var isSimulated: Bool { status == .simulated }
    var isReady: Bool { (status == .running && sessionRunning) || status == .simulated }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "latent.camera")
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var inFlight: [Int64: PhotoDelegate] = [:]
    @ObservationIgnored private var configured = false            // camera queue only
    /// Main-thread view of `configured` (set once the first setup is applied).
    @ObservationIgnored private var isConfigured = false
    /// The longest single-frame exposure on the current camera, published from the camera queue.
    private(set) var maxSingleExposure: Double = 1
    @ObservationIgnored private var wantsRunning = true
    @ObservationIgnored private var wantsPortrait = false
    @ObservationIgnored private var wantsHighResolution = false
    /// Process Zero: capture one unmerged Bayer RAW frame instead of ProRAW.
    @ObservationIgnored private var wantsZero = false
    /// A manual (slow) shutter is set: needs a physical camera, which allows custom exposure.
    @ObservationIgnored private var wantsSlowShutter = false
    @ObservationIgnored private var stackOutput: AVCaptureVideoDataOutput?
    @ObservationIgnored private let stackQueue = DispatchQueue(label: "latent.stack")
    @ObservationIgnored private var inFlightStack: FrameStacker?
    @ObservationIgnored private var ultraWideCamera: AVCaptureDevice?
    @ObservationIgnored private var teleCamera: AVCaptureDevice?
    /// The back camera as one virtual device (smooth lens switching, but its photos stop at 12MP).
    @ObservationIgnored private var virtualDevice: AVCaptureDevice?
    /// The plain main camera: the only way to get its full 48MP. Used at 1× when 48MP is on.
    @ObservationIgnored private var mainCamera: AVCaptureDevice?
    @ObservationIgnored private var baseZoom: CGFloat = 1
    @ObservationIgnored private var lensZoom: CGFloat = 1
    @ObservationIgnored private var exposureBias: Float = 0

    private struct Setup { var ok: Bool; var lenses: [LensOption]; var selected: Int; var flash: Bool; var depth = false }

    @MainActor
    func start() async {
        #if targetEnvironment(simulator)
        status = .simulated
        lenses = [LensOption(id: 0, label: "1", zoomFactor: 1)]
        hasFrontCamera = true
        return
        #else
        if isConfigured { setRunning(true); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .unauthorized; return }
        default:
            status = .unauthorized; return
        }
        hasFrontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        observeSession()
        let setup: Setup = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.configure(position: .back)) }
        }
        apply(setup)
        status = setup.ok ? .running : .failed
        #endif
    }

    /// Reads the exposure a few times a second for the viewfinder's meter.
    @MainActor func startMetering() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            // Read the device on the camera queue (where it's changed), publish on the main thread.
            self?.queue.async {
                guard let self, let d = self.device else { return }
                let m = Meter(shutter: d.exposureDuration.seconds, iso: d.iso, offset: d.exposureTargetOffset)
                // Paused or restarting cameras report NaN: keep the last good reading.
                guard m.shutter.isFinite, m.shutter > 0, m.iso.isFinite, m.offset.isFinite else { return }
                Task { @MainActor in
                    // Only publish real changes, so the viewfinder doesn't redraw for nothing.
                    if abs(m.offset - self.meter.offset) > 0.05 || abs(m.shutter - self.meter.shutter) / max(self.meter.shutter, 1e-6) > 0.05
                        || abs(m.iso - self.meter.iso) > 2 { self.meter = m }
                }
            }
        }
    }

    @MainActor private func apply(_ setup: Setup) {
        if setup.ok { isConfigured = true }
        lenses = setup.lenses; selectedLens = setup.selected; hasFlash = setup.flash; depthSupported = setup.depth
        aeafLocked = false
    }

    /// Portrait mode swaps ProRAW for processed capture with depth (iOS can't deliver depth with RAW).
    @MainActor @discardableResult
    func setPortrait(_ on: Bool) async -> Bool {
        if isSimulated { return on }
        guard isConfigured else { queue.async { self.wantsPortrait = on }; return false }
        // On the back, the combined triple camera has no depth: portrait swaps to a depth-capable camera
        // (dual-wide, dual or LiDAR) and back again, so the session is rebuilt either way.
        if position == .back {
            let setup: Setup = await withCheckedContinuation { cont in
                queue.async {
                    self.wantsPortrait = on
                    cont.resume(returning: self.configure(position: .back))
                }
            }
            if setup.ok { apply(setup) }
            return await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.photoOutput.isDepthDataDeliveryEnabled) } }
        }
        return await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.applyPortrait(on)) } }
    }

    /// Back cameras that can capture depth, in order of preference.
    private static let backDepthTypes: [AVCaptureDevice.DeviceType] = [.builtInDualWideCamera, .builtInDualCamera, .builtInLiDARDepthCamera]

    private static func hasDepth(_ dev: AVCaptureDevice) -> Bool { dev.formats.contains { !$0.supportedDepthDataFormats.isEmpty } }

    /// Camera queue.
    private func applyPortrait(_ on: Bool) -> Bool {
        wantsPortrait = on
        guard let dev = device else { return false }
        let zoom = dev.videoZoomFactor
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if on {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
            photoOutput.isAppleProRAWEnabled = false
            // The high-resolution format used for ProRAW has no depth; move to the best one that does.
            if dev.activeFormat.supportedDepthDataFormats.isEmpty, let format = Self.bestDepthFormat(dev),
               (try? dev.lockForConfiguration()) != nil {
                dev.activeFormat = format
                dev.unlockForConfiguration()
            }
            if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = true }
            if photoOutput.isPortraitEffectsMatteDeliverySupported { photoOutput.isPortraitEffectsMatteDeliveryEnabled = true }
        } else {
            photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
            photoOutput.isDepthDataDeliveryEnabled = false
            if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }   // back to the full-res format
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported && !wantsZero
        }
        pickPhotoDimensions(dev)
        if (try? dev.lockForConfiguration()) != nil {           // a format change resets zoom: keep the chosen lens
            dev.videoZoomFactor = min(max(zoom, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
            dev.unlockForConfiguration()
        }
        noteDevice()
        return photoOutput.isDepthDataDeliveryEnabled
    }

    /// The depth-capable format with the largest 4:3 photos (what the Camera app's Portrait mode uses).
    private static func bestDepthFormat(_ dev: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let candidates = dev.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            let d = f.formatDescription.dimensions
            let fourThree = abs(Double(d.width) / Double(max(d.height, 1)) - 4.0 / 3.0) < 0.02
            return (fourThree ? 1 << 40 : 0) + (f.supportedMaxPhotoDimensions.map(area).max() ?? 0)
        }
        return candidates.max { score($0) < score($1) }
    }

    /// 12MP by default (smaller RAWs, quicker develops); the largest the format offers (48MP on the main camera)
    /// when high resolution is on. Portrait's depth formats top out at 12MP anyway.
    private func pickPhotoDimensions(_ dev: AVCaptureDevice) {
        let dims = dev.activeFormat.supportedMaxPhotoDimensions
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let limit = wantsHighResolution && !wantsZero ? Int.max : 12_600_000   // single-frame RAW is 12MP
        if let pick = dims.filter({ area($0) <= limit }).max(by: { area($0) < area($1) }) ?? dims.min(by: { area($0) < area($1) }) {
            photoOutput.maxPhotoDimensions = pick
        }
    }

    /// The virtual back camera never delivers more than 12MP, so 48MP at 1× needs the main camera on its own.
    /// Puts the right one in the session for the current lens and setting. Returns whether it switched
    /// (camera queue).
    @discardableResult
    private func routeForResolution() -> Bool {
        guard configured, !wantsPortrait, let virtual = virtualDevice, let main = mainCamera, let current = device else { return false }
        let mainHas48 = main.formats.contains { $0.supportedMaxPhotoDimensions.contains { Int($0.width) * Int($0.height) > 40_000_000 } }
        let choice = Self.lensCamera(lensZoom: lensZoom, baseZoom: baseZoom, highResolution: wantsHighResolution, mainHas48: mainHas48,
                                     needsPhysical: wantsZero || wantsSlowShutter,
                                     hasUltraWide: ultraWideCamera != nil, hasTele: teleCamera != nil)
        let target: AVCaptureDevice
        switch choice {
        case .virtual: target = virtual
        case .main: target = main
        case .ultraWide: target = ultraWideCamera ?? main
        case .tele: target = teleCamera ?? main
        }
        let wantMain = choice == .main && wantsHighResolution
        guard target.uniqueID != current.uniqueID, let newInput = try? AVCaptureDeviceInput(device: target) else { return false }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            session.commitConfiguration(); return false
        }
        session.addInput(newInput)
        input = newInput
        device = target
        noteDevice()
        if wantMain && !wantsZero { Self.useHighResolutionFormat(target) } else if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported && !wantsZero
        pickPhotoDimensions(target)
        if let conn = photoOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = false
        }
        session.commitConfiguration()
        rotation = AVCaptureDevice.RotationCoordinator(device: target, previewLayer: nil)
        apply(zoom: zoomOnCurrentDevice)
        if (try? target.lockForConfiguration()) != nil {
            target.setExposureTargetBias(min(max(exposureBias, target.minExposureTargetBias), target.maxExposureTargetBias))
            target.unlockForConfiguration()
        }
        Task { @MainActor in self.aeafLocked = false }
        return true
    }

    enum LensCamera: Equatable { case virtual, main, ultraWide, tele }

    /// Which camera should be in the session. The combined (virtual) camera switches lenses smoothly but stops at
    /// 12MP and won't give single-frame RAW or manual exposure; those need the physical camera behind the lens.
    static func lensCamera(lensZoom: CGFloat, baseZoom: CGFloat, highResolution: Bool, mainHas48: Bool, needsPhysical: Bool,
                           hasUltraWide: Bool, hasTele: Bool) -> LensCamera {
        let atBase = abs(lensZoom - baseZoom) < 0.01
        if needsPhysical {
            if lensZoom < baseZoom - 0.01, hasUltraWide { return .ultraWide }
            if lensZoom > baseZoom * 2.5, hasTele { return .tele }
            return .main
        }
        return highResolution && atBase && mainHas48 ? .main : .virtual
    }

    /// The zoom to set for the chosen lens on whichever camera is in the session: the virtual camera zooms between
    /// its lenses; the main camera on its own only for a 2× crop; the other physical lenses not at all.
    private var zoomOnCurrentDevice: CGFloat {
        guard let device else { return lensZoom }
        if !device.constituentDevices.isEmpty || virtualDevice == nil { return lensZoom }
        if device.uniqueID == mainCamera?.uniqueID { return max(1, lensZoom / baseZoom) }
        return 1
    }

    /// Manual shutter on or off (0 = automatic).
    func setSlowShutter(_ seconds: Double) {
        queue.async {
            self.wantsSlowShutter = seconds > 0
            self.routeForResolution()
        }
    }

    /// The longest exposure one frame can take on the current camera.
    /// Camera queue. Publishes facts about the current camera that the main thread needs.
    private func noteDevice() {
        guard let d = device else { return }
        let minFps = d.activeFormat.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1
        let longest = min(d.activeFormat.maxExposureDuration.seconds, 1 / max(minFps, 0.5))
        Task { @MainActor in self.maxSingleExposure = longest.isFinite && longest > 0 ? longest : 1 }
    }

    /// Camera queue. Holds the shutter at `seconds`, raising or lowering ISO to keep the metered brightness (as far
    /// as the sensor's ISO range allows), and calls back once frames are exposed that way.
    /// Returns the device it set, so the same one is released afterwards.
    private func holdShutter(_ seconds: Double, then done: @escaping (AVCaptureDevice?) -> Void) {
        guard let d = device, d.isExposureModeSupported(.custom), (try? d.lockForConfiguration()) != nil else { done(nil); return }
        let duration = CMTime(seconds: min(seconds, d.activeFormat.maxExposureDuration.seconds), preferredTimescale: 1_000_000)
        if duration > d.activeVideoMaxFrameDuration { d.activeVideoMaxFrameDuration = duration }
        let iso = Float(Self.meteredProduct(d) / duration.seconds).clamped(d.activeFormat.minISO, d.activeFormat.maxISO)
        d.setExposureModeCustom(duration: duration, iso: iso) { _ in done(d) }
        d.unlockForConfiguration()
    }

    /// Exposure time × ISO the meter has settled on (what any shutter/ISO pair must match). A camera that's just
    /// restarted can report NaN; fall back to a typical indoor reading rather than pass NaN on (which crashes).
    private static func meteredProduct(_ d: AVCaptureDevice) -> Double {
        let p = d.exposureDuration.seconds * Double(d.iso)
        return p.isFinite && p > 0 ? p : 1.0 / 60 * 400
    }

    /// Camera queue. Back to automatic exposure and normal frame rates after a manual shutter.
    /// `device`: the one that was set manual (whichever camera is current now).
    private func releaseShutter(_ held: AVCaptureDevice? = nil) {
        guard let d = held ?? device, (try? d.lockForConfiguration()) != nil else { return }
        d.activeVideoMinFrameDuration = .invalid
        d.activeVideoMaxFrameDuration = .invalid
        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
        d.setExposureTargetBias(min(max(exposureBias, d.minExposureTargetBias), d.maxExposureTargetBias))
        d.unlockForConfiguration()
        Task { @MainActor in self.aeafLocked = false }
    }

    /// A long exposure (beyond one frame) by stacking a continuous run of video frames for `seconds`.
    func captureStack(seconds: Double, trails: Bool, location: CLLocation?, progress: @escaping @Sendable (Double) -> Void) async throws -> CapturedFrame {
        if isSimulated {
            for i in 1...10 { try? await Task.sleep(for: .seconds(seconds / 10)); progress(Double(i) / 10) }
            return CapturedFrame(source: .image(SimulatedScene.capture, sceneReferred: false), metadata: [:], location: location)
        }
        guard status == .running else { throw CameraError.unavailable }
        let (sum, peak, count): (CIImage, CIImage, Int) = try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let d = self.device else { cont.resume(throwing: CameraError.unavailable); return }
                let stacker = FrameStacker(seconds: seconds, progress: progress) { result in
                    self.queue.async {
                        self.session.beginConfiguration()
                        if let out = self.stackOutput { self.session.removeOutput(out) }
                        self.stackOutput = nil
                        self.session.commitConfiguration()
                        self.releaseShutter(d)
                        self.inFlightStack = nil
                        self.stopIfIdle()
                        cont.resume(with: result.map { ($0.sum, $0.max, $0.count) })
                    }
                }
                // Frames at base ISO up to 1/15 s each: short enough that a hand doesn't smear one frame (so the
                // aligner can line them up) and back to back, so light trails stay unbroken. Many short frames
                // averaged are as clean as a few long ones.
                let product = Self.meteredProduct(d)
                let minFps = Double(d.activeFormat.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1)
                let longest = min(d.activeFormat.maxExposureDuration.seconds, 1 / max(minFps, 1), 1.0 / 15)
                let exposure = (product / Double(d.activeFormat.minISO)).clamped(d.activeFormat.minExposureDuration.seconds, longest)
                let frame = max(exposure, 1.0 / 30)
                let iso = Float(product / exposure).clamped(d.activeFormat.minISO, d.activeFormat.maxISO)

                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                self.session.beginConfiguration()
                guard self.session.canAddOutput(out) else {
                    self.session.commitConfiguration(); cont.resume(throwing: CameraError.unavailable); return
                }
                self.session.addOutput(out)
                if let conn = out.connection(with: .video), let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture,
                   conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
                self.session.commitConfiguration()
                self.stackOutput = out
                out.setSampleBufferDelegate(stacker, queue: self.stackQueue)
                self.inFlightStack = stacker

                if (try? d.lockForConfiguration()) != nil {
                    let t = CMTime(seconds: frame, preferredTimescale: 1_000_000)
                    d.activeVideoMaxFrameDuration = t
                    d.activeVideoMinFrameDuration = t
                    if d.isExposureModeSupported(.custom) {
                        d.setExposureModeCustom(duration: CMTime(seconds: exposure, preferredTimescale: 1_000_000), iso: iso) { sync in
                            self.stackQueue.async { stacker.notBefore = sync }
                        }
                    }
                    d.unlockForConfiguration()
                }
                // Give up if frames stop arriving (camera interrupted).
                self.stackQueue.asyncAfter(deadline: .now() + seconds + 6) { stacker.fail(CameraError.noData) }
            }
        }
        var meta: [String: Any] = [:]
        meta[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifExposureTime as String: seconds]
        let image = LongExposure.blend(sum: sum, max: peak, count: count, trails: trails)
        return CapturedFrame(source: .image(image, sceneReferred: false), metadata: meta, location: location)
    }

    /// Panorama: after the first shot, hold exposure, white balance and focus so every frame matches (the seams
    /// disappear only if the frames do).
    func lockForPanorama(_ on: Bool) {
        if isSimulated { return }
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if on {
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                Task { @MainActor in self.aeafLocked = false }
            }
            d.unlockForConfiguration()
        }
    }

    /// Ends a running long exposure now, keeping what's been exposed so far.
    func finishExposureEarly() {
        queue.async {
            guard let stacker = self.inFlightStack else { return }
            self.stackQueue.async { stacker.finishNow() }
        }
    }

    /// Switches Process Zero (single-frame Bayer RAW) on or off.
    func setZero(_ on: Bool) {
        queue.async {
            self.wantsZero = on
            guard self.configured, let dev = self.device else { return }
            if self.routeForResolution() { return }
            self.session.beginConfiguration()
            // Leave a 48MP sensor format behind: single-frame RAW is 12MP.
            if on, !self.wantsPortrait, self.session.canSetSessionPreset(.photo) { self.session.sessionPreset = .photo }
            if !self.wantsPortrait { self.photoOutput.isAppleProRAWEnabled = self.photoOutput.isAppleProRAWSupported && !on }
            self.pickPhotoDimensions(dev)
            self.session.commitConfiguration()
            self.apply(zoom: self.zoomOnCurrentDevice)
        }
    }

    /// The .photo preset usually already allows 48MP; if not, pick the 4:3 format that does.
    private static func useHighResolutionFormat(_ dev: AVCaptureDevice) {
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        if (dev.activeFormat.supportedMaxPhotoDimensions.map(area).max() ?? 0) > 40_000_000 { return }
        let fourThree: (AVCaptureDevice.Format) -> Bool = {
            let d = $0.formatDescription.dimensions
            return abs(Double(d.width) / Double(max(d.height, 1)) - 4.0 / 3.0) < 0.02
        }
        let best = dev.formats.filter { f in fourThree(f) && (f.supportedMaxPhotoDimensions.map(area).max() ?? 0) > 40_000_000 }
            .min { area($0.formatDescription.dimensions) < area($1.formatDescription.dimensions) }
        if let best, (try? dev.lockForConfiguration()) != nil { dev.activeFormat = best; dev.unlockForConfiguration() }
    }

    /// Switches between 12MP and 48MP capture.
    func setHighResolution(_ on: Bool) {
        queue.async {
            self.wantsHighResolution = on
            guard self.configured, let dev = self.device else { return }
            if self.routeForResolution() { return }
            self.session.beginConfiguration()
            self.pickPhotoDimensions(dev)
            self.session.commitConfiguration()
        }
    }

    /// Starts or stops the sensor (stopped while the roll or settings cover the viewfinder, and in the background).
    func setRunning(_ running: Bool) {
        queue.async {
            self.wantsRunning = running
            guard self.configured else { return }
            if running {
                self.stopWhenIdle = false
                if !self.session.isRunning { self.session.startRunning() }
            } else if self.session.isRunning {
                // Never pull the sensor out from under a photo or long exposure still being taken: stop once done.
                if !self.inFlight.isEmpty || self.stackOutput != nil { self.stopWhenIdle = true } else { self.session.stopRunning() }
            }
            self.noteRunning()
        }
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Interruptions (a call, another app taking the camera, too hot) and runtime errors (media services reset)
    /// stop the session on their own. Keep `sessionRunning` true to reality, end a long exposure cleanly, and start
    /// again when allowed.
    private func observeSession() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in self?.queue.async { self?.noteRunning() } }
        observers = [
            nc.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil, using: refresh),
            nc.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil, using: refresh),
            nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }
                    if let stacker = self.inFlightStack { self.stackQueue.async { stacker.finishNow() } }
                    self.noteRunning()
                }
            },
            nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                self?.queue.async { self?.restartIfWanted() }
            },
            nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] _ in
                // Media services resets and most runtime errors recover with a restart; try once, a little later.
                self?.queue.asyncAfter(deadline: .now() + 0.5) { self?.restartIfWanted() }
            },
        ]
    }

    /// Camera queue. Starts the session again if it should be running.
    private func restartIfWanted() {
        if configured, wantsRunning, !session.isRunning { session.startRunning() }
        noteRunning()
    }

    /// Camera queue. Stops the session if a stop was put off until the last capture finished.
    private func stopIfIdle() {
        guard stopWhenIdle, inFlight.isEmpty, stackOutput == nil else { return }
        stopWhenIdle = false
        if !wantsRunning, session.isRunning { session.stopRunning() }
        noteRunning()
    }

    /// Camera queue. Publishes whether frames are flowing.
    private func noteRunning() {
        let running = session.isRunning
        Task { @MainActor in self.sessionRunning = running }
    }

    /// Switches between the back and front cameras.
    @MainActor
    func flip() async {
        let target: AVCaptureDevice.Position = position == .back ? .front : .back
        if isSimulated { position = target; return }
        guard isConfigured else { return }
        let setup: Setup = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.configure(position: target)) }
        }
        if setup.ok { position = target; apply(setup) }
    }

    // MARK: configuration (camera queue)

    private func configure(position: AVCaptureDevice.Position) -> Setup {
        let failed = Setup(ok: false, lenses: [], selected: 0, flash: false)
        let normal: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let priority = position == .back && wantsPortrait ? Self.backDepthTypes + normal : normal
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: priority, mediaType: .video, position: position).devices
        let usable = position == .back && wantsPortrait
            ? priority.lazy.compactMap { t in found.first { $0.deviceType == t && Self.hasDepth($0) } }.first
            : nil
        guard let dev = usable ?? priority.lazy.compactMap({ t in found.first { $0.deviceType == t } }).first,
              let newInput = try? AVCaptureDeviceInput(device: dev) else { return failed }

        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false   // photos only: leave other audio alone
        session.sessionPreset = .photo
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            session.commitConfiguration(); return failed
        }
        session.addInput(newInput)
        input = newInput
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else { session.commitConfiguration(); return failed }
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .quality
        // Leaving portrait (or a fresh camera): no depth, and ProRAW where available — it lets the darkroom skip the
        // phone's tone mapping and sharpening. Portrait turns depth on below, after the session is set up.
        photoOutput.isPortraitEffectsMatteDeliveryEnabled = false
        photoOutput.isDepthDataDeliveryEnabled = false
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported && !wantsZero
        pickPhotoDimensions(dev)
        // Selfies come out the way the viewfinder showed them.
        if let conn = photoOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = position == .front
        }
        session.commitConfiguration()

        device = dev
        rotation = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
        noteDevice()

        // Lenses: a virtual device exposes switch-over zoom factors for each physical camera.
        var lenses = [LensOption(id: 0, label: "1", zoomFactor: 1)]
        var selected = 0
        if position == .back {
            let switchOvers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            let hasTele = dev.constituentDevices.contains { $0.deviceType == .builtInTelephotoCamera }
            let factors = [1] + switchOvers
            let base = hasUltraWide ? (factors.count > 1 ? factors[1] : 1) : 1
            lenses = factors.enumerated().map { i, f in LensOption(id: i, label: Self.label(f / base), zoomFactor: f) }
            if !hasTele, base * 2 <= dev.maxAvailableVideoZoomFactor {
                lenses.append(LensOption(id: lenses.count, label: "2", zoomFactor: base * 2))
            }
            selected = lenses.firstIndex { $0.zoomFactor == base } ?? 0
            baseZoom = base; lensZoom = base
            apply(zoom: base)
        }
        virtualDevice = position == .back && !dev.constituentDevices.isEmpty ? dev : nil
        mainCamera = position == .back ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) : nil
        ultraWideCamera = position == .back ? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) : nil
        teleCamera = position == .back ? AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) : nil

        configured = true
        routeForResolution()
        if wantsPortrait { _ = applyPortrait(true) }
        if wantsRunning, !session.isRunning { session.startRunning() }
        noteRunning()
        return Setup(ok: true, lenses: lenses, selected: selected, flash: dev.hasFlash,
                     depth: Self.hasDepth(dev) || (position == .back && AVCaptureDevice.DiscoverySession(
                        deviceTypes: Self.backDepthTypes, mediaType: .video, position: .back).devices.contains(where: Self.hasDepth)))
    }

    private static func label(_ x: CGFloat) -> String {
        if x < 1 { return String(format: "%g", Double(x)).replacingOccurrences(of: "0.", with: ".") }
        return String(format: "%g", (Double(x) * 10).rounded() / 10)
    }

    private func apply(zoom: CGFloat) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        device.unlockForConfiguration()
    }

    // MARK: controls

    @MainActor
    func select(lens: LensOption) {
        selectedLens = lens.id
        queue.async {
            self.lensZoom = lens.zoomFactor
            if !self.routeForResolution() { self.apply(zoom: self.zoomOnCurrentDevice) }
        }
    }

    func setExposureBias(_ ev: Float) {
        queue.async {
            self.exposureBias = ev
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias))
            d.unlockForConfiguration()
        }
    }

    /// `point` is in device coordinates (0…1, landscape-right sensor space).
    func focus(at point: CGPoint) {
        Task { @MainActor in aeafLocked = false }
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = point; d.focusMode = .autoFocus
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = point; d.exposureMode = .continuousAutoExposure
            }
            d.isSubjectAreaChangeMonitoringEnabled = true
            d.unlockForConfiguration()
        }
    }

    /// Split focus: focus only at `point` (device coordinates), leaving exposure where it is.
    func setFocus(at point: CGPoint) {
        Task { @MainActor in aeafLocked = false }
        queue.async {
            guard let d = self.device, d.isFocusPointOfInterestSupported, (try? d.lockForConfiguration()) != nil else { return }
            d.focusPointOfInterest = point
            if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
            d.isSubjectAreaChangeMonitoringEnabled = false        // stay where it was put
            d.unlockForConfiguration()
        }
    }

    /// Split exposure: meter only at `point` (device coordinates), leaving focus where it is.
    func setExposure(at point: CGPoint) {
        Task { @MainActor in aeafLocked = false }
        queue.async {
            guard let d = self.device, d.isExposurePointOfInterestSupported, (try? d.lockForConfiguration()) != nil else { return }
            d.exposurePointOfInterest = point
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            d.isSubjectAreaChangeMonitoringEnabled = false
            d.unlockForConfiguration()
        }
    }

    /// Focuses and meters at `point` once, then holds both until the next tap (device coordinates).
    @MainActor
    func lock(at point: CGPoint) {
        aeafLocked = true
        guard !isSimulated else { return }
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = point; d.focusMode = .autoFocus          // focuses once, then stays put
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                d.exposurePointOfInterest = point; d.exposureMode = .autoExpose   // meters once, then locks
            }
            d.isSubjectAreaChangeMonitoringEnabled = false
            d.unlockForConfiguration()
        }
    }

    // MARK: capture

    /// Dim enough that a single frame would be noisy (camera queue).
    private var isLowLight: Bool {
        guard let d = device else { return false }
        return d.iso >= 800 || CMTimeGetSeconds(d.exposureDuration) >= 1.0 / 30
    }

    /// `shutter`: a manual shutter in seconds (up to what one frame allows), or 0 for automatic.
    func capture(flash: FlashSetting, location: CLLocation?, shutter: Double = 0) async throws -> CapturedFrame {
        if isSimulated {
            return await Task.detached(priority: .userInitiated) {
                CapturedFrame(source: .image(SimulatedScene.capture), metadata: [:], flashFired: false, location: location)
            }.value
        }
        guard status == .running else { throw CameraError.unavailable }
        var held: AVCaptureDevice?
        if shutter > 0 {
            held = await withCheckedContinuation { (c: CheckedContinuation<AVCaptureDevice?, Never>) in
                queue.async { self.holdShutter(shutter) { c.resume(returning: $0) } }
            }
        }
        defer { if shutter > 0 { let d = held; queue.async { self.releaseShutter(d) } } }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let settings: AVCapturePhotoSettings
                let portrait = self.photoOutput.isDepthDataDeliveryEnabled
                let bayer = self.wantsZero && !portrait
                    ? self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
                    : nil
                if let bayer {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: bayer)
                } else if !portrait, let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                // Less multi-frame fusion = less of the over-processed phone look. In low light, allow full
                // multi-frame capture instead: it's what keeps night frames from turning to noise.
                // A manual shutter is one honest exposure: no multi-frame merging.
                settings.photoQualityPrioritization = bayer != nil || shutter > 0 ? .speed : self.isLowLight ? .quality : .balanced
                if self.photoOutput.supportedFlashModes.contains(flash.avMode) { settings.flashMode = flash.avMode }
                if portrait {
                    settings.isDepthDataDeliveryEnabled = true
                    settings.embedsDepthDataInPhoto = true
                    if self.photoOutput.isPortraitEffectsMatteDeliveryEnabled {
                        settings.isPortraitEffectsMatteDeliveryEnabled = true
                        settings.embedsPortraitEffectsMatteInPhoto = true
                    }
                }
                if let conn = self.photoOutput.connection(with: .video),
                   let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture,
                   conn.isVideoRotationAngleSupported(angle) {
                    conn.videoRotationAngle = angle
                }
                let id = settings.uniqueID
                let delegate = PhotoDelegate(location: location, singleFrame: bayer != nil) { [weak self] result in
                    self?.queue.async { self?.inFlight[id] = nil; self?.stopIfIdle() }
                    cont.resume(with: result)
                }
                self.inFlight[id] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let location: CLLocation?
    private let singleFrame: Bool
    private let completion: (Result<CapturedFrame, Error>) -> Void
    init(location: CLLocation?, singleFrame: Bool, completion: @escaping (Result<CapturedFrame, Error>) -> Void) {
        self.location = location
        self.singleFrame = singleFrame
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else { completion(.failure(CameraError.noData)); return }
        let source: FrameSource = photo.isRawPhoto ? .raw(data) : .processed(data)
        var frame = CapturedFrame(source: source, metadata: photo.metadata,
                                  flashFired: photo.resolvedSettings.isFlashEnabled, location: location)
        frame.singleFrame = singleFrame && photo.isRawPhoto
        completion(.success(frame))
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
