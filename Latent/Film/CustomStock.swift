import Foundation

/// A stock you made: a built-in stock plus your adjustments. Stored in Preferences as JSON.
struct CustomStock: Codable, Identifiable, Equatable {
    var id = "custom-" + UUID().uuidString.prefix(8).lowercased()
    var name = "My Stock"
    var iso = 400
    var baseID = FilmStock.honey.id

    // Adjustments, each 0 = unchanged (multipliers: 1 = unchanged).
    var brightness = 0.0    // -1…1
    var warmth = 0.0        // -1…1
    var tint = 0.0          // -1 green … +1 magenta
    var contrast = 0.0      // -1…1
    var fade = 0.0          // 0…1  lifts the blacks
    var saturation = 0.0    // -1…1
    var grain = 1.0         // 0…2
    var halation = 1.0      // 0…2
    var glow = 0.0          // -1…1 bloom
    var softness = 0.0      // -1…1
    var vignette = 0.0      // -1…1

    var base: FilmStock { FilmStock.builtIn(id: baseID) ?? .honey }

    /// The finished stock the darkroom prints with.
    var stock: FilmStock {
        var s = base
        s.id = id; s.name = name.isEmpty ? "Untitled" : name; s.iso = iso
        s.blurb = "Your stock, based on \(base.displayName)."
        s.exposureBias += brightness * 0.7
        s.temperature += warmth * 0.6
        s.tint += tint * 0.5
        s.contrast *= 1 + contrast * 0.4
        s.black += RGB(repeating: fade * 0.09)
        s.white -= RGB(repeating: fade * 0.03)
        s.saturation = max(0, s.saturation * (1 + saturation * 0.6))
        s.grain *= grain
        s.halation *= halation
        s.bloom = max(0, s.bloom + glow * 0.45)
        s.softness = max(0, s.softness + softness * 0.4)
        s.vignette = max(0, s.vignette + vignette * 0.4)
        return s
    }

    /// "Surprise me": a random but sensible starting point.
    static func random(keeping id: String, name: String) -> CustomStock {
        var c = CustomStock()
        c.id = id; c.name = name
        let bases = FilmStock.all.filter { !$0.isMonochrome }
        c.baseID = (Double.random(in: 0...1) < 0.15 ? FilmStock.all.filter(\.isMonochrome) : bases).randomElement()!.id
        c.iso = [100, 160, 200, 400, 800, 1600].randomElement()!
        c.brightness = .random(in: -0.3...0.3); c.warmth = .random(in: -0.6...0.6); c.tint = .random(in: -0.3...0.3)
        c.contrast = .random(in: -0.5...0.5); c.fade = .random(in: 0...0.5); c.saturation = .random(in: -0.5...0.4)
        c.grain = .random(in: 0.5...1.6); c.halation = .random(in: 0.4...1.6); c.glow = .random(in: -0.4...0.6)
        c.softness = .random(in: -0.4...0.5); c.vignette = .random(in: -0.4...0.6)
        return c
    }
}

/// Lets `FilmStock.with(id:)` find custom stocks from anywhere (the darkroom, the roll, previews).
enum StockRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stocks: [String: FilmStock] = [:]
    nonisolated(unsafe) private static var order: [String] = []

    static func set(_ customs: [CustomStock]) {
        lock.lock(); defer { lock.unlock() }
        stocks = Dictionary(uniqueKeysWithValues: customs.map { ($0.id, $0.stock) })
        order = customs.map(\.id)
    }

    static var customs: [FilmStock] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { stocks[$0] }
    }

    static func stock(id: String) -> FilmStock? {
        lock.lock(); defer { lock.unlock() }
        return stocks[id]
    }
}
