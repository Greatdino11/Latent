import simd
import CoreImage
import XCTest
@testable import Latent

final class FilmCurveTests: XCTestCase {
    func testCurveIsMonotonicAndBounded() {
        for stock in FilmStock.all {
            var last = -1.0
            for i in 0...200 {
                let x = 0.18 * pow(2, Double(i - 100) / 10)       // -10 … +10 stops
                let y = LUT.curve(x, stock.contrast.y, stock.balance.y, stock.black.y, stock.white.y)
                XCTAssertGreaterThanOrEqual(y, last - 1e-9, "\(stock.id) curve dips at \(x)")
                XCTAssert((0...1).contains(y), "\(stock.id) out of range")
                last = y
            }
        }
    }

    func testMidGreyPrintsMidGrey() {
        for stock in FilmStock.all where !stock.isMonochrome {
            let y = LUT.transform(RGB(repeating: 0.18), stock)
            XCTAssert((0.35...0.65).contains(LUT.luma(y)), "\(stock.id) mid grey prints at \(y)")
        }
    }

    func testMonochromeStocksAreNeutral() {
        // Neutral-paper monochromes only (toned ones, like Umber, are warm on purpose).
        for stock in FilmStock.all where stock.isMonochrome && stock.white.x == stock.white.z {
            let y = LUT.transform(RGB(0.6, 0.2, 0.1), stock)
            XCTAssertEqual(y.x, y.y, accuracy: 0.03); XCTAssertEqual(y.y, y.z, accuracy: 0.03)
        }
    }

    /// Bright skies keep their colour instead of fading to the print white.
    func testBrightSkyStaysBlue() {
        let sky = RGB(0.35, 0.6, 1.4)   // a bright blue sky, about +2.5 stops
        for stock in [FilmStock.coast, .valley, .clear] {
            let y = LUT.transform(sky, stock)
            XCTAssertGreaterThan(y.z - y.x, 0.05, "\(stock.id) sky lost its blue: \(y)")
        }
    }

    func testCacheKeyTracksParameters() {
        let a = LUT.cacheKey(.honey, expandSDR: false)
        XCTAssertEqual(a, LUT.cacheKey(.honey, expandSDR: false))
        XCTAssertNotEqual(a, LUT.cacheKey(.honey, expandSDR: true))
        XCTAssertNotEqual(a, LUT.cacheKey(FilmStock.honey.with(\.saturation, 0.5), expandSDR: false))
    }

    func testToneMonochromeIsWarm() {
        let y = LUT.transform(RGB(repeating: 0.05), .umber)
        XCTAssertGreaterThan(y.x, y.z, "Umber shadows should be warm")
        XCTAssertEqual(Set(FilmStock.all.map(\.id)).count, FilmStock.all.count, "stock ids are unique")
    }

    func testStrengthScalesTexture() {
        let s = FilmStock.night.scaled(by: 0)
        XCTAssertEqual(s.halation, 0); XCTAssertEqual(s.aberration, 0)
        XCTAssertGreaterThan(s.grain, 0, "grain is kept at zero strength")
    }
}

final class CropTests: XCTestCase {
    private func image(_ w: CGFloat, _ h: CGFloat) -> CIImage { CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) }

    func testPortraitThreeTwo() {
        let e = FilmPipeline.crop(image(3024, 4032), to: .r3x2).extent
        XCTAssertEqual(e.width / e.height, 2.0 / 3.0, accuracy: 0.002)
        XCTAssertEqual(e.origin, .zero)
    }

    func testLandscapeSquareAndPano() {
        XCTAssertEqual(FilmPipeline.crop(image(4032, 3024), to: .r1x1).extent.size, CGSize(width: 3024, height: 3024))
        let p = FilmPipeline.crop(image(4032, 3024), to: .pano).extent
        XCTAssertEqual(p.width / p.height, 65.0 / 24.0, accuracy: 0.01)
    }

    /// Sliding moves the frame within the negative, never changes its size, and stops at the edges.
    func testCropShiftSlidesWithinFrame() {
        let e = CGRect(x: 0, y: 0, width: 3024, height: 4032)       // portrait 3:4
        let centred = FilmPipeline.cropRect(e, to: .r1x1)
        let top = FilmPipeline.cropRect(e, to: .r1x1, shift: 1)
        let bottom = FilmPipeline.cropRect(e, to: .r1x1, shift: -1)
        XCTAssertEqual(top.size, centred.size); XCTAssertEqual(bottom.size, centred.size)
        XCTAssertEqual(top.maxY, e.maxY); XCTAssertEqual(bottom.minY, e.minY)
        XCTAssertEqual(FilmPipeline.cropRect(e, to: .r1x1, shift: 5), top, "clamped to the edge")
        XCTAssertEqual(FilmPipeline.slideAxis(width: 3024, height: 4032, aspect: .r1x1), .vertical)
        XCTAssertEqual(FilmPipeline.slideAxis(width: 3024, height: 4032, aspect: .r3x2), .horizontal)
        XCTAssertNil(FilmPipeline.slideAxis(width: 3024, height: 4032, aspect: .r4x3), "no room to slide")
        XCTAssertNil(FilmPipeline.slideAxis(width: 3024, height: 4032, aspect: nil))
    }

    func testFullFrameKeepsEverything() {
        XCTAssertEqual(FilmPipeline.crop(image(4032, 3024), to: nil).extent.size, CGSize(width: 4032, height: 3024))
    }
}

final class RecipeTests: XCTestCase {
    /// A recipe written by the first version with negatives: none of the later keys.
    func testOldRecipeStillDecodes() throws {
        let json = #"{"exposure":0,"aspect":"3:2","grainAmount":1,"halation":true,"flare":false,"dateStamp":true,"frame":"white","date":800000000,"sceneReferred":true}"#
        let r = try JSONDecoder().decode(DevelopOptions.self, from: Data(json.utf8))
        XCTAssertEqual(r.aspect, .r3x2)
        XCTAssertEqual(r.flareStrength, 0)
        XCTAssertNil(r.pushPull); XCTAssertNil(r.strength); XCTAssertNil(r.negativeFormat)
        XCTAssertEqual(r.frame, .white)
    }

