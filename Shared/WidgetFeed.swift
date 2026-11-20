import Foundation

/// The photo widget's view of the roll: small copies of recent prints plus an index, kept by the app in the
/// shared App Group container and read by the widget extension.
enum WidgetFeed {
    static let group = "group.dev.latentcam.app11da0f"
    static let kind = "dev.latentcam.photo"
    /// How many recent frames the widget can choose from.
    static let limit = 60
    /// Long edge of the stored copies; plenty for the large widget at 3×.
    static let pixelSize: CGFloat = 1000

    struct Entry: Codable, Hashable {
        let file: String
        let stock: String
        let date: Date
        let landscape: Bool
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Widget", isDirectory: true)
    }

    static var indexURL: URL? { folder?.appendingPathComponent("index.json") }

    /// Newest first.
    static func read() -> [Entry] {
        guard let url = indexURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }
}
