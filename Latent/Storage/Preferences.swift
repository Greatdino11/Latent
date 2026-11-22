import Foundation

/// User settings, persisted to UserDefaults.
@Observable
final class Preferences {
    @ObservationIgnored private let d = UserDefaults.standard

    var selectedStockID: String { didSet { d.set(selectedStockID, forKey: "selectedStock") } }
    var aspect: AspectRatio { didSet { d.set(aspect.rawValue, forKey: "aspect") } }
    var grainAmount: Double { didSet { d.set(grainAmount, forKey: "grain") } }
    var halation: Bool { didSet { d.set(halation, forKey: "halation") } }
    /// Lens flare strength: 0 off … 1 full … 1.5 strong.
    var flareAmount: Double { didSet { d.set(flareAmount, forKey: "flareAmount") } }
    var dateStamp: Bool { didSet { d.set(dateStamp, forKey: "dateStamp") } }
    var frameStyle: FrameStyle { didSet { d.set(frameStyle.rawValue, forKey: "frame") } }
    /// Light leaks on new frames: 0 off, 0.5 subtle, 1 strong.
    var lightLeak: Double { didSet { d.set(lightLeak, forKey: "lightLeak") } }
    var dust: Bool { didSet { d.set(dust, forKey: "dust") } }
    /// 48MP ProRAW (main camera) instead of 12MP.
    var highResolution: Bool { didSet { d.set(highResolution, forKey: "hires") } }
    /// Process Zero: one unmerged Bayer RAW frame, no Apple processing (12MP).
    var zeroProcess: Bool { didSet { d.set(zeroProcess, forKey: "zero") } }
    /// Manual shutter in seconds; 0 = automatic. Over ~1 s, frames are stacked.
    var shutter: Double { didSet { d.set(shutter, forKey: "shutter") } }
    /// Long exposures keep moving lights as solid trails.
    var trails: Bool { didSet { d.set(trails, forKey: "trails") } }
    var portraitLens: PortraitLens { didSet { d.set(portraitLens.rawValue, forKey: "portraitLens") } }
    var blurAmount: Double { didSet { d.set(blurAmount, forKey: "blurAmount") } }
    var saveToPhotos: Bool { didSet { d.set(saveToPhotos, forKey: "saveToPhotos") } }
    var saveOriginal: Bool { didSet { d.set(saveOriginal, forKey: "saveOriginal") } }
    var showGrid: Bool { didSet { d.set(showGrid, forKey: "grid") } }
    var showLevel: Bool { didSet { d.set(showLevel, forKey: "level") } }
    var showMeter: Bool { didSet { d.set(showMeter, forKey: "meter") } }
    var stockOrder: [String] { didSet { d.set(stockOrder, forKey: "stockOrder") } }
    var hiddenStocks: Set<String> { didSet { d.set(Array(hiddenStocks), forKey: "hidden") } }
    var randomPool: Set<String> { didSet { d.set(Array(randomPool), forKey: "randomPool") } }
    var saveLocation: Bool { didSet { d.set(saveLocation, forKey: "saveLocation") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var advanceSound: Bool { didSet { d.set(advanceSound, forKey: "advanceSound") } }
    /// Show each new frame developing full screen (Random hides the stock until then).
    var bigReveal: Bool { didSet { d.set(bigReveal, forKey: "bigReveal") } }
    /// Default look strength per stock id (0…1); missing = 1.
    var stockStrength: [String: Double] { didSet { d.set(stockStrength, forKey: "stockStrength") } }
    /// Stocks the user made.
    var customStocks: [CustomStock] {
        didSet {
            StockRegistry.set(customStocks)
            d.set(try? JSONEncoder().encode(customStocks), forKey: "customStocks")
        }
    }
    /// The first-launch introduction has been shown.
    var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    init() {
        d.register(defaults: [
            "selectedStock": FilmStock.randomID, "aspect": AspectRatio.r3x2.rawValue, "grain": 1.0,
            "halation": true, "flareAmount": 0.6, "dateStamp": false, "frame": FrameStyle.none.rawValue, "lightLeak": 0.0, "dust": false, "hires": false, "zero": false, "shutter": 0.0, "trails": true, "portraitLens": PortraitLens.classic.rawValue, "blurAmount": 0.6,
            "saveToPhotos": true, "saveOriginal": false, "grid": false, "level": true, "meter": true,
            "saveLocation": false, "haptics": true, "advanceSound": false, "bigReveal": false,
        ])
        selectedStockID = d.string(forKey: "selectedStock") ?? FilmStock.randomID
        aspect = AspectRatio(rawValue: d.string(forKey: "aspect") ?? "") ?? .r3x2
        grainAmount = d.double(forKey: "grain")
        halation = d.bool(forKey: "halation")
        // Earlier builds had an on/off switch; carry "off" over once, then drop the old key.
        if d.object(forKey: "flare") as? Bool == false { d.set(0.0, forKey: "flareAmount") }
        d.removeObject(forKey: "flare")
        flareAmount = d.double(forKey: "flareAmount")
        dateStamp = d.bool(forKey: "dateStamp")
        frameStyle = FrameStyle(rawValue: d.string(forKey: "frame") ?? "") ?? .none
        lightLeak = d.double(forKey: "lightLeak")
        dust = d.bool(forKey: "dust")
        highResolution = d.bool(forKey: "hires")
        zeroProcess = d.bool(forKey: "zero")
        shutter = d.double(forKey: "shutter")
        trails = d.bool(forKey: "trails")
        portraitLens = PortraitLens(rawValue: d.string(forKey: "portraitLens") ?? "") ?? .classic
        blurAmount = d.double(forKey: "blurAmount")
        saveToPhotos = d.bool(forKey: "saveToPhotos")
        saveOriginal = d.bool(forKey: "saveOriginal")
        showGrid = d.bool(forKey: "grid")
        showLevel = d.bool(forKey: "level")
        showMeter = d.bool(forKey: "meter")
        let customs = d.data(forKey: "customStocks").flatMap { try? JSONDecoder().decode([CustomStock].self, from: $0) } ?? []
        customStocks = customs
        StockRegistry.set(customs)
        stockOrder = d.stringArray(forKey: "stockOrder") ?? FilmStock.all.map(\.id)
        hiddenStocks = Set(d.stringArray(forKey: "hidden") ?? [])
        randomPool = Set(d.stringArray(forKey: "randomPool") ?? [])
        saveLocation = d.bool(forKey: "saveLocation")
        haptics = d.bool(forKey: "haptics")
        advanceSound = d.bool(forKey: "advanceSound")
        bigReveal = d.bool(forKey: "bigReveal")
        stockStrength = d.dictionary(forKey: "stockStrength") as? [String: Double] ?? [:]
        // Existing users (who already have photos) skip the introduction.
        let hasRoll = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Roll").path))?.isEmpty == false
        onboarded = d.bool(forKey: "onboarded") || hasRoll
    }

    func strength(for stock: FilmStock) -> Double { stockStrength[stock.id] ?? 1 }

    /// All stocks in the user's order (new stocks appended).
    var orderedStocks: [FilmStock] {
        let known = stockOrder.compactMap(FilmStock.with(id:))
        return known + FilmStock.available.filter { !stockOrder.contains($0.id) }
    }

    var visibleStocks: [FilmStock] { orderedStocks.filter { !hiddenStocks.contains($0.id) } }

    var isRandom: Bool { selectedStockID == FilmStock.randomID || FilmStock.with(id: selectedStockID) == nil }

    /// The stock for the next frame. Random mode draws from the pool (or every visible stock).
    func resolveStock() -> FilmStock {
        if !isRandom, let s = FilmStock.with(id: selectedStockID) { return s }
        let pool = visibleStocks.filter { randomPool.isEmpty || randomPool.contains($0.id) }
        return pool.randomElement() ?? visibleStocks.randomElement() ?? .honey
    }

    func moveStocks(from source: IndexSet, to destination: Int) {
        var ids = orderedStocks.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        stockOrder = ids
    }

    func toggleHidden(_ id: String) {
        if hiddenStocks.contains(id) { hiddenStocks.remove(id) } else { hiddenStocks.insert(id) }
        if hiddenStocks.contains(selectedStockID) { selectedStockID = FilmStock.randomID }
    }

    func save(_ custom: CustomStock) {
        if let i = customStocks.firstIndex(where: { $0.id == custom.id }) { customStocks[i] = custom }
        else { customStocks.append(custom) }
    }

    func delete(_ custom: CustomStock) {
        customStocks.removeAll { $0.id == custom.id }
        stockOrder.removeAll { $0 == custom.id }
        if selectedStockID == custom.id { selectedStockID = FilmStock.randomID }
    }

    func toggleRandom(_ id: String) {
        if randomPool.contains(id) { randomPool.remove(id) } else { randomPool.insert(id) }
    }
}