    func testRoundTrip() throws {
        var o = DevelopOptions(); o.pushPull = -0.7; o.strength = 0.4; o.aspect = nil; o.negativeFormat = 2
        let back = try JSONDecoder().decode(DevelopOptions.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back.pushPull, -0.7); XCTAssertEqual(back.strength, 0.4); XCTAssertNil(back.aspect)
        XCTAssertEqual(back.negativeFormat, 2)
    }

    @MainActor
    func testCaptureDateFromExif() {
        let meta: [String: Any] = [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal as String: "2025:10:31 18:45:12",
            kCGImagePropertyExifOffsetTimeOriginal as String: "-05:00",
        ]]
        let d = AppModel.captureDate(meta)
        XCTAssertEqual(d?.timeIntervalSince1970, 1761954312)
        XCTAssertNil(AppModel.captureDate([:]))
    }
}

final class NegativeCodecTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    private func value(of image: CIImage) -> Float {
        var px = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return px[1]
    }

    /// Encode → 10-bit HEIF → decode keeps scene values from deep shadow to bright highlight.
    func testRoundTripThroughHEIF() throws {
        for v in [0.0028, 0.02, 0.18, 1.0, 6.0] {
            let scene = CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            let heif = try context.heif10Representation(of: NegativeCodec.encode(scene), colorSpace: p3, options: [:])
            let back = NegativeCodec.decode(try XCTUnwrap(CIImage(data: heif)), format: NegativeCodec.current)
            let got = Double(value(of: back))
            XCTAssertEqual(got, v, accuracy: v * 0.04 + 0.0003, "value \(v) came back as \(got)")
        }
    }

    func testLegacyNegativesStillDecode() {
        let stored = CIImage(color: CIColor(red: 0.0225, green: 0.0225, blue: 0.0225, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(Double(value(of: NegativeCodec.decode(stored, format: nil))), 0.18, accuracy: 0.002)
    }
}

final class RollArchiveTests: XCTestCase {
    func testExportImportRoundTrip() throws {
        let fm = FileManager.default
        let src = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dst = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        let files = ["1_honey.jpg": Data(repeating: 7, count: 5000), "1.neg.heic": Data(repeating: 3, count: 12000),
                     "1.recipe.json": Data("{}".utf8), "empty.photos": Data()]
        for (n, d) in files { try d.write(to: src.appendingPathComponent(n)) }

        let stocks = Data(#"[{"id":"custom-x"}]"#.utf8)
        let archive = try RollArchive.export(from: src, stocks: stocks)
        let first = try RollArchive.importArchive(archive, into: dst)
        XCTAssertEqual(first.added, files.count - 1, "Photos links stay behind")
        XCTAssertEqual(first.stocks, stocks)
        for (n, d) in files where !n.hasSuffix(".photos") { XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(n)), d, n) }
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("empty.photos").path))
        XCTAssertEqual(try RollArchive.importArchive(archive, into: dst).added, 0, "existing files are kept, not duplicated")
    }

    func testRejectsNonArchive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hello".utf8).write(to: url)
        XCTAssertThrowsError(try RollArchive.importArchive(url, into: FileManager.default.temporaryDirectory))
    }

    /// A crafted archive can't write outside the roll folder.
    func testIgnoresPathTraversal() throws {
        var data = Data("LATROLL1".utf8)
        let name = Data("../evil.txt".utf8)
        data += withUnsafeBytes(of: UInt32(name.count).littleEndian) { Data($0) } + name
        data += withUnsafeBytes(of: UInt64(3).littleEndian) { Data($0) } + Data("bad".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(try RollArchive.importArchive(url, into: dst).added, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }
}

extension NegativeCodecTests {
    /// Same check without the HEIF step, to tell encoding problems from file-format problems.
    func testCodecMathKeepsHighlights() {
        let scene = CIImage(color: CIColor(red: 6, green: 6, blue: 6, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(Double(value(of: scene)), 6, accuracy: 0.01, "test input itself")
        let back = NegativeCodec.decode(NegativeCodec.encode(scene), format: NegativeCodec.current)
        XCTAssertEqual(Double(value(of: back)), 6, accuracy: 0.05)
    }
}

final class EdgeTests: XCTestCase {
    func testWholePixelsRoundsInward() {
        let r = FilmPipeline.wholePixels(CGRect(x: 0.3, y: 0, width: 4033.7, height: 2688.6))
        XCTAssertEqual(r, CGRect(x: 1, y: 0, width: 4033, height: 2688))
        XCTAssertEqual(FilmPipeline.wholePixels(CGRect(x: 0, y: 0, width: 4032, height: 3024)), CGRect(x: 0, y: 0, width: 4032, height: 3024))
    }

    /// The framed print's outer edges are paper, not a dark unpainted column/row.
    func testFramedPrintHasNoDarkEdge() throws {
        for (w, h) in [(3023, 4031), (4033, 2689), (1001, 667)] {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var o = DevelopOptions(); o.frame = .white
            let out = Finisher.finish(ctx.makeImage()!, stock: .honey, options: o)
            let ow = out.width, oh = out.height
            var px = [UInt8](repeating: 0, count: ow * oh * 4)
            let read = CGContext(data: &px, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: ow * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            read.draw(out, in: CGRect(x: 0, y: 0, width: ow, height: oh))
            for (x, y, edge) in [(ow - 1, oh / 2, "right"), (0, oh / 2, "left"), (ow / 2, 0, "top"), (ow / 2, oh - 1, "bottom")] {
                XCTAssertGreaterThan(px[(y * ow + x) * 4], 230, "\(w)x\(h): \(edge) edge isn't paper")
            }
        }
    }
}

final class ScanCharacterTests: XCTestCase {
    func testSeededRandomIsDeterministic() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42), c = SeededRandom(seed: 43)
        let xs = (0..<5).map { _ in a.unit() }
        XCTAssertEqual(xs, (0..<5).map { _ in b.unit() })
        XCTAssertNotEqual(xs, (0..<5).map { _ in c.unit() })
        XCTAssert(xs.allSatisfy { (0..<1).contains($0) })
    }

    /// 35mm border: sprocket bands go on the long sides, and edges are whole pixels with no unpainted sliver.
    func testFilmBorderLayout() {
        for (w, h) in [(4032, 2688), (2688, 4032)] {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            var o = DevelopOptions(); o.frame = .film; o.dust = true
            let out = Finisher.finish(ctx.makeImage()!, stock: .reel, options: o)
            let addedW = out.width - w, addedH = out.height - h
            if w > h { XCTAssertGreaterThan(addedH, addedW, "landscape: rebate top/bottom") }
            else { XCTAssertGreaterThan(addedW, addedH, "portrait: rebate left/right") }
        }
    }

    func testOldRecipesDecodeWithoutScanFields() throws {
        let json = #"{"exposure":0,"aspect":"3:2","grainAmount":1,"halation":true,"flare":true,"dateStamp":false,"frame":"none","date":800000000,"sceneReferred":true}"#
        let r = try JSONDecoder().decode(DevelopOptions.self, from: Data(json.utf8))
        XCTAssertNil(r.lightLeak); XCTAssertNil(r.dust)
        XCTAssertEqual(try JSONDecoder().decode(DevelopOptions.self, from: Data(#"{"frame":"film","date":1,"exposure":0,"grainAmount":1,"halation":true,"flare":true,"dateStamp":false,"sceneReferred":false}"#.utf8)).frame, .film)
    }
}

final class CustomStockTests: XCTestCase {
    func testNeutralCustomStockMatchesBase() {
        var c = CustomStock(); c.baseID = "coast"
        let s = c.stock, base = FilmStock.coast
        XCTAssertEqual(s.contrast, base.contrast); XCTAssertEqual(s.saturation, base.saturation)
        XCTAssertEqual(s.black, base.black); XCTAssertEqual(s.grain, base.grain)
        XCTAssertEqual(s.id, c.id); XCTAssertNotEqual(LUT.cacheKey(s, expandSDR: false), LUT.cacheKey(base, expandSDR: false))
    }

    func testAdjustmentsMoveTheRightWay() {
        var c = CustomStock(); c.baseID = "clear"
        c.warmth = 1; c.fade = 1; c.saturation = -1; c.grain = 2
        let s = c.stock, base = FilmStock.clear
        XCTAssertGreaterThan(s.temperature, base.temperature)
        XCTAssertGreaterThan(s.black.x, base.black.x)
        XCTAssertLessThan(s.saturation, base.saturation)
        XCTAssertEqual(s.grain, base.grain * 2, accuracy: 1e-9)
        let warm = LUT.transform(RGB(repeating: 0.18), s)
        XCTAssertGreaterThan(warm.x, warm.z, "warmer stock prints grey warm")
    }

    func testRegistryResolvesCustomIDs() throws {
        let c = CustomStock()
        StockRegistry.set([c])
        defer { StockRegistry.set([]) }
        XCTAssertEqual(FilmStock.with(id: c.id)?.name, c.name)
        XCTAssert(FilmStock.available.contains { $0.id == c.id })
        let round = try JSONDecoder().decode([CustomStock].self, from: JSONEncoder().encode([c]))
        XCTAssertEqual(round, [c])
    }
}

final class PortraitTests: XCTestCase {
    private let ctx = CIContext(options: [.cacheIntermediates: false])

    private func value(_ image: CIImage, at p: CGPoint) -> Float {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return px[0]
    }

    /// Mask is clear where depth matches focus and full where it's far from it.
    func testBlurMaskFollowsFocus() throws {
        let e = CGRect(x: 0, y: 0, width: 400, height: 400)
        // Left half near (1), right half far (0).
        let near = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 400))
        let depth = near.composited(over: CIImage(color: .black).cropped(to: e))
        let mask = try XCTUnwrap(Portrait.blurMask(depth, focus: 1, extent: e, short: 400))
        XCTAssertLessThan(value(mask, at: CGPoint(x: 40, y: 200)), 0.05, "in-focus side stays sharp")
        XCTAssertGreaterThan(value(mask, at: CGPoint(x: 360, y: 200)), 0.95, "far side is fully blurred")
    }

    /// The sharp subject must not smear into the blurred background beside it.
    func testBackgroundBlurDoesNotBleedSubject() throws {
        let e = CGRect(x: 0, y: 0, width: 400, height: 200)
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1, colorSpace: lin)!).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let img = red.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 1, alpha: 1, colorSpace: lin)!).cropped(to: e))
        let bg = CIImage(color: .white).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200))
        let weight = bg.composited(over: CIImage(color: .black).cropped(to: e))   // 1 = background (right half)
        let out = try XCTUnwrap(Portrait.backgroundBlur(img, weight: weight, extent: e) { $0.applyingGaussianBlur(sigma: 20) })
        let plain = img.clampedToExtent().applyingGaussianBlur(sigma: 20)
        let p = CGPoint(x: 212, y: 100)
        XCTAssertLessThan(value(out, at: p), 0.03, "no red from the subject in the background blur")
        XCTAssertGreaterThan(value(plain, at: p), 0.2, "a plain blur does bleed (sanity check)")
    }

    func testRecipeCarriesPortraitFields() throws {
        var o = DevelopOptions(); o.portraitLens = .swirl; o.blurAmount = 0.4; o.focusDepth = 0.7
        let back = try JSONDecoder().decode(DevelopOptions.self, from: JSONEncoder().encode(o))
        XCTAssertEqual(back.portraitLens, .swirl); XCTAssertEqual(back.blurAmount, 0.4); XCTAssertEqual(back.focusDepth, 0.7)
    }
}

