import SwiftUI

@main
struct LatentApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.amber)
        }
    }
}

enum Theme {
    static let amber = Color(red: 0.95, green: 0.64, blue: 0.23)
    static let body = Color(red: 0.06, green: 0.06, blue: 0.065)
    static let panel = Color(white: 0.11)
    static let label = Color(white: 0.85)
    static let dim = Color(white: 0.45)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
