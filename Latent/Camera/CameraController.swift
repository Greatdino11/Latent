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
    case unavailable, noData
    var errorDescription: String? { self == .unavailable ? "The camera isn't available." : "The camera returned no image." }
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

    var isSimulated: Bool { status == .simulated }
    var isReady: Bool { status == .running || status == .simulated }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let queue = DispatchQueue(label: "latent.camera")
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private var device: AVCaptureDevice?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var inFlight: [Int64: PhotoDelegate] = [:]
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var wantsRunning = true
    @ObservationIgnored private var wantsPortrait = false

    private struct Setup { var ok: Bool; var lenses: [LensOption]; var selected: Int; var flash: Bool; var depth = false }

    @MainActor
    func start() async {
        #if targetEnvironment(simulator)
        status = .simulated
        lenses = [LensOption(id: 0, label: "1", zoomFactor: 1)]
        hasFrontCamera = true
        return
        #else
        if configured { setRunning(true); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { status = .unauthorized; return }
        default:
            status = .unauthorized; return
        }
        hasFrontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        let setup: Setup = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.configure(position: .back)) }
        }
        apply(setup)
        status = setup.ok ? .running : .failed
        #endif
    }

    @MainActor private func apply(_ setup: Setup) {
        lenses = setup.lenses; selectedLens = setup.selected; hasFlash = setup.flash; depthSupported = setup.depth
    }

    /// Portrait mode swaps ProRAW for processed capture with depth (iOS can't deliver depth with RAW).
    @MainActor @discardableResult
    func setPortrait(_ on: Bool) async -> Bool {
        if isSimulated { return on }
        guard configured else { wantsPortrait = on; return false }
        return await withCheckedContinuation { cont in queue.async { cont.resume(returning: self.applyPortrait(on)) } }
    }

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
            photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        }
        pickPhotoDimensions(dev)
        if (try? dev.lockForConfiguration()) != nil {           // a format change resets zoom: keep the chosen lens
            dev.videoZoomFactor = min(max(zoom, dev.minAvailableVideoZoomFactor), dev.maxAvailableVideoZoomFactor)
            dev.unlockForConfiguration()
        }
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

    /// 12MP keeps RAW files and develop times reasonable (48MP ProRAW is ~75MB a frame).
    private func pickPhotoDimensions(_ dev: AVCaptureDevice) {
        let dims = dev.activeFormat.supportedMaxPhotoDimensions
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        if let pick = dims.filter({ area($0) <= 12_600_000 }).max(by: { area($0) < area($1) }) ?? dims.min(by: { area($0) < area($1) }) {
            photoOutput.maxPhotoDimensions = pick
        }
    }

    /// Starts or stops the sensor (stopped while the roll or settings cover the viewfinder, and in the background).
    func setRunning(_ running: Bool) {
        wantsRunning = running
        guard configured else { return }
        queue.async {
            if running, !self.session.isRunning { self.session.startRunning() }
            if !running, self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Switches between the back and front cameras.
    @MainActor
    func flip() async {
        let target: AVCaptureDevice.Position = position == .back ? .front : .back
        if isSimulated { position = target; return }
        guard configured else { return }
        let setup: Setup = await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.configure(position: target)) }
        }
        if setup.ok { position = target; apply(setup) }
    }

    // MARK: configuration (camera queue)

    private func configure(position: AVCaptureDevice.Position) -> Setup {
        let failed = Setup(ok: false, lenses: [], selected: 0, flash: false)
        let priority: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: priority, mediaType: .video, position: position).devices
        guard let dev = priority.lazy.compactMap({ t in found.first { $0.deviceType == t } }).first,
              let newInput = try? AVCaptureDeviceInput(device: dev) else { return failed }

        session.beginConfiguration()
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
        // Shoot Apple ProRAW where available: it lets the darkroom skip the phone's tone mapping and sharpening.
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        pickPhotoDimensions(dev)
        // Selfies come out the way the viewfinder showed them.
        if let conn = photoOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = position == .front
        }
        session.commitConfiguration()

        device = dev
        rotation = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)

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
            apply(zoom: base)
        }

        configured = true
        if wantsPortrait { _ = applyPortrait(true) }
        if wantsRunning, !session.isRunning { session.startRunning() }
        return Setup(ok: true, lenses: lenses, selected: selected, flash: dev.hasFlash,
                     depth: dev.formats.contains { !$0.supportedDepthDataFormats.isEmpty })
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
        queue.async { self.apply(zoom: lens.zoomFactor) }
    }

    func setExposureBias(_ ev: Float) {
        queue.async {
            guard let d = self.device, (try? d.lockForConfiguration()) != nil else { return }
            d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias))
            d.unlockForConfiguration()
        }
    }

    /// `point` is in device coordinates (0…1, landscape-right sensor space).
    func focus(at point: CGPoint) {
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

    // MARK: capture

    /// Dim enough that a single frame would be noisy (camera queue).
    private var isLowLight: Bool {
        guard let d = device else { return false }
        return d.iso >= 800 || CMTimeGetSeconds(d.exposureDuration) >= 1.0 / 30
    }

    func capture(flash: FlashSetting, location: CLLocation?) async throws -> CapturedFrame {
        if isSimulated {
            return await Task.detached(priority: .userInitiated) {
                CapturedFrame(source: .image(SimulatedScene.capture), metadata: [:], flashFired: false, location: location)
            }.value
        }
        guard status == .running else { throw CameraError.unavailable }
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                let settings: AVCapturePhotoSettings
                let portrait = self.photoOutput.isDepthDataDeliveryEnabled
                if !portrait, let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                } else if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                // Less multi-frame fusion = less of the over-processed phone look. In low light, allow full
                // multi-frame capture instead: it's what keeps night frames from turning to noise.
                settings.photoQualityPrioritization = self.isLowLight ? .quality : .balanced
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
                let delegate = PhotoDelegate(location: location) { [weak self] result in
                    self?.queue.async { self?.inFlight[id] = nil }
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
    private let completion: (Result<CapturedFrame, Error>) -> Void
    init(location: CLLocation?, completion: @escaping (Result<CapturedFrame, Error>) -> Void) {
        self.location = location
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { completion(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else { completion(.failure(CameraError.noData)); return }
        let source: FrameSource = photo.isRawPhoto ? .raw(data) : .processed(data)
        completion(.success(CapturedFrame(source: source, metadata: photo.metadata,
                                          flashFired: photo.resolvedSettings.isFlashEnabled, location: location)))
    }
}