final class StockCodeTests: XCTestCase {
    func testRoundTripAndPasteFromMessage() throws {
        var c = CustomStock(); c.name = "Beach"; c.baseID = "coast"; c.warmth = 0.4; c.grain = 1.6
        let code = try XCTUnwrap(StockCode.encode(c))
        XCTAssert(code.hasPrefix("LTN1-")); XCTAssertLessThan(code.count, 400)
        let back = try XCTUnwrap(StockCode.decode("Try my stock! \(code) 🎞"))
        XCTAssertEqual(back.name, "Beach"); XCTAssertEqual(back.baseID, "coast"); XCTAssertEqual(back.warmth, 0.4)
        XCTAssertNotEqual(back.id, c.id, "imports get a fresh id")
    }

    func testRejectsGarbage() {
        XCTAssertNil(StockCode.decode("hello"))
        XCTAssertNil(StockCode.decode("LTN1-notbase64!!"))
    }
}

final class DoubleExposureTests: XCTestCase {
    private let ctx = CIContext(options: [.cacheIntermediates: false])
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    private func grey(_ v: Double, _ w: CGFloat, _ h: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func value(_ image: CIImage, at p: CGPoint) -> Float {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return px[1]
    }

    /// Two mid-grey exposures add up to one mid-grey exposure, on the first frame's canvas.
    func testTwoExposuresAddToOne() {
        let out = Darkroom.superimpose(grey(0.18, 300, 200), grey(0.18, 200, 300))
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 300, height: 200))
        for p in [CGPoint(x: 1, y: 1), CGPoint(x: 150, y: 100), CGPoint(x: 298, y: 198)] {
            XCTAssertEqual(value(out, at: p), 0.18, accuracy: 0.003)
        }
    }

    /// A bright second exposure shows through over a dark first one.
    func testSecondFrameShowsThrough() {
        let out = Darkroom.superimpose(grey(0, 100, 100), grey(0.5, 100, 100))
        XCTAssertEqual(value(out, at: CGPoint(x: 50, y: 50)), 0.25, accuracy: 0.003)
    }
}

