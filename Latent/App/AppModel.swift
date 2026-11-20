import CoreImage
import CoreLocation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {
    let camera = CameraController()
    let roll = RollStore()
    let prefs = Preferences()
    let level = LevelMonitor()
    let location = LocationProvider()
    let orientation = DeviceOrientation()

    var exposure: Double = 0 {
        didSet { if !camera.isSimulated { camera.setExposureBias(Float(exposure)) } }
    }
    var flash: FlashSetting = .off
    /// Portrait mode: capture depth so the background can be blurred (now and when re-developing).
    private(set) var portrait = false

    func togglePortrait() {
        let want = !portrait
        portrait = want
        Task {
            let ok = await camera.setPortrait(want)
            if want && !ok {
                portrait = false
                show("Portrait isn't available on this camera")
            }
        }
    }
    private(set) var developingCount = 0
    private(set) var shutterTick = 0
    /// The most recently developed frame, used to play the reveal on the roll thumbnail.
    private(set) var lastDeveloped: RollItem?
    /// A freshly developed frame waiting for its full-screen reveal.
    var reveal: RollItem?
    var errorMessage: String?
    /// Progress / result of importing photos, shown in the roll.
    var importStatus: String?
    /// A short message over the viewfinder (e.g. a Photos save that failed). Clears itself.
    private(set) var notice: String?
    /// How long the most recent frame took to develop.
    private(set) var lastDevelopSeconds: Double?
    /// Frames waiting to be developed at once. Each ProRAW frame is ~25 MB in memory until it's done.
    static let maxPending = 3
    /// At 48MP each waiting frame is ~4x the memory: develop one at a time.
    var maxPending: Int { prefs.highResolution ? 1 : Self.maxPending }

    /// The roll or settings is covering the viewfinder: the sensor and sensors-for-UI can rest.
    var viewfinderCovered = false { didSet { updateSensors() } }
    var isActive = true { didSet { updateSensors() } }

    func launch() async {
        FilmAdvanceSound.configureSession()   // never interrupt music or podcasts
        camera.setHighResolution(prefs.highResolution)
        await camera.start()
        updateSensors()
        orientation.start()
        // Build the look tables in the background so the first frame on each stock develops quickly.
        let stocks = prefs.visibleStocks
        let expandSDR = camera.isSimulated
        Task.detached(priority: .background) { await Darkroom.shared.prewarm(stocks, expandSDR: expandSDR) }
    }

    func updateSensors() {
        let live = isActive && !viewfinderCovered
        camera.setRunning(live)
        location.setActive(live && prefs.saveLocation)
        if live, prefs.showLevel { level.start() } else { level.stop() }
    }

    // MARK: capture

    /// Self-timer: 0 (off), 3 or 10 seconds.
    var timerSeconds = 0
    /// Seconds left on a running self-timer.
    private(set) var countdown: Int?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    /// The shutter: starts the self-timer when one is set (pressing again cancels it), otherwise shoots.
    func capture() {
        if countdownTask != nil {
            countdownTask?.cancel(); countdownTask = nil; countdown = nil
            Feedback.selection()
            return
        }
        guard timerSeconds > 0 else { fire(); return }
        countdownTask = Task {
            for left in stride(from: timerSeconds, through: 1, by: -1) {
                countdown = left
                Feedback.selection()
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            fire()
        }
    }

    private func fire() {
        guard camera.isReady else { return }
        guard developingCount < maxPending else {
            show("Developing… one moment")
            return
        }
        shutterTick += 1
        Feedback.shutter()
        let stock = prefs.resolveStock()
        Task { await shoot(stock: stock, saveToPhotos: prefs.saveToPhotos) }
    }

    private func currentOptions(for stock: FilmStock) -> DevelopOptions {
        var o = DevelopOptions(
            exposure: camera.isSimulated ? exposure : 0,
            aspect: prefs.aspect,
            grainAmount: prefs.grainAmount,
            halation: prefs.halation,
            flareAmount: prefs.flareAmount,
            dateStamp: prefs.dateStamp,
            frame: prefs.frameStyle,
            date: Date()
        )
        o.strength = prefs.strength(for: stock)
        if prefs.highResolution { o.fullResolution = true }
        if prefs.lightLeak > 0 { o.lightLeak = prefs.lightLeak }
        if portrait { o.portraitLens = prefs.portraitLens; o.blurAmount = prefs.blurAmount }
        if prefs.dust { o.dust = true }
        return o
    }

    private func shoot(stock: FilmStock, saveToPhotos: Bool) async {
        let options = currentOptions(for: stock)
        let saveOriginal = prefs.saveOriginal
        let fix = prefs.saveLocation ? location.current : nil
        developingCount += 1
        defer { developingCount -= 1 }
        do {
            let frame = try await camera.capture(flash: flash, location: fix)
            let started = Date()
            let result = try await Darkroom.shared.develop(frame, stock: stock, options: options)
            lastDevelopSeconds = Date().timeIntervalSince(started)
            let item = try roll.add(result, stock: stock)
            lastDeveloped = item
            Feedback.advance()
            if prefs.bigReveal { reveal = item }
            if saveToPhotos {
                let recipe = (try? JSONEncoder().encode(result.options)) ?? Data()
                do {
                    let id = try await PhotoLibrary.create(print: result.jpeg, original: saveOriginal ? frame.originalData : nil,
                                                           recipe: recipe, location: fix, date: options.date)
                    roll.setPhotosID(id, for: item)
                } catch {
                    show("Saved on the roll, but not to Photos: \(error.localizedDescription)")
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Develops photos picked from the library (RAW or regular) on the current stock, keeping their full frame.
    func importPhotos(_ picks: [PhotosPickerItem]) async {
        var done = 0, failed = 0
        // Load the next photo from the library while the current one develops (one ahead, to bound memory).
        func load(_ i: Int) -> Task<ImportedPhoto?, Error>? {
            i < picks.count ? Task { try await picks[i].loadTransferable(type: ImportedPhoto.self) } : nil
        }
        var next = load(0)
        for (i, pick) in picks.enumerated() {
            importStatus = "Developing \(i + 1) of \(picks.count)…"
            developingCount += 1
            defer { developingCount -= 1 }
            let current = next
            next = load(i + 1)
            do {
                guard let photo = try await current?.value else { failed += 1; continue }
                let stock = prefs.resolveStock()
                let metadata = JPEGEncoder.metadata(of: photo.data)
                var options = currentOptions(for: stock)
                options.aspect = nil
                options.exposure = 0
                options.date = Self.captureDate(metadata) ?? Date()   // date stamp shows when it was taken
                let rawType = pick.supportedContentTypes.first { $0.conforms(to: .rawImage) }?.identifier
                let frame = CapturedFrame(source: photo.isRAW ? .raw(photo.data, hint: rawType) : .processed(photo.data), metadata: metadata)
                let result = try await Darkroom.shared.develop(frame, stock: stock, options: options)
                lastDeveloped = try roll.add(result, stock: stock, filedAt: Date())   // newest on the roll
                done += 1
            } catch {
                failed += 1
            }
        }
        let noun = done == 1 ? "photo" : "photos"
        importStatus = failed == 0 ? "Imported \(done) \(noun)" : "Imported \(done) \(noun), \(failed) couldn't be read"
    }

    /// When a photo was taken, from its EXIF (DateTimeOriginal + offset).
    static func captureDate(_ metadata: [String: Any]) -> Date? {
        guard let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
            if let d = f.date(from: text + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }

    func show(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if notice == message { notice = nil }
        }
    }

    // MARK: re-developing

    /// Prints a frame's negative again: on another stock, with an edit (push/pull, strength, framing), or as-is to
    /// pick up new texture settings. Grain, halation and flare always come from the current settings.
    /// If the frame was saved to Photos, that copy is updated in place. Returns a status line.
    @discardableResult
    func reprint(_ item: RollItem, stock: FilmStock? = nil, edit: (inout DevelopOptions) -> Void = { _ in }) async throws -> String {
        let stock = stock ?? item.stock ?? .clear
        let negative = try Data(contentsOf: item.negativeURL)
        var options = roll.recipe(for: item)
        options.grainAmount = prefs.grainAmount
        options.halation = prefs.halation
        options.flareAmount = prefs.flareAmount
        if stock.id != item.stockID { options.strength = prefs.strength(for: stock) }
        edit(&options)
        let metadata = JPEGEncoder.metadata(of: item.url)
        let depth = try? Data(contentsOf: item.depthURL)
        let jpeg = try await Darkroom.shared.redevelop(negative: negative, depth: depth, metadata: metadata, stock: stock, options: options)
        let updated = try roll.replace(item, stock: stock, jpeg: jpeg, options: options)
        if let id = roll.photosID(for: updated) {
            do {
                try await PhotoLibrary.applyEdit(id: id, print: jpeg, recipe: (try? JSONEncoder().encode(options)) ?? Data())
                return "Updated in Photos too."
            } catch PhotoLibrary.Failure.missing {
                roll.setPhotosID(nil, for: updated)
            } catch {
                return "Re-developed. Couldn't update Photos: \(error.localizedDescription)"
            }
        }
        return "Re-developed."
    }

    /// Saves a frame to Photos: updates its existing copy, or adds a new one.
    func saveToPhotos(_ item: RollItem) async throws -> String {
        let jpeg = try Data(contentsOf: item.url)
        let recipe = (try? JSONEncoder().encode(roll.recipe(for: item))) ?? Data()
        if let id = roll.photosID(for: item) {
            do {
                try await PhotoLibrary.applyEdit(id: id, print: jpeg, recipe: recipe)
                return "Updated in Photos"
            } catch PhotoLibrary.Failure.missing {
                roll.setPhotosID(nil, for: item)
            }
        }
        let id = try await PhotoLibrary.create(print: jpeg, original: nil, recipe: recipe, location: nil, date: item.date)
        roll.setPhotosID(id, for: item)
        return "Saved to Photos"
    }

    #if DEBUG
    /// Launch with `-demoRoll` to develop the test scene once on every stock (simulator testing).
    /// Add `-demoRedevelop` to also re-develop the newest frame on Coast, pushed +1, square, half strength.
    func developDemoRollIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard camera.isSimulated else { return }
        // `-demoInput`: develop every image in Documents/DemoInput on every stock.
        if args.contains("-demoInput") {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoInput")
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
            var t = Date()
            for file in files {
                guard let data = try? Data(contentsOf: file) else { continue }
                // `-asRAW`: feed the photo in as an under-exposed scene-referred capture, like ProRAW of a backlit scene.
                let asRAW = args.contains("-asRAW")
                let rawLike = CIImage(data: data, options: [.applyOrientationProperty: true])?
                    .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
                let isDNGFile = ["dng", "nef", "cr2", "cr3", "arw", "raf", "orf", "rw2"].contains(file.pathExtension.lowercased())
                // `-demoPortrait`: a synthetic depth map (near in the middle) and each lens, on Honey.
                if args.contains("-demoPortrait"), let probe = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                    // Subject = warm, saturated pixels (red well above green): a sharp-edged "near" region, stored at
                    // the iPhone's depth-map resolution (768 px wide) so upsampling artefacts show up as on device.
                    let e = probe.extent
                    let warm = probe.applyingFilter("CIColorMatrix", parameters: [
                        "inputRVector": CIVector(x: 5, y: -5, z: 0, w: 0), "inputGVector": CIVector(x: 5, y: -5, z: 0, w: 0),
                        "inputBVector": CIVector(x: 5, y: -5, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                        "inputBiasVector": CIVector(x: 0.15, y: 0.15, z: 0.15, w: 0)])
                        .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                                                                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                    let k = 768 / e.width
                    let depth = warm.transformed(by: CGAffineTransform(scaleX: k, y: k)).cropped(to: CGRect(x: 0, y: 0, width: 768, height: (e.height * k).rounded()))
                    for lens in PortraitLens.allCases {
                        t = t.addingTimeInterval(1)
                        var options = currentOptions(for: .honey); options.date = t
                        options.portraitLens = lens; options.blurAmount = 0.9
                        let frame = CapturedFrame(source: isDNGFile ? .raw(data, hint: UTType(filenameExtension: file.pathExtension)?.identifier) : .processed(data),
                                                  metadata: [:], depth: depth)
                        if let result = try? await Darkroom.shared.develop(frame, stock: .honey, options: options) {
                            try? roll.add(result, stock: .honey)
                        }
                    }
                    continue
                }
                // `-stocks=a,b,c` limits which stocks are rendered.
                let only = args.first { $0.hasPrefix("-stocks=") }.map { Set($0.dropFirst(8).split(separator: ",").map(String.init)) }
                for stock in FilmStock.available where (only?.contains(stock.id) ?? true)
                    && (isDNGFile || !asRAW || ["honey", "coast", "pine", "valley"].contains(stock.id)) {
                    t = t.addingTimeInterval(1)
                    var options = currentOptions(for: stock); options.date = t
                    let isDNG = ["dng", "nef", "cr2", "cr3", "arw", "raf", "orf", "rw2"].contains(file.pathExtension.lowercased())
                    let frame = isDNG ? CapturedFrame(source: .raw(data, hint: UTType(filenameExtension: file.pathExtension)?.identifier), metadata: [:])
                        : asRAW && rawLike != nil
                        ? CapturedFrame(source: .image(rawLike!, sceneReferred: true), metadata: [:])
                        : CapturedFrame(source: .processed(data), metadata: [:])
                    if let result = try? await Darkroom.shared.develop(frame, stock: stock, options: options) {
                        try? roll.add(result, stock: stock)
                    }
                }
            }
            return
        }
        // `-demoNegatives`: re-develop shared negatives (Documents/DemoNegatives/<base>.neg.heic + .recipe.json)
        // on every stock — the calibration loop for tuning stocks on real captures.
        if args.contains("-demoNegatives") {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoNegatives")
            let negs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(".neg.heic") }.sorted { $0.path < $1.path }
            var t = Date()
            for neg in negs {
                let base = neg.lastPathComponent.replacingOccurrences(of: ".neg.heic", with: "")
                guard let data = try? Data(contentsOf: neg) else { continue }
                var recipe = (try? JSONDecoder().decode(DevelopOptions.self, from: Data(contentsOf: dir.appendingPathComponent(base + ".recipe.json")))) ?? DevelopOptions()
                recipe.dateStamp = false; recipe.frame = .none
                for stock in FilmStock.all {
                    t = t.addingTimeInterval(1)
                    guard let jpeg = try? await Darkroom.shared.redevelop(negative: data, metadata: [:], stock: stock, options: recipe) else { continue }
                    let result = DevelopResult(jpeg: jpeg, negative: data, options: recipe)
                    try? roll.add(result, stock: stock, filedAt: t)
                }
            }
            return
        }
        // `-demoDepth`: real portrait negatives (Documents/DemoNegatives/<base>.neg.heic + .depth.png + .recipe.json)
        // with every lens, at auto focus and at the near subject.
        if args.contains("-demoDepth") {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoNegatives")
            let negs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasSuffix(".neg.heic") }.sorted { $0.path < $1.path }
            var t = Date()
            for neg in negs {
                let base = neg.lastPathComponent.replacingOccurrences(of: ".neg.heic", with: "")
                guard let data = try? Data(contentsOf: neg), let depth = try? Data(contentsOf: dir.appendingPathComponent(base + ".depth.png")),
                      let depthImage = CIImage(data: depth, options: [.colorSpace: NSNull()]) else { continue }
                var recipe = (try? JSONDecoder().decode(DevelopOptions.self, from: Data(contentsOf: dir.appendingPathComponent(base + ".recipe.json")))) ?? DevelopOptions()
                recipe.dateStamp = false; recipe.frame = .none; recipe.dust = nil; recipe.blurAmount = 0.6
                let auto = DepthMap.autoFocus(depthImage, matte: nil, context: CIContext())
                for lens in PortraitLens.allCases {
                    for focus in [auto, 0.85] {
                        t = t.addingTimeInterval(1)
                        var o = recipe; o.portraitLens = lens; o.focusDepth = focus
                        guard let jpeg = try? await Darkroom.shared.redevelop(negative: data, depth: depth, metadata: [:], stock: .pine, options: o) else { continue }
                        try? roll.add(DevelopResult(jpeg: jpeg, negative: data, options: o), stock: .pine, filedAt: t)
                    }
                }
            }
            return
        }
        guard args.contains("-demoRoll") else { return }
        for stock in FilmStock.all {
            await shoot(stock: stock, saveToPhotos: false)
            try? await Task.sleep(for: .milliseconds(20))
        }
        if args.contains("-demoRedevelop"), let first = roll.items.first {
            _ = try? await reprint(first, stock: .coast) { $0.pushPull = 1; $0.aspect = .r1x1; $0.strength = 0.5 }
        }
    }
    #endif
}

/// Which way the phone is physically held, so icons can turn upright while the UI stays portrait.
@Observable
final class DeviceOrientation {
    private(set) var angle: Angle = .zero
    @ObservationIgnored private var observer: NSObjectProtocol?

    @MainActor
    func start() {
        guard observer == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            switch UIDevice.current.orientation {
            case .portrait: self?.angle = .zero
            case .landscapeLeft: self?.angle = .degrees(90)
            case .landscapeRight: self?.angle = .degrees(-90)
            default: break   // face up/down, upside down: keep the last
            }
        }
    }
}

/// A photo from the library: the RAW original when there is one, otherwise the image as stored.
struct ImportedPhoto: Transferable {
    let data: Data
    let isRAW: Bool

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .rawImage) { ImportedPhoto(data: $0, isRAW: true) }
        DataRepresentation(importedContentType: .image) { ImportedPhoto(data: $0, isRAW: false) }
    }
}
