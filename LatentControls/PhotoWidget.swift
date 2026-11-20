import AppIntents
import ImageIO
import SwiftUI
import WidgetKit

/// What the photo widget shows.
enum PhotoChoice: String, AppEnum {
    case shuffle, latest

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Photo"
    static let caseDisplayRepresentations: [PhotoChoice: DisplayRepresentation] = [
        .shuffle: "A different photo every few hours",
        .latest: "Your latest photo",
    ]
}

struct PhotoWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Latent Photo"
    static let description = IntentDescription("A photo from your Latent roll.")

    @Parameter(title: "Show", default: .shuffle)
    var choice: PhotoChoice
}

struct PhotoEntry: TimelineEntry {
    let date: Date
    var image: UIImage?
    var stock = ""
    var taken: Date?
    var isPlaceholder = false
}

struct PhotoProvider: AppIntentTimelineProvider {
    /// How long each shuffled photo stays up.
    private static let interval: TimeInterval = 2 * 3600

    func placeholder(in context: Context) -> PhotoEntry { PhotoEntry(date: .now, isPlaceholder: true) }

    func snapshot(for configuration: PhotoWidgetIntent, in context: Context) async -> PhotoEntry {
        let feed = WidgetFeed.read()
        guard let pick = configuration.choice == .latest ? feed.first : preferred(feed, for: context.family).randomElement()
        else { return PhotoEntry(date: .now) }
        return entry(pick, at: .now, context: context)
    }

    func timeline(for configuration: PhotoWidgetIntent, in context: Context) async -> Timeline<PhotoEntry> {
        let feed = WidgetFeed.read()
        guard !feed.isEmpty else { return Timeline(entries: [PhotoEntry(date: .now)], policy: .never) }
        if configuration.choice == .latest {
            // The app reloads the widget whenever the roll changes.
            return Timeline(entries: [entry(feed[0], at: .now, context: context)], policy: .never)
        }
        // A handful of different frames, a couple of hours apart, then shuffle again.
        let picks = Array(preferred(feed, for: context.family).shuffled().prefix(6))
        let entries = picks.enumerated().map { i, pick in
            entry(pick, at: Date.now.addingTimeInterval(Double(i) * Self.interval), context: context)
        }
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// The wide widget looks best with landscape frames, if there are enough of them.
    private func preferred(_ feed: [WidgetFeed.Entry], for family: WidgetFamily) -> [WidgetFeed.Entry] {
        guard family == .systemMedium else { return feed }
        let wide = feed.filter(\.landscape)
        return wide.count >= 3 ? wide : feed
    }

    private func entry(_ pick: WidgetFeed.Entry, at date: Date, context: Context) -> PhotoEntry {
        PhotoEntry(date: date, image: load(pick.file, for: context), stock: pick.stock, taken: pick.date)
    }

    /// Decodes just big enough for the widget, to stay inside the extension's memory budget.
    private func load(_ file: String, for context: Context) -> UIImage? {
        guard let url = WidgetFeed.folder?.appendingPathComponent(file),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let side = max(context.displaySize.width, context.displaySize.height) * 2.5
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(side, 300), WidgetFeed.pixelSize),
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

struct PhotoWidgetView: View {
    let entry: PhotoEntry
    @Environment(\.widgetFamily) private var family

    private static let amber = Color(red: 1, green: 0.66, blue: 0.24)

    var body: some View {
        Group {
            if entry.image != nil || entry.isPlaceholder {
                label
            } else {
                empty
            }
        }
        .containerBackground(for: .widget) {
            if let image = entry.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(white: 0.07)
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Spacer()
            if !entry.stock.isEmpty {
                Text(entry.stock.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Self.amber)
            }
            if family != .systemSmall, let taken = entry.taken {
                Text(taken.formatted(.dateTime.day().month(.abbreviated).year()))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 3)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.aperture").font(.system(size: 26)).foregroundStyle(Self.amber)
            Text("Take a photo with Latent")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
        }
    }
}

struct PhotoWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetFeed.kind, intent: PhotoWidgetIntent.self, provider: PhotoProvider()) { entry in
            PhotoWidgetView(entry: entry)
        }
        .configurationDisplayName("Latent Photo")
        .description("A photo from your roll: shuffled every few hours, or your latest.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}
