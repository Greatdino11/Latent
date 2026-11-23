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
    /// Mirrors deletions made in the Photos app back onto the roll.
    @ObservationIgnored private(set) lazy var photosSync = PhotosSync(roll: roll)

    var exposure: Double = 0 {
        didSet { if !camera.isSimulated { camera.setExposureBias(Float(exposure)) } }
    }
    var flash: FlashSetting = .off
    /// Portrait mode: capture depth so the background can be blurred (now and when re-developing).
    private(set) var portrait = false

    /// A panorama or long exposure is under way: the camera mustn't change underneath it.
    var captureBusy: Bool { pano != nil || exposing != nil }

    func togglePortrait() {
        guard !captureBusy else { return }
        let want = !portrait
        if want, prefs.zeroProcess || prefs.highResolution || prefs.shutter > 0 {
            show("Portrait uses normal capture: ZERO, 48MP and slow shutter pause until it's off")
        }
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
    var isActive = true {
        didSet {
            updateSensors()
            if isActive && !oldValue { photosSync.refresh() }   // catch deletions made while we were away
            if !isActive { flushPhotos() }                      // leaving: bring edited frames up to date in Photos
        }
    }

    func launch() async {
        FilmAdvanceSound.configureSession()   // never interrupt music or podcasts
        camera.setHighResolution(prefs.highResolution)
        camera.setZero(prefs.zeroProcess)
        camera.setSlowShutter(prefs.shutter)
        await camera.start()
        camera.startMetering()
        RemoteShutter.shared.start(self)
        photosSync.onRemoved = { [weak self] n in
            self?.show("\(n) frame\(n == 1 ? "" : "s") left the roll because \(n == 1 ? "its photo was" : "their photos were") deleted in Photos. Restore in Settings ▸ Storage.")
        }
        updateSensors()
        photosSync.refresh()
        orientation.start()
        // Build the look tables in the background so the first frame on each stock develops quickly.
        let stocks = prefs.visibleStocks
        let expandSDR = camera.isSimulated
        Task.detached(priority: .background) { await Darkroom.shared.prewarm(stocks, expandSDR: expandSDR) }
    }

    func updateSensors() {
        let live = isActive && !viewfinderCovered
        if !live {
            // A self-timer shouldn't fire into a covered or backgrounded camera, and a long exposure keeps what it
            // has rather than failing when the app leaves the screen.
            if countdownTask != nil { countdownTask?.cancel(); countdownTask = nil; countdown = nil }
            if exposing != nil { camera.finishExposureEarly() }
        }
        camera.setRunning(live)
        location.setActive(live && prefs.saveLocation)
        if live, prefs.showLevel { level.start() } else { level.stop() }
    }

    // MARK: capture

    /// A long exposure in progress: how far through it is (0…1), and how long it is.
    private(set) var exposing: Double?
    private(set) var exposingSeconds: Double = 0

    /// Self-timer: 0 (off), 3 or 10 seconds.
    var timerSeconds = 0
    /// Seconds left on a running self-timer.
    private(set) var countdown: Int?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    /// The shutter: starts the self-timer when one is set (pressing again cancels it), otherwise shoots.
    /// `timer` overrides the self-timer for this press (the watch remote sends its own).
    func capture(timer: Int? = nil) {
        // During a long exposure the shutter is STOP: finish now, keeping what's exposed.
        if exposing != nil {
            camera.finishExposureEarly()
            Feedback.selection()
            return
        }
        let seconds = timer ?? timerSeconds
        if countdownTask != nil {
            countdownTask?.cancel(); countdownTask = nil; countdown = nil
            Feedback.selection()
            return
        }
        guard seconds > 0 else { fire(); return }
        countdownTask = Task {
            for left in stride(from: seconds, through: 1, by: -1) {
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
        guard camera.isReady, exposing == nil else { return }
        guard developingCount < maxPending else {
            show("Developing… one moment")
            return
        }
        shutterTick += 1
        Feedback.shutter()
        if prefs.panoMode { panoShot(); return }
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
        o.customStock = snapshot(of: stock)
        if prefs.highResolution && !prefs.zeroProcess { o.fullResolution = true }
        if prefs.lightLeak > 0 { o.lightLeak = prefs.lightLeak }
        if portrait { o.portraitLens = prefs.portraitLens; o.blurAmount = prefs.blurAmount }
        if prefs.dust { o.dust = true }
        if prefs.expired > 0.01 { o.expired = prefs.expired }
        o.scanner = prefs.scanner
        if prefs.crisp { o.crisp = true }
        return o
    }

    private func shoot(stock: FilmStock, saveToPhotos: Bool) async {
        let options = currentOptions(for: stock)
        let saveOriginal = prefs.saveOriginal
        let fix = prefs.saveLocation ? location.current : nil
        developingCount += 1
        defer { developingCount -= 1 }
        do {
            let shutter = portrait ? 0 : prefs.shutter      // portrait captures normally (as its notice says)
            let frame: CapturedFrame
            if shutter > camera.maxSingleExposure + 0.001 {
                // Longer than one frame can expose: stack frames for the whole time.
                exposingSeconds = shutter; exposing = 0
                do {
                    frame = try await camera.captureStack(seconds: shutter, trails: prefs.trails, location: fix) { p in
                        Task { @MainActor in if self.exposing != nil { self.exposing = p } }
                    }
                    exposing = nil
                } catch { exposing = nil; throw error }
            } else {
                frame = try await camera.capture(flash: flash, location: fix, shutter: shutter)
            }
            let started = Date()
            let result = try await Darkroom.shared.develop(frame, stock: stock, options: options)
            lastDevelopSeconds = Date().timeIntervalSince(started)
            await keep(result, stock: stock, original: saveOriginal ? frame.originalData : nil, location: fix, saveToPhotos: saveToPhotos)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Puts a developed frame on the roll (and in Photos).
    private func keep(_ result: DevelopResult, stock: FilmStock, original: Data?, location fix: CLLocation?, saveToPhotos: Bool) async {
        do {
            let item = try roll.add(result, stock: stock)
            lastDeveloped = item
            Feedback.advance()
            if prefs.bigReveal { reveal = item }
            guard saveToPhotos else { return }
            let recipe = (try? JSONEncoder().encode(result.options)) ?? Data()
            do {
                let id = try await PhotoLibrary.create(print: result.jpeg, original: original, recipe: recipe, location: fix, date: result.options.date)
                roll.setPhotosID(id, for: item)
            } catch {
                show("Saved on the roll, but not to Photos: \(error.localizedDescription)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: panorama

    /// Shots of a panorama in progress.
    struct PanoShots {
        var scenes: [CIImage] = []
        var ghost: UIImage?
        var sceneReferred = true
        var focal35: Double?
        var metadata: [String: Any] = [:]
        var location: CLLocation?
        var capturing = false
    }
    private(set) var pano: PanoShots?

    private func panoShot() {
        if pano == nil { pano = PanoShots() }
        guard pano?.capturing == false, (pano?.scenes.count ?? 0) < Panorama.maxFrames else { return }
        pano?.capturing = true
        let fix = prefs.saveLocation ? location.current : nil
        // Lock exposure, white balance and focus on what the first shot sees, before it's taken (the lock and the
        // capture run in order on the camera's queue), so every frame matches.
        let first = pano?.scenes.isEmpty == true
        if first { camera.lockForPanorama(true) }
        Task {
            do {
                let frame = try await camera.capture(flash: .off, location: fix)
                if first {
                    pano?.metadata = frame.metadata; pano?.location = fix
                    let exif = frame.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
                    pano?.focal35 = (exif?[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.doubleValue
                        ?? (camera.isSimulated ? nil : 26)
                }
                let (scene, referred) = try await Darkroom.shared.panoScene(of: frame)
                let ghost = await Darkroom.shared.panoGhost(scene).map { UIImage(cgImage: $0) }
                guard pano != nil else { return }          // cancelled meanwhile
                pano?.scenes.append(scene); pano?.sceneReferred = referred; pano?.ghost = ghost
                pano?.capturing = false
                Feedback.advance()
                if (pano?.scenes.count ?? 0) >= Panorama.maxFrames { finishPanorama() }
            } catch {
                if pano?.scenes.isEmpty == true {
                    // Nothing taken yet: leave panorama-in-progress (and its locks) rather than strand the camera.
                    pano = nil
                    camera.lockForPanorama(false)
                } else {
                    pano?.capturing = false
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Stitches and develops the panorama.
    func finishPanorama() {
        guard let shots = pano, shots.scenes.count >= 2, !shots.capturing else { return }
        pano?.capturing = true                     // stitching: shots stay until it works
        let stock = prefs.resolveStock()
        var options = currentOptions(for: stock)
        options.portraitLens = nil
        developingCount += 1
        Task {
            defer { developingCount -= 1 }
            do {
                let result = try await Darkroom.shared.developPanorama(shots.scenes, sceneReferred: shots.sceneReferred, focal35: shots.focal35,
                                                                       metadata: shots.metadata, stock: stock, options: options)
                pano = nil                         // releases the shots
                camera.lockForPanorama(false)
                await keep(result, stock: stock, original: nil, location: shots.location, saveToPhotos: prefs.saveToPhotos)
            } catch {
                // Keep every shot: take another (overlapping more) and tap DONE again, or CANCEL.
                pano?.capturing = false
                errorMessage = error.localizedDescription + "\n\nYour shots are kept: add another overlapping shot and tap DONE, or CANCEL."
            }
        }
    }

    func cancelPanorama() {
        pano = nil
        camera.lockForPanorama(false)
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

    /// Frames re-developed since their Photos copy was last updated.
    @ObservationIgnored private var photosPending = Set<String>()

    /// Brings the Photos copies of edited frames up to date in a single library change. `ids` nil: all of them.
    func flushPhotos(_ ids: Set<String>? = nil) {
        let due = ids.map { photosPending.intersection($0) } ?? photosPending
        guard !due.isEmpty else { return }
        photosPending.subtract(due)
        let edits: [PhotoLibrary.Edit] = due.compactMap { id in
            guard let item = roll.item(id: id), let pid = roll.photosID(for: item), let jpeg = try? Data(contentsOf: item.url) else { return nil }
            return PhotoLibrary.Edit(assetID: pid, print: jpeg, recipe: (try? JSONEncoder().encode(roll.recipe(for: item))) ?? Data())
        }
        Task {
            do {
                let missing = try await PhotoLibrary.applyEdits(edits)
                for pid in missing {
                    if let item = roll.items.first(where: { roll.photosID(for: $0) == pid }) { roll.setPhotosID(nil, for: item) }
                }
            } catch {
                show("Re-developed on the roll; couldn't update Photos: \(error.localizedDescription)")
            }
        }
    }

    /// The stock a frame was printed on (its saved copy for the user's own stocks); nil if that stock is gone.
    func stock(for item: RollItem) -> FilmStock? {
        DevelopOptions.resolveStock(stockID: item.stockID, recipe: roll.recipe(for: item))
    }

    /// A copy of `stock` to keep in a recipe, when it's one of the user's own.
    func snapshot(of stock: FilmStock) -> CustomStock? { prefs.customStocks.first { $0.id == stock.id } }

    /// Prints a frame's negative again: on another stock (`stock`), or on its own with an edit (push/pull,
    /// strength, framing, texture). The frame keeps its own settings unless the edit changes them.
    /// If the frame was saved to Photos, that copy is updated in place. Returns a status line.
    @discardableResult
    /// `syncPhotos: false` (editing): the Photos copy is updated later in one go by `flushPhotos`, not per tweak.
    func reprint(_ item: RollItem, stock newStock: FilmStock? = nil, syncPhotos: Bool = true,
                 edit: (inout DevelopOptions) -> Void = { _ in }) async throws -> String {
        var options = roll.recipe(for: item)
        let changing = newStock.map { $0.id != item.stockID } ?? false
        guard let stock = changing ? newStock : DevelopOptions.resolveStock(stockID: item.stockID, recipe: options) else {
            throw DarkroomError.missingStock
        }
        let negative = try Data(contentsOf: item.negativeURL)
        if changing { options.strength = prefs.strength(for: stock) }
        // Keep a copy of the user's own stock with the frame (also fills it in for frames from before copies).
        if changing || options.customStock == nil { options.customStock = snapshot(of: stock) }
        edit(&options)
        let metadata = JPEGEncoder.metadata(of: item.url)
        let depth = try? Data(contentsOf: item.depthURL)
        let jpeg = try await Darkroom.shared.redevelop(negative: negative, depth: depth, metadata: metadata, stock: stock, options: options)
        let updated = try roll.replace(item, stock: stock, jpeg: jpeg, options: options)
        if !syncPhotos {
            if roll.photosID(for: updated) != nil { photosPending.insert(updated.id) }
            return "Re-developed."
        }
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

    /// Double exposure of two roll frames, printed as a new frame on the first one's stock and settings.
    /// The print settings for a double exposure: the base frame's, freshly dated, with today's texture.
    func doubleExposureOptions(base: RollItem) -> DevelopOptions {
        var options = roll.recipe(for: base)
        options.date = Date()
        options.cropShift = nil; options.portraitLens = nil; options.pushPull = nil
        options.grainAmount = prefs.grainAmount; options.halation = prefs.halation; options.flareAmount = prefs.flareAmount
        return options
    }

    /// `a` is the base (its frame, stock and settings); `balance` 0…1 is how much of the light comes from `b`.
    func doubleExposure(_ a: RollItem, _ b: RollItem, balance: Double = 0.5) async throws -> RollItem {
        let na = try Data(contentsOf: a.negativeURL), nb = try Data(contentsOf: b.negativeURL)
        let ra = roll.recipe(for: a), rb = roll.recipe(for: b)
        guard let stock = stock(for: a) else { throw DarkroomError.missingStock }
        let options = doubleExposureOptions(base: a)
        let result = try await Darkroom.shared.doubleExposure(na, ra, nb, rb, balance: balance, stock: stock, options: options,
                                                             metadata: JPEGEncoder.metadata(of: a.url))
        let item = try roll.add(result, stock: stock)
        lastDeveloped = item
        if prefs.saveToPhotos {
            let recipe = (try? JSONEncoder().encode(result.options)) ?? Data()
            if let id = try? await PhotoLibrary.create(print: result.jpeg, original: nil, recipe: recipe, location: nil, date: options.date) {
                roll.setPhotosID(id, for: item)
            }
        }
        return item
    }

    /// A contact sheet of frames in shooting order (up to 36), written to a temporary JPEG.
    func contactSheet(_ items: [RollItem], name: String? = nil, progress: (Int, Int) -> Void) async throws -> URL {
        let ordered = Array(items.sorted { $0.date < $1.date }.prefix(ContactSheet.maxFrames))
        var frames: [ContactSheet.Frame] = []
        for (i, item) in ordered.enumerated() {
            progress(i + 1, ordered.count)
            // A frame whose stock is gone shows its existing print rather than being re-printed on another stock.
            let stock = self.stock(for: item)
            var image: CGImage?, mark: CGRect?
            if let stock, item.hasNegative, let neg = try? Data(contentsOf: item.negativeURL),
               let made = try? await Darkroom.shared.contactFrame(negative: neg, recipe: roll.recipe(for: item), stock: stock, maxPixel: 900) {
                (image, mark) = made
            }
            if image == nil { image = await roll.thumbnail(for: item, maxPixel: 900)?.cgImage }
            if let image { frames.append(.init(image: image, number: i + 1, stock: stock?.displayName ?? "", mark: mark)) }
        }
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"
        let days = Set(ordered.map { f.string(from: $0.date) })
        let title = "LATENT   " + (name.map { $0.uppercased() + "   " } ?? "") + (days.count == 1 ? days.first! : "\(f.string(from: ordered.first!.date)) – \(f.string(from: ordered.last!.date))")
            + "   \(frames.count) FRAMES"
        let seed = UInt64(abs(ordered.first!.date.timeIntervalSince1970))
        let jpeg: Data = try await Task.detached(priority: .userInitiated) {
            guard let cg = ContactSheet.render(frames, title: title, seed: seed) else { throw DarkroomError.render }
            return try JPEGEncoder.encode(cg, metadata: [:])
        }.value
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Latent contact sheet \(f.string(from: Date())).jpg")
        try jpeg.write(to: url, options: .atomic)
        return url
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
        // `-demoPanoUI`: PANO mode with one shot taken. `-demoPano`: three overlapping crops of the test scene,
        // stitched and developed (written to Documents/DemoOut/pano.jpg).
        if args.contains("-demoPanoUI") {
            prefs.panoMode = true
            panoShot()
            return
        }
        if args.contains("-demoPano") {
            let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoOut")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let scene = SimulatedScene.capture, e = scene.extent
            let w = (e.width * 0.5).rounded(), step = (e.width * 0.25).rounded()
            let strips = (0..<3).map { scene.cropped(to: CGRect(x: e.minX + CGFloat($0) * step, y: e.minY, width: w, height: e.height)) }
            do {
                let result = try await Darkroom.shared.developPanorama(strips, sceneReferred: false, focal35: nil, metadata: [:],
                                                                       stock: .honey, options: currentOptions(for: .honey))
                try result.jpeg.write(to: out.appendingPathComponent("pano.jpg"))
            } catch {
                try? "\(error)".write(to: out.appendingPathComponent("pano-error.txt"), atomically: true, encoding: .utf8)
            }
            return
        }
        // `-demoSheet` / `-demoDouble`: a contact sheet of the roll and a double exposure of its two newest frames,
        // written to Documents/DemoOut.
        if args.contains("-demoSheet") || args.contains("-demoDouble") {
            let out = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoOut")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var log = "items \(roll.items.count)\n"
            let keepSaving = prefs.saveToPhotos
            prefs.saveToPhotos = false            // the simulator's Photos prompt would block
            defer { prefs.saveToPhotos = keepSaving }
            if args.contains("-demoDouble"), roll.items.count >= 2 {
                do {
                    let item = try await doubleExposure(roll.items[1], roll.items[0])
                    try FileManager.default.copyItem(at: item.url, to: out.appendingPathComponent("double.jpg"))
                } catch { log += "double: \(error)\n" }
            }
            if args.contains("-demoSheet") {
                do {
                    let url = try await contactSheet(roll.items, progress: { _, _ in })
                    try? FileManager.default.removeItem(at: out.appendingPathComponent("sheet.jpg"))
                    try FileManager.default.copyItem(at: url, to: out.appendingPathComponent("sheet.jpg"))
                } catch { log += "sheet: \(error)\n" }
            }
            try? log.write(to: out.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            return
        }
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