final class ContactSheetTests: XCTestCase {
    private func frame(_ w: Int, _ h: Int, _ n: Int) -> ContactSheet.Frame {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(gray: 0.5, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return .init(image: c.makeImage()!, number: n, stock: "Honey 200")
    }

    func testStripsOfSix() throws {
        let one = try XCTUnwrap(ContactSheet.render([frame(30, 20, 1)], title: "T", seed: 1))
        let seven = try XCTUnwrap(ContactSheet.render((1...7).map { frame($0 % 2 == 0 ? 20 : 30, $0 % 2 == 0 ? 30 : 20, $0) }, title: "T", seed: 1))
        XCTAssertEqual(one.width, seven.width, "strips are always six frames wide")
        XCTAssertGreaterThan(seven.height, one.height, "a seventh frame starts a second strip")
        XCTAssertGreaterThan(one.width, one.height)
    }

    func testEmptyRollHasNoSheet() {
        XCTAssertNil(ContactSheet.render([], title: "T", seed: 1))
    }
}

final class ContactFrameTests: XCTestCase {
    /// The sheet shows the whole 3:2 negative; a square crop of a 4:3 frame is marked as the middle three-quarters.
    func testCropMarkSitsInsideTheFullFrame() async throws {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let scene = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let heif = try XCTUnwrap(CIContext().heif10Representation(of: NegativeCodec.encode(scene),
                                                                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [:]))
        var recipe = DevelopOptions(); recipe.negativeFormat = NegativeCodec.current
        recipe.aspect = .r1x1; recipe.grainAmount = 0
        let (image, mark) = try await Darkroom.shared.contactFrame(negative: heif, recipe: recipe, stock: .honey, maxPixel: 400)
        XCTAssertEqual(Double(image.width) / Double(image.height), 1.5, accuracy: 0.02)
        let m = try XCTUnwrap(mark)
        XCTAssertEqual(m.width, 0.75, accuracy: 0.01); XCTAssertEqual(m.minX, 0.125, accuracy: 0.01)

        recipe.aspect = .r3x2
        let (_, none) = try await Darkroom.shared.contactFrame(negative: heif, recipe: recipe, stock: .honey, maxPixel: 400)
        XCTAssertNil(none, "a 3:2 frame needs no mark")
    }
}

extension DoubleExposureTests {
    /// Balance moves the light from the base to the frame on top.
    func testBalanceSharesTheLight() {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ctx = CIContext(options: [.cacheIntermediates: false])
        func v(_ i: CIImage) -> Float {
            var px = [Float](repeating: 0, count: 4)
            ctx.render(i, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 50, y: 50, width: 1, height: 1), format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
            return px[1]
        }
        XCTAssertEqual(v(Darkroom.superimpose(base, black, balance: 0.25)), 0.375, accuracy: 0.003)
        XCTAssertEqual(v(Darkroom.superimpose(base, black, balance: 0.75)), 0.125, accuracy: 0.003)
    }
}

final class RollTrashTests: XCTestCase {
    func testTrashRestoreAndPurge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let rollDir = root.appendingPathComponent("Roll")
        try FileManager.default.createDirectory(at: rollDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = "1795000000000"
        for name in ["\(base)_honey.jpg", "\(base).neg.heic", "\(base).recipe.json"] { try Data([1]).write(to: rollDir.appendingPathComponent(name)) }
        try "ASSET-1".write(to: rollDir.appendingPathComponent("\(base).photos"), atomically: true, encoding: .utf8)

        let roll = RollStore(folder: rollDir)
        let item = try XCTUnwrap(roll.items.first)
        roll.trash(item)
        XCTAssertTrue(roll.items.isEmpty)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: rollDir.path)).isEmpty, "every file moves out")
        XCTAssertEqual(roll.trashedPhotoLinks().first?.photosID, "ASSET-1")

        roll.restore(base: base)
        XCTAssertEqual(roll.items.map(\.base), [base])
        XCTAssertTrue(roll.items[0].hasNegative)
        XCTAssertTrue(roll.trashedPhotoLinks().isEmpty)

        roll.trash(roll.items[0])
        roll.purgeTrash(olderThan: 30)
        XCTAssertEqual(roll.trashedPhotoLinks().count, 1, "recent trash is kept")
        let marker = root.appendingPathComponent("RollTrash/\(base).trashed")
        try ISO8601DateFormatter().string(from: Date().addingTimeInterval(-40 * 86_400)).write(to: marker, atomically: true, encoding: .utf8)
        roll.purgeTrash(olderThan: 30)
        XCTAssertTrue(roll.trashedPhotoLinks().isEmpty)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("RollTrash").path)).isEmpty)
    }
}

