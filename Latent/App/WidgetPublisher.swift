import Foundation
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Keeps the photo widget's feed in step with the roll: writes small copies of the newest prints into the App
/// Group, drops ones no longer needed, and asks the widget to refresh.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()
    private var pending: Task<Void, Never>?

    private struct Source: Sendable { let url: URL; let base: String; let stock: String; let date: Date }

    /// Debounced, so a burst of shots or an import publishes once.
    func publish(_ items: [RollItem]) {
        let sources = items.prefix(WidgetFeed.limit).map {
            Source(url: $0.url, base: $0.base, stock: $0.stock?.displayName ?? "", date: $0.date)
        }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let changed = await Task.detached(priority: .utility) { Self.write(sources) }.value
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetFeed.kind) }
        }
    }

    /// Returns whether the index changed.
    nonisolated private static func write(_ sources: [Source]) -> Bool {
        guard let folder = WidgetFeed.folder else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = Dictionary(WidgetFeed.read().map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [WidgetFeed.Entry] = []
        for s in sources {
            // Name by the print's modification time so a re-developed frame gets a fresh copy.
            let modified = (try? s.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? s.date
            let file = "\(s.base)-\(Int64(modified.timeIntervalSince1970)).jpg"
            let dest = folder.appendingPathComponent(file)
            var landscape = true
            if fm.fileExists(atPath: dest.path) {
                landscape = previous[file]?.landscape ?? Self.isLandscape(dest)
            } else {
                guard let src = CGImageSourceCreateWithURL(s.url as CFURL, nil),
                      let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: WidgetFeed.pixelSize,
                      ] as CFDictionary),
                      let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(out, thumb, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(out) else { continue }
                landscape = thumb.width >= thumb.height
            }
            entries.append(.init(file: file, stock: s.stock, date: s.date, landscape: landscape))
        }
        // Remove copies that fell off the end or were replaced.
        let keep = Set(entries.map(\.file) + ["index.json"])
        for f in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where !keep.contains(f) {
            try? fm.removeItem(at: folder.appendingPathComponent(f))
        }
        guard entries != WidgetFeed.read(), let url = WidgetFeed.indexURL,
              let data = try? JSONEncoder().encode(entries) else { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }

    nonisolated private static func isLandscape(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return true }
        return w >= h
    }
}
