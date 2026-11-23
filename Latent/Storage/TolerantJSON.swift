import Foundation

/// Reads saved JSON so that a setting missing from an older file (or one written before a new setting existed)
/// takes its default instead of making the whole file unreadable. Swift's synthesized decoding rejects a missing
/// key even when the property has a default; laying the stored keys over a freshly encoded default fixes that.
enum TolerantJSON {
    static func decode<T: Codable>(_ type: T.Type, from data: Data, defaults: T,
                                   nested: [String: (Any) -> Any] = [:]) throws -> T {
        guard var stored = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try JSONDecoder().decode(T.self, from: data)
        }
        for (key, fill) in nested { if let value = stored[key] { stored[key] = fill(value) } }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults)) as? [String: Any] ?? [:]
        let merged = base.merging(stored) { _, new in new }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    /// Lays a stored object over defaults (for objects nested inside another file).
    static func filled<T: Codable>(_ value: Any, defaults: T) -> Any {
        guard let stored = value as? [String: Any],
              let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))) as? [String: Any] else { return value }
        return base.merging(stored) { _, new in new }
    }
}

extension CustomStock {
    static func tolerant(from data: Data) throws -> CustomStock {
        try TolerantJSON.decode(CustomStock.self, from: data, defaults: CustomStock())
    }

    /// A list of stocks, each read tolerantly.
    static func tolerantList(from data: Data) throws -> [CustomStock] {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return try array.map { item in
            let filled = TolerantJSON.filled(item, defaults: CustomStock())
            return try JSONDecoder().decode(CustomStock.self, from: JSONSerialization.data(withJSONObject: filled))
        }
    }
}

extension DevelopOptions {
    static func tolerant(from data: Data, defaults: DevelopOptions) throws -> DevelopOptions {
        try TolerantJSON.decode(DevelopOptions.self, from: data, defaults: defaults,
                                nested: ["customStock": { TolerantJSON.filled($0, defaults: CustomStock()) }])
    }
}
