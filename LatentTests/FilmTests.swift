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

        let archive = try RollArchive.export(from: src)
        XCTAssertEqual(try RollArchive.importArchive(archive, into: dst), files.count)
        for (n, d) in files { XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent(n)), d, n) }
        XCTAssertEqual(try RollArchive.importArchive(archive, into: dst), 0, "existing files are kept, not duplicated")
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
        XCTAssertEqual(try RollArchive.importArchive(url, into: dst), 0)
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
