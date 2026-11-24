import CoreLocation
import Foundation
import ImageIO
import Photos
import UIKit

/// One frame on the roll. Files in Documents/Roll, sharing the base name (capture time in ms):
///   <base>_<stockID>.jpg   the developed print
///   <base>.neg.heic        the negative (neutral scene, 10-bit) for re-developing
///   <base>.recipe.json     DevelopOptions used for the print
struct RollItem: Identifiable, Hashable {
    let base: String
    let stockID: String
    let date: Date
    let folder: URL
    /// When the current print was made; changes on every re-develop so views and caches refresh.
    var stamp: TimeInterval = 0

    var id: String { base }
    var url: URL { folder.appendingPathComponent("\(base)_\(stockID).jpg") }
    var negativeURL: URL { folder.appendingPathComponent("\(base).neg.heic") }
    var recipeURL: URL { folder.appendingPathComponent("\(base).recipe.json") }
    var photosURL: URL { folder.appendingPathComponent("\(base).photos") }
    /// Present while the Photos copy is behind the roll's print (an edit not yet sent to Photos).
    var photosStaleURL: URL { folder.appendingPathComponent("\(base).photos-stale") }
    var depthURL: URL { folder.appendingPathComponent("\(base).depth.png") }
    var hasDepth: Bool { FileManager.default.fileExists(atPath: depthURL.path) }
    var stock: FilmStock? { FilmStock.with(id: stockID) }
    var hasNegative: Bool { FileManager.default.fileExists(atPath: negativeURL.path) }
}

@Observable
final class RollStore {
    private(set) var items: [RollItem] = []
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let thumbs = NSCache<NSString, UIImage>()

    init(folder custom: URL? = nil) {
        folder = custom ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Roll", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        items = files.compactMap(parse).sorted { $0.date > $1.date }
    }

    func item(id: String) -> RollItem? { items.first { $0.id == id } }

    /// Where the roll's files live (for export / import).
    var folderURL: URL { folder }

    /// Adds a developed frame. `filedAt` sets its place on the roll (defaults to the capture time).
    @discardableResult
    func add(_ result: DevelopResult, stock: FilmStock, filedAt: Date? = nil) throws -> RollItem {
        var when = filedAt ?? result.options.date
        var base = String(Int64(when.timeIntervalSince1970 * 1000))
        while items.contains(where: { $0.base == base }) {          // never overwrite an existing frame
            when = when.addingTimeInterval(0.001); base = String(Int64(when.timeIntervalSince1970 * 1000))
        }
        let item = RollItem(base: base, stockID: stock.id, date: when, folder: folder)
        try result.jpeg.write(to: item.url, options: .atomic)
        try result.negative.write(to: item.negativeURL, options: .atomic)
        try JSONEncoder().encode(result.options).write(to: item.recipeURL, options: .atomic)
        if let depth = result.depth { try depth.write(to: item.depthURL, options: .atomic) }
        items.insert(item, at: 0)
        return item
    }

    enum Failure: LocalizedError {
        case gone, unreadableRecipe
        var errorDescription: String? {
            switch self {
            case .gone: "That frame is no longer on the roll."
            case .unreadableRecipe: "This frame's settings couldn't be read, so it wasn't changed."
            }
        }
    }

    /// The recipe for re-developing: throws rather than handing back defaults when the file exists but can't be
    /// read, so a re-develop can never overwrite a frame's real settings with blank ones.
    func readRecipe(for item: RollItem) throws -> DevelopOptions {
        guard let data = try? Data(contentsOf: item.recipeURL) else { return DevelopOptions(date: item.date) }   // very old frames
        do { return try DevelopOptions.tolerant(from: data, defaults: DevelopOptions(date: item.date)) } catch { throw Failure.unreadableRecipe }
    }

    /// The recipe for display (defaults if it can't be read).
    func recipe(for item: RollItem) -> DevelopOptions {
        guard let data = try? Data(contentsOf: item.recipeURL),
              let r = try? DevelopOptions.tolerant(from: data, defaults: DevelopOptions(date: item.date)) else {
            return DevelopOptions(date: item.date)
        }
        return r
    }

