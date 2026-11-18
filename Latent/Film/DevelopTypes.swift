import CoreImage
import CoreLocation
import ImageIO
import UIKit

enum AspectRatio: String, CaseIterable, Identifiable, Codable {
    case r3x2 = "3:2", r4x3 = "4:3", r1x1 = "1:1", r16x9 = "16:9", pano = "65:24"
    var id: String { rawValue }
    var label: String { self == .pano ? "PANO" : rawValue }
    /// Long side divided by short side.
    var longOverShort: CGFloat {
        switch self {
        case .r3x2: 3.0 / 2.0
        case .r4x3: 4.0 / 3.0
        case .r1x1: 1
        case .r16x9: 16.0 / 9.0
        case .pano: 65.0 / 24.0
        }
    }
    var next: AspectRatio {
        let all = Self.allCases; return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum FrameStyle: String, CaseIterable, Identifiable, Codable {
    case none, white, black
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Everything about how a frame is printed except the stock. Saved beside each negative so it can be re-developed.
struct DevelopOptions: Codable {
    var exposure: Double = 0        // extra EV applied in post (simulator only; device uses the sensor)
    var aspect: AspectRatio? = .r3x2      // nil keeps the full frame (imports)
    var grainAmount: Double = 1     // user multiplier 0…2
    var halation = true
    var flare = true                // legacy on/off (older recipes)
    var flareAmount: Double? = nil  // 0 = off, 1 = full strength; nil = use `flare`
    var flareStrength: Double { flareAmount ?? (flare ? 1 : 0) }
    var dateStamp = false
    var frame: FrameStyle = .none
    var date = Date()
    /// True when the source was a RAW decode (real highlight data above 1.0).
    var sceneReferred = false
    /// Development push (+) or pull (−) in stops, chosen after the fact.
    var pushPull: Double? = nil
    /// How strongly the stock's look is applied: 0 = neutral print, 1 = full look.
    var strength: Double? = nil
    /// The camera's flash fired for this frame.
    var flashFired: Bool? = nil
    /// How the negative file is encoded (see `NegativeCodec`); nil = the original 1/8-exposure format.
    var negativeFormat: Int? = nil
}

enum FrameSource {
    case raw(Data, hint: String? = nil)   // ProRAW DNG or a camera RAW; `hint` is its type (e.g. com.nikon.raw-image)
    case processed(Data)    // HEIC/JPEG from the camera pipeline
    case image(CIImage, sceneReferred: Bool = false)   // simulator test scene / test input
}

struct CapturedFrame {
    let source: FrameSource
    private let captureMetadata: [String: Any]
    let flashFired: Bool
    let location: CLLocation?

    init(source: FrameSource, metadata: [String: Any], flashFired: Bool = false, location: CLLocation? = nil) {
        self.source = source
        self.captureMetadata = metadata
        self.flashFired = flashFired
        self.location = location
    }

    /// Capture metadata, plus GPS when location tagging is on.
    var metadata: [String: Any] {
        var m = captureMetadata
        if let location, m[kCGImagePropertyGPSDictionary as String] == nil {
            m[kCGImagePropertyGPSDictionary as String] = location.exifGPS
        }
        return m
    }

    var originalData: Data? {
        switch source {
        case .raw(let d, _), .processed(let d): d
        case .image: nil
        }
    }
}

struct DevelopResult {
    let jpeg: Data
    let negative: Data
    let options: DevelopOptions
}

enum DarkroomError: LocalizedError {
    case decode, render, encode
    var errorDescription: String? {
        switch self {
        case .decode: "Couldn't read the photo."
        case .render: "Couldn't develop the photo."
        case .encode: "Couldn't save the photo."
        }
    }
}