final class FlareTests: XCTestCase {
    /// In a RAW, only sun-level sources throw ghosts: a bright patch (sky through branches, sunlit bark) doesn't.
    func testOnlyTheSunThrowsGhosts() {
        func peak(forLuma l: Double) -> Float { Float(l / 2.5 - 1) }   // the hot-spot mask's scale for RAW
        XCTAssertEqual(FilmPipeline.flareIntensity(peak: peak(forLuma: 5), sceneReferred: true), 0)
        XCTAssertEqual(FilmPipeline.flareIntensity(peak: 6, sceneReferred: true), 1, accuracy: 1e-9)   // clipped sun
        let mid = FilmPipeline.flareIntensity(peak: peak(forLuma: 12.5), sceneReferred: true)
        XCTAssertGreaterThan(mid, 0); XCTAssertLessThan(mid, 1)
        XCTAssertEqual(FilmPipeline.flareIntensity(peak: 0.03, sceneReferred: false), 1, accuracy: 1e-6)
    }

    /// Night is tungsten-balanced: mid grey prints neutral-to-cool, not warm.
    func testNightIsNotWarmOverall() {
        let o = LUT.transform(RGB(0.18, 0.18, 0.18), FilmStock.night.forRAW())
        XCTAssertLessThanOrEqual(o.x, o.z + 0.005)
    }
}

final class LongExposureTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func flat(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: linear)!).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    private func value(_ i: CIImage) -> Float {
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(i, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return px[1]
    }

    /// Four frames of a dim wall average to the wall; a headlight that passed once survives as a trail.
    func testTrailsKeepPassingLights() {
        let wallSum = flat(0.4), wallMax = flat(0.12)                       // 4 × 0.1
        XCTAssertEqual(value(LongExposure.blend(sum: wallSum, max: wallMax, count: 4, trails: true)), 0.1, accuracy: 0.003)
        let lightSum = flat(1.3), lightMax = flat(1.0)                      // 0.1 × 3 + a 1.0 headlight
        XCTAssertEqual(value(LongExposure.blend(sum: lightSum, max: lightMax, count: 4, trails: true)), 1.0, accuracy: 0.01)
        XCTAssertEqual(value(LongExposure.blend(sum: lightSum, max: lightMax, count: 4, trails: false)), 0.325, accuracy: 0.003)
    }

    func testShutterLabels() {
        XCTAssertEqual(LongExposure.label(0), "AUTO")
        XCTAssertEqual(LongExposure.label(1.0 / 15), "1/15")
        XCTAssertEqual(LongExposure.label(8), "8\"")
    }
}

final class LabLookTests: XCTestCase {
    private func value(_ i: CIImage) -> RGB {
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(i, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return RGB(Double(px[0]), Double(px[1]), Double(px[2]))
    }
    private func patch(_ v: Double) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// Expired film lifts the blacks and pulls the whites down: less contrast.
    func testExpiredFogsAndFades() {
        let black = value(FilmPipeline.expire(patch(0.02), amount: 1, seed: 7)), white = value(FilmPipeline.expire(patch(0.95), amount: 1, seed: 7))
        XCTAssertGreaterThan(black.sum() / 3, 0.08)
        XCTAssertLessThan(white.sum() / 3, 0.9)
        let none = value(FilmPipeline.expire(patch(0.5), amount: 0, seed: 7))
        XCTAssertEqual(none.sum() / 3, 0.5, accuracy: 0.01)
    }

    /// Frontier scans are punchier than Noritsu's.
    func testFrontierHasMoreContrastThanNoritsu() {
        func spread(_ s: ScannerLook) -> Double { value(FilmPipeline.scan(patch(0.85), s)).sum() - value(FilmPipeline.scan(patch(0.15), s)).sum() }
        XCTAssertGreaterThan(spread(.frontier), spread(.noritsu))
    }
}

final class RollDayTests: XCTestCase {
    func testGroupsByDayNewestFirst() {
        let cal = Calendar.current
        let d1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 18))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9))!
        let d3 = cal.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 17))!
        let folder = URL(fileURLWithPath: "/tmp")
        let items = [d1, d2, d3].map { RollItem(base: String(Int64($0.timeIntervalSince1970 * 1000)), stockID: "honey", date: $0, folder: folder) }
        let days = RollDay.group(items)
        XCTAssertEqual(days.map(\.key), ["2026-11-21", "2026-11-20"])
        XCTAssertEqual(days[0].items.count, 2)
        XCTAssertEqual(days[1].title, "FRI 20 NOV")
    }
}