    /// Swaps in a re-developed print on a new stock.
    @discardableResult
    func replace(_ item: RollItem, stock: FilmStock, jpeg: Data, options: DevelopOptions) throws -> RollItem {
        // Deleted (or moved to Removed with Photos) while developing: don't write it back.
        guard items.contains(where: { $0.id == item.id }) else { throw Failure.gone }
        let updated = RollItem(base: item.base, stockID: stock.id, date: item.date, folder: folder,
                               stamp: Date().timeIntervalSince1970)
        try jpeg.write(to: updated.url, options: .atomic)
        try JSONEncoder().encode(options).write(to: updated.recipeURL, options: .atomic)
        // Exactly one print per frame: remove any other "<base>_<stock>.jpg" (an older stock's print).
        for f in files(of: item.base, in: folder) where f.pathExtension == "jpg" && f != updated.url {
            try? FileManager.default.removeItem(at: f)
        }
        purgeThumbs(item)
        purgeThumbs(updated)
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = updated }
        return updated
    }

    func delete(_ item: RollItem) {
        for url in [item.url, item.negativeURL, item.recipeURL, item.photosURL, item.depthURL, item.photosStaleURL] {
            try? FileManager.default.removeItem(at: url)
        }
        purgeThumbs(item)
        items.removeAll { $0.id == item.id }
    }

    /// The Photos asset this frame was saved as, if any.
    func photosID(for item: RollItem) -> String? {
        (try? String(contentsOf: item.photosURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marks a frame's Photos copy as behind (kept on disk, so it survives the app closing).
    func markPhotosStale(_ item: RollItem) { try? Data().write(to: item.photosStaleURL) }
    func clearPhotosStale(_ item: RollItem) { try? FileManager.default.removeItem(at: item.photosStaleURL) }
    /// Frames whose Photos copy needs updating.
    func photosStaleItems() -> [RollItem] {
        items.filter { FileManager.default.fileExists(atPath: $0.photosStaleURL.path) }
    }

    func setPhotosID(_ id: String?, for item: RollItem) {
        if let id { try? id.write(to: item.photosURL, atomically: true, encoding: .utf8) }
        else { try? FileManager.default.removeItem(at: item.photosURL) }
    }

    // MARK: trash (frames whose Photos copy was deleted)

    /// Frames removed because their Photos copy was deleted wait here 30 days, like Photos' Recently Deleted,
    /// and come back if the photo is restored there.
    @ObservationIgnored private lazy var trashFolder: URL = {
        let url = folder.deletingLastPathComponent().appendingPathComponent("RollTrash", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func files(of base: String, in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(base + "_") || $0.lastPathComponent.hasPrefix(base + ".") }
    }

    /// Moves a frame (print, negative, recipe, depth, Photos link) into the trash.
    func trash(_ item: RollItem) {
        let fm = FileManager.default
        for f in files(of: item.base, in: folder) {
            let dest = trashFolder.appendingPathComponent(f.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.moveItem(at: f, to: dest)
        }
        try? ISO8601DateFormatter().string(from: Date())
            .write(to: trashFolder.appendingPathComponent("\(item.base).trashed"), atomically: true, encoding: .utf8)
        purgeThumbs(item)
        items.removeAll { $0.id == item.id }
    }

    /// Trashed frames and the Photos asset each was linked to.
    func trashedPhotoLinks() -> [(base: String, photosID: String)] {
        ((try? FileManager.default.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "photos" }
            .compactMap { url in
                guard let id = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty else { return nil }
                return (url.deletingPathExtension().lastPathComponent, id)
            }
    }

    /// Puts a trashed frame back on the roll.
    func restore(base: String) {
        let fm = FileManager.default
        for f in files(of: base, in: trashFolder) where f.pathExtension != "trashed" {
            try? fm.moveItem(at: f, to: folder.appendingPathComponent(f.lastPathComponent))
        }
        try? fm.removeItem(at: trashFolder.appendingPathComponent("\(base).trashed"))
        reload()
    }

    /// Frames in the trash (newest first) and when each was removed, for the "Removed with Photos" list.
    func trashedFrames() -> [(item: RollItem, removed: Date?)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> (RollItem, Date?)? in
            guard let item = parse(url, in: trashFolder) else { return nil }
            let marker = trashFolder.appendingPathComponent("\(item.base).trashed")
            let when = (try? String(contentsOf: marker, encoding: .utf8)).flatMap {
                ISO8601DateFormatter().date(from: $0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (item, when)
        }
        .sorted { $0.0.date > $1.0.date }
    }

    /// Permanently deletes one trashed frame (only ever on the user's request).
    func deleteFromTrash(base: String) {
        for f in files(of: base, in: trashFolder) { try? FileManager.default.removeItem(at: f) }
    }

    /// Deletes frames that have been in the trash longer than `days`.
    func purgeTrash(olderThan days: Double = 30) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let markers = ((try? fm.contentsOfDirectory(at: trashFolder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "trashed" }
        for m in markers {
            guard let text = try? String(contentsOf: m, encoding: .utf8),
                  let when = ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  when < cutoff else { continue }
            let base = m.deletingPathExtension().lastPathComponent
            for f in files(of: base, in: trashFolder) { try? fm.removeItem(at: f) }
        }
    }

    // MARK: storage

    struct Usage { var prints: Int64 = 0; var negatives: Int64 = 0; var negativeCount = 0 }

    func usage() -> Usage {
        var u = Usage()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for f in files {
            let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if f.lastPathComponent.hasSuffix(".neg.heic") { u.negatives += size; u.negativeCount += 1 }
            else if f.pathExtension == "jpg" { u.prints += size }
        }
        return u
    }

    /// Deletes negatives (frames stay, but can no longer be re-developed). `olderThan` limits it to older frames.
    func discardNegatives(olderThan days: Int? = nil) {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        for item in items where cutoff == nil || item.date < cutoff! {
            try? FileManager.default.removeItem(at: item.negativeURL)
        }
        items = items   // refresh hasNegative in views
    }

    func thumbnail(for item: RollItem, maxPixel: Int = 400) async -> UIImage? {
        let key = "\(item.url.lastPathComponent)-\(item.stamp)-\(maxPixel)" as NSString
        if let hit = thumbs.object(forKey: key) { return hit }
        let url = item.url
        let image = await Task.detached(priority: .utility) { Self.downsample(url, maxPixel: maxPixel) }.value
        if let image { thumbs.setObject(image, forKey: key) }
        return image
    }

    private func purgeThumbs(_ item: RollItem) {
        for px in [200, 400, 2000, 2400] { thumbs.removeObject(forKey: "\(item.url.lastPathComponent)-\(item.stamp)-\(px)" as NSString) }
    }

    static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func parse(_ url: URL) -> RollItem? { parse(url, in: folder) }

    private func parse(_ url: URL, in dir: URL) -> RollItem? {
        guard url.pathExtension == "jpg" else { return nil }
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let ms = Double(parts[0]) else { return nil }
        return RollItem(base: String(parts[0]), stockID: String(parts[1]), date: Date(timeIntervalSince1970: ms / 1000), folder: dir)
    }
}

/// Saving to Photos. Each roll frame maps to one Photos asset, which is edited in place when re-developed.
/// When the original (RAW/HEIC) is kept, it is the asset's base image and the print is a Photos edit on top,
/// so Photos ▸ Edit ▸ Revert brings the original back.
enum PhotoLibrary {
    static let formatID = "dev.latentcam.develop"

    enum Failure: LocalizedError {
        case denied, missing
        var errorDescription: String? {
            switch self {
            case .denied: "Allow Latent to access Photos in Settings to save there."
            case .missing: "The photo is no longer in your library."
            }
        }
    }

    static func authorize() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { throw Failure.denied }
    }

    /// Deletes these assets from the library (they go to Photos' Recently Deleted, after iOS asks the user).
    /// Returns how many were found; throws if the user says no.
    @discardableResult
    static func delete(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let fetch = PHFetchOptions(); fetch.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: fetch)
        guard assets.count > 0 else { return 0 }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets) }
        return assets.count
    }

    /// Adds a new asset and returns its local identifier.
    static func create(print: Data, original: Data?, recipe: Data, location: CLLocation?, date: Date) async throws -> String {
        try await authorize()
        var placeholder: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: original ?? print, options: nil)
            req.creationDate = date
            req.location = location
            placeholder = req.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = placeholder else { throw Failure.missing }
        if original != nil { try await applyEdit(id: id, print: print, recipe: recipe) }
        return id
    }

    /// Replaces the asset's current look with a new print (keeps the original underneath).
    static func applyEdit(id: String, print: Data, recipe: Data) async throws {
        try await authorize()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { throw Failure.missing }
        let input: PHContentEditingInput = try await withCheckedThrowingContinuation { cont in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { $0.formatIdentifier == formatID }
            asset.requestContentEditingInput(with: options) { input, info in
                if let input { cont.resume(returning: input) }
                else { cont.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? Failure.missing) }
            }
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: formatID, formatVersion: "1", data: recipe)
        try print.write(to: output.renderedContentURL, options: .atomic)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }
    }

    struct Edit { let assetID: String; let print: Data; let recipe: Data }

    /// Applies several prints to their Photos assets in one library change (one write, one iCloud sync) instead of
    /// one per frame. One asset failing to prepare (say, an iCloud download) doesn't sink the rest: it's simply not
    /// in `done`, so the caller tries it again later. `missing`: assets no longer in the library.
    static func applyEdits(_ edits: [Edit]) async throws -> (done: [String], missing: [String]) {
        guard !edits.isEmpty else { return ([], []) }
        try await authorize()
        var missing: [String] = []
        var prepared: [(PHAsset, PHContentEditingOutput, String)] = []
        let fetch = PHFetchOptions(); fetch.includeHiddenAssets = true
        for e in edits {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [e.assetID], options: fetch).firstObject else {
                missing.append(e.assetID); continue
            }
            let input: PHContentEditingInput? = try? await withCheckedThrowingContinuation { cont in
                let options = PHContentEditingInputRequestOptions()
                options.isNetworkAccessAllowed = true
                options.canHandleAdjustmentData = { $0.formatIdentifier == formatID }
                asset.requestContentEditingInput(with: options) { input, info in
                    if let input { cont.resume(returning: input) }
                    else { cont.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? Failure.missing) }
                }
            }
            guard let input else { continue }
            let output = PHContentEditingOutput(contentEditingInput: input)
            output.adjustmentData = PHAdjustmentData(formatIdentifier: formatID, formatVersion: "1", data: e.recipe)
            guard (try? e.print.write(to: output.renderedContentURL, options: .atomic)) != nil else { continue }
            prepared.append((asset, output, e.assetID))
        }
        guard !prepared.isEmpty else { return ([], missing) }
        try await PHPhotoLibrary.shared().performChanges {
            for (asset, output, _) in prepared { PHAssetChangeRequest(for: asset).contentEditingOutput = output }
        }
        return (prepared.map(\.2), missing)
    }

    static func exists(_ id: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil
    }
}