final class SocialPrintTests: XCTestCase {
    func testPostAndStorySizes() throws {
        let c = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        c.setFillColor(gray: 0.4, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let print = c.makeImage()!
        for f in SocialPrint.Format.allCases {
            let data = try XCTUnwrap(SocialPrint.render(print, format: f, border: .none, stock: "Honey 200"))
            let img = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(img.size.width * img.scale, f.size.width)
            XCTAssertEqual(img.size.height * img.scale, f.size.height)
        }
    }
}

final class MeterTests: XCTestCase {
    /// A paused camera reports NaN exposure: the meter shows a dash instead of crashing.
    func testMeterSurvivesInvalidReadings() {
        XCTAssertEqual(MatchNeedle.shutter(.nan), "—")
        XCTAssertEqual(MatchNeedle.shutter(.infinity), "—")
        XCTAssertEqual(MatchNeedle.shutter(0), "—")
        XCTAssertEqual(MatchNeedle.shutter(1.0 / 125), "1/125")
        XCTAssertEqual(MatchNeedle.shutter(2), "2\"")
    }
}

final class PanoramaTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func pixel(_ i: CIImage, _ p: CGPoint) -> SIMD3<Float> {
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(i, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: p.x, y: p.y, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        return SIMD3(px[0], px[1], px[2])
    }

    /// Three overlapping strips of one scene stitch back into (most of) the scene, in the right place.
    func testStripsStitchBackTogether() throws {
        let scene = SimulatedScene.capture
        let e = scene.extent
        let w = (e.width * 0.5).rounded(), step = (e.width * 0.25).rounded()
        let strips = (0..<3).map { i in
            scene.cropped(to: CGRect(x: e.minX + CGFloat(i) * step, y: e.minY, width: w, height: e.height))
        }
        let pano = try Panorama.stitch(strips, focal35: nil)
        // Width close to the original (allowing for the clean-edge crop), height kept.
        XCTAssertGreaterThan(pano.extent.width, e.width * 0.9)
        XCTAssertLessThanOrEqual(pano.extent.width, e.width + 2)
        XCTAssertGreaterThan(pano.extent.height, e.height * 0.95)
        // Points right across the panorama, including both overlaps, match the scene and are fully opaque.
        let dx = e.width - pano.extent.width, dy = e.height - pano.extent.height
        for fx in [0.15, 0.3, 0.38, 0.5, 0.62, 0.7, 0.85] {
            for fy in [0.3, 0.6] {
                let p = CGPoint(x: (pano.extent.width * fx).rounded(), y: (pano.extent.height * fy).rounded())
                let original = pixel(scene, CGPoint(x: e.minX + p.x + dx / 2, y: e.minY + p.y + dy / 2))
                XCTAssertLessThan(simd_length(pixel(pano, p) - original), 0.08, "at \(fx), \(fy)")
            }
        }
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(pano, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: (pano.extent.width * 0.38).rounded(), y: 100, width: 1, height: 1),
                           format: .RGBAf, colorSpace: linear)
        XCTAssertEqual(px[3], 1, accuracy: 0.001, "overlaps stay opaque")
    }

    /// Something in one shot's overlap but not the other's (a passer-by, or a close object shifted by parallax)
    /// comes out whole or not at all — never as a see-through double.
    func testSeamAvoidsGhosts() throws {
        let scene = SimulatedScene.capture
        let e = scene.extent
        let w = (e.width * 0.5).rounded(), step = (e.width * 0.25).rounded()
        let a = scene.cropped(to: CGRect(x: e.minX, y: e.minY, width: w, height: e.height))
        let bar = CGRect(x: e.minX + e.width * 0.28, y: e.minY + e.height * 0.2, width: e.width * 0.03, height: e.height * 0.6)
        let b = CIImage(color: .black).cropped(to: bar).composited(over: scene)
            .cropped(to: CGRect(x: e.minX + step, y: e.minY, width: w, height: e.height))
        let pano = try Panorama.stitch([a, b], focal35: nil)
        let dx = e.width * 0.75 - pano.extent.width, dy = e.height - pano.extent.height
        let p = CGPoint(x: (bar.midX - e.minX - dx / 2).rounded(), y: (bar.midY - e.minY - dy / 2).rounded())
        let got = pixel(pano, p), original = pixel(scene, CGPoint(x: bar.midX, y: bar.midY))
        let ratio = (got.x + got.y + got.z) / max(0.001, original.x + original.y + original.z)
        XCTAssertTrue(ratio < 0.1 || ratio > 0.9, "the object is either there or not, never half (ratio \(ratio))")
    }

    func testRejectsUnrelatedFrames() {
        let a = SimulatedScene.capture
        let b = CIImage(color: .gray).cropped(to: a.extent)
        XCTAssertThrowsError(try Panorama.stitch([a, b], focal35: nil))
    }
}

final class AdaptiveGrainTests: XCTestCase {
    /// Standard deviation of a flat patch after grain, measured in display (sRGB) values.
    private func grainStd(at v: Double, iso: Double? = nil, push: Double = 0) -> Double {
        let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let e = CGRect(x: 0, y: 0, width: 512, height: 512)
        // v is the display value; the pipeline works in linear light.
        let l = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        let flat = CIImage(color: CIColor(red: l, green: l, blue: l, alpha: 1, colorSpace: lin)!).cropped(to: e)
        let out = FilmPipeline.grain(on: flat, stock: .honey, user: 1, push: push, iso: iso, extent: e, short: 512)
        var px = [Float](repeating: 0, count: 256 * 256 * 4)
        CIContext().render(out, toBitmap: &px, rowBytes: 256 * 16, bounds: CGRect(x: 128, y: 128, width: 256, height: 256),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let g = stride(from: 1, to: px.count, by: 4).map { Double(px[$0]) }
        let mean = g.reduce(0, +) / Double(g.count)
        return (g.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(g.count)).squareRoot()
    }

    func testGrainIsStrongestInTheMidtones() {
        let shadow = grainStd(at: 0.03), mid = grainStd(at: 0.45), highlight = grainStd(at: 0.97)
        XCTAssertGreaterThan(mid, shadow * 1.8)
        XCTAssertGreaterThan(mid, highlight * 2)
    }

    func testHighISOAndPushChangeTheGrain() {
        XCTAssertEqual(FilmPipeline.grainLightFactor(iso: 100), 1)
        XCTAssertLessThan(FilmPipeline.grainLightFactor(iso: 3200), 0.65)
        XCTAssertLessThan(grainStd(at: 0.45, iso: 3200), grainStd(at: 0.45, iso: 100))
        XCTAssertGreaterThan(grainStd(at: 0.45, push: 1), grainStd(at: 0.45))
    }
}

final class DetailTests: XCTestCase {
    private func detail(_ jpeg: Data) -> Double {
        let img = CIImage(data: jpeg)!
        let e = img.extent, c = CGRect(x: e.midX - 500, y: e.midY - 500, width: 1000, height: 1000)
        let hp = img.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: img.clampedToExtent().applyingGaussianBlur(sigma: 1.5)])
        var px = [Float](repeating: 0, count: 4)
        CIContext().render(hp.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: c)]), toBitmap: &px, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Double(px[0] + px[1] + px[2])
    }

    /// CRISP keeps more fine detail than VINTAGE; the negative round trip keeps nearly all of it.
    func testCrispIsSharperAndNegativesKeepDetail() async throws {
        var o = DevelopOptions(); o.aspect = .r3x2; o.grainAmount = 0; o.flareAmount = 0; o.halation = false
        o.date = Date(timeIntervalSince1970: 1_800_000_000)
        let frame = CapturedFrame(source: .image(SimulatedScene.capture, sceneReferred: false), metadata: [:])
        let vintage = try await Darkroom.shared.develop(frame, stock: .honey, options: o)
        var c = o; c.crisp = true
        let crisp = try await Darkroom.shared.develop(frame, stock: .honey, options: c)
        XCTAssertGreaterThan(detail(crisp.jpeg), detail(vintage.jpeg) * 1.05)
        let again = try await Darkroom.shared.redevelop(negative: vintage.negative, metadata: [:], stock: .honey, options: vintage.options)
        XCTAssertGreaterThan(detail(again), detail(vintage.jpeg) * 0.97)
    }
}


final class PhotosSyncPlanTests: XCTestCase {
    /// Only photos the library reports as deleted take their frames off the roll — a link that simply doesn't
    /// resolve (another phone, a restored backup, an imported roll) is left alone.
    func testOnlyReportedDeletionsTrash() {
        let linked = [(base: "1", photosID: "A"), (base: "2", photosID: "B"), (base: "3", photosID: "C")]
        let plan = PhotosSync.plan(linked: linked, deleted: ["B"], trashed: [], present: [])
        XCTAssertEqual(plan.trash, ["2"])
        let migrated = PhotosSync.plan(linked: linked, deleted: [], trashed: [], present: [])
        XCTAssertTrue(migrated.trash.isEmpty, "nothing reported deleted: nothing trashed, even if no link resolves")
    }

    func testRestoresWhenThePhotoComesBack() {
        let trashed = [(base: "9", photosID: "Z"), (base: "8", photosID: "Y")]
        let plan = PhotosSync.plan(linked: [], deleted: [], trashed: trashed, present: ["Z"])
        XCTAssertEqual(plan.restore, ["9"])
    }
}

final class StockSnapshotTests: XCTestCase {
    func testFramesKeepTheirOwnCopyOfACustomStock() throws {
        var mine = CustomStock(); mine.id = "custom-snaptest"; mine.baseID = "coast"; mine.warmth = 0.5
        var recipe = DevelopOptions(); recipe.customStock = mine
        // The stock is no longer installed (deleted): the frame's own copy is used.
        let resolved = try XCTUnwrap(DevelopOptions.resolveStock(stockID: "custom-snaptest", recipe: recipe))
        XCTAssertEqual(resolved.id, "custom-snaptest")
        XCTAssertEqual(resolved.temperature, mine.stock.temperature)
        // No copy and not installed: reported as missing (never silently swapped for another stock).
        XCTAssertNil(DevelopOptions.resolveStock(stockID: "custom-gone", recipe: DevelopOptions()))
        // Built-in stocks resolve by id.
        XCTAssertEqual(DevelopOptions.resolveStock(stockID: "honey", recipe: DevelopOptions())?.id, "honey")
        // The copy survives the recipe's JSON round trip.
        let back = try JSONDecoder().decode(DevelopOptions.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(back.customStock, mine)
    }
}

final class LensRoutingTests: XCTestCase {
    private func pick(_ zoom: CGFloat, hiRes: Bool = false, physical: Bool = false, has48: Bool = true) -> CameraController.LensCamera {
        CameraController.lensCamera(lensZoom: zoom, baseZoom: 2, highResolution: hiRes, mainHas48: has48, needsPhysical: physical,
                                    hasUltraWide: true, hasTele: true)
    }

    func testRoutesToTheRightCamera() {
        XCTAssertEqual(pick(2), .virtual, "plain shooting keeps the smooth combined camera")
        XCTAssertEqual(pick(2, hiRes: true), .main, "48MP at 1× needs the main camera on its own")
        XCTAssertEqual(pick(2, hiRes: true, has48: false), .virtual)
        XCTAssertEqual(pick(6, hiRes: true), .virtual, "48MP only exists at 1×")
        XCTAssertEqual(pick(1, physical: true), .ultraWide, "ZERO / slow shutter at .5×")
        XCTAssertEqual(pick(2, physical: true), .main)
        XCTAssertEqual(pick(6, physical: true), .tele)
        XCTAssertEqual(pick(4, physical: true), .main, "a 2× crop of the main camera stays on it")
    }
}

final class RollStoreFlowTests: XCTestCase {
    func testAddThenRedevelopOnAnotherStock() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let roll = RollStore(folder: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = DevelopOptions(); o.date = Date(timeIntervalSince1970: 1_800_000_000); o.grainAmount = 1.5
        let item = try roll.add(DevelopResult(jpeg: Data([1, 2, 3]), negative: Data([9]), options: o, depth: nil), stock: .honey)
        XCTAssertEqual(roll.items.map(\.id), [item.id])
        XCTAssertTrue(item.hasNegative)
        XCTAssertEqual(roll.recipe(for: item).grainAmount, 1.5)

        // A second frame at the same instant never overwrites the first.
        let twin = try roll.add(DevelopResult(jpeg: Data([4]), negative: Data([8]), options: o, depth: nil), stock: .honey)
        XCTAssertNotEqual(twin.id, item.id)

        var changed = roll.recipe(for: item); changed.grainAmount = 0.5
        let updated = try roll.replace(item, stock: .coast, jpeg: Data([7, 7]), options: changed)
        XCTAssertEqual(updated.stockID, "coast")
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path), "old print removed")
        XCTAssertEqual(try Data(contentsOf: updated.url), Data([7, 7]))
        XCTAssertEqual(roll.recipe(for: updated).grainAmount, 0.5)
        XCTAssertTrue(updated.hasNegative, "the negative is untouched")
        XCTAssertGreaterThan(updated.stamp, item.stamp)
    }
}

final class TolerantSaveTests: XCTestCase {
    /// A custom stock saved before some settings existed still loads, with defaults for what's missing.
    func testOldCustomStockStillLoads() throws {
        let old = Data(#"{"id":"custom-old","name":"Beach","iso":200,"baseID":"coast","warmth":0.4}"#.utf8)
        let stock = try CustomStock.tolerant(from: old)
        XCTAssertEqual(stock.name, "Beach"); XCTAssertEqual(stock.warmth, 0.4); XCTAssertEqual(stock.grain, 1)
        let list = try CustomStock.tolerantList(from: Data("[\(String(decoding: old, as: UTF8.self))]".utf8))
        XCTAssertEqual(list.first?.id, "custom-old")
    }

    /// A recipe whose stock copy lacks a setting still reads, and keeps its real settings.
    func testRecipeWithOlderStockCopyStillReads() throws {
        let json = #"{"exposure":0,"grainAmount":1.7,"halation":true,"flare":true,"dateStamp":false,"frame":"white","date":800000000,"sceneReferred":true,"customStock":{"id":"custom-old","baseID":"honey"}}"#
        let r = try DevelopOptions.tolerant(from: Data(json.utf8), defaults: DevelopOptions())
        XCTAssertEqual(r.grainAmount, 1.7); XCTAssertEqual(r.frame, .white)
        XCTAssertEqual(r.customStock?.id, "custom-old"); XCTAssertEqual(r.customStock?.name, "My Stock")
    }

    /// An unreadable recipe makes a re-develop stop, never overwrite the frame with blank settings.
    func testUnreadableRecipeThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let roll = RollStore(folder: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try roll.add(DevelopResult(jpeg: Data([1]), negative: Data([2]), options: DevelopOptions(), depth: nil), stock: .honey)
        try Data("not json".utf8).write(to: item.recipeURL)
        XCTAssertThrowsError(try roll.readRecipe(for: item))
    }
}

@MainActor
final class AppFlowTests: XCTestCase {
    private func makeModel() async throws -> (AppModel, RollItem, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(roll: RollStore(folder: dir))
        var o = DevelopOptions(); o.aspect = .r3x2; o.grainAmount = 0; o.date = Date(timeIntervalSince1970: 1_800_000_000)
        let scene = SimulatedScene.capture.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let result = try await Darkroom.shared.develop(CapturedFrame(source: .image(scene, sceneReferred: false), metadata: [:]), stock: .honey, options: o)
        let item = try model.roll.add(result, stock: .honey)
        return (model, item, dir)
    }

    /// Two edits started back to back run in order, and the second starts from the first's result: the stock
    /// change survives the push edit that follows it.
    func testRedevelopsOfOneFrameRunInOrder() async throws {
        let (model, item, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        async let first = model.reprint(item, stock: .coast, syncPhotos: false)
        async let second = model.reprint(item, syncPhotos: false) { $0.pushPull = 1 }
        _ = try await (first, second)
        let now = try XCTUnwrap(model.roll.item(id: item.id))
        XCTAssertEqual(now.stockID, "coast")
        XCTAssertEqual(model.roll.recipe(for: now).pushPull, 1)
        let prints = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(item.base) && $0.hasSuffix(".jpg") }
        XCTAssertEqual(prints.count, 1, "exactly one print per frame")
    }

    /// A frame deleted while it's being re-developed stays deleted.
    func testDeletedWhileDevelopingStaysDeleted() async throws {
        let (model, item, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        let work = Task { try await model.reprint(item, stock: .coast, syncPhotos: false) }
        model.roll.delete(item)
        _ = await work.result
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(item.base) }
        XCTAssertTrue(left.isEmpty, "nothing written back: \(left)")
    }

    /// An edit to a frame saved in Photos is remembered on disk until Photos has it.
    func testPhotosUpdateIsRememberedOnDisk() async throws {
        let (model, item, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.roll.setPhotosID("ASSET", for: item)
        try await model.reprint(item, syncPhotos: false) { $0.pushPull = 0.5 }
        XCTAssertEqual(model.roll.photosStaleItems().map(\.id), [item.id])
    }

    /// If a panorama's first shot can't be taken, panorama mode isn't left half-started with the camera locked.
    func testFailedFirstPanoShotLeavesNoPanorama() async throws {
        let (model, _, dir) = try await makeModel()
        defer { try? FileManager.default.removeItem(at: dir) }
        model.panoShot()                        // the camera isn't running in tests, so the capture fails
        for _ in 0..<50 where model.pano != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(model.pano)
        XCTAssertFalse(model.captureBusy)
    }
}
