import XCTest
import CoreGraphics
import CoreText
import Vision
@testable import MaskKit

/// N7 — automatic text masks. The geometry half is tested deterministically (it is where the bugs
/// live); the Vision half is tested end-to-end against rendered text, because the two claims worth
/// proving — that the coordinate flip is right and that the `minimumTextHeight` trap is defused —
/// can only be shown by running the real detector.
final class TextMaskDetectorTests: XCTestCase {

    // MARK: - Tiling

    func testSmallImageIsASingleTile() {
        let tiles = TextMaskDetector.tileGrid(width: 800, height: 600, tileSize: 1024, overlap: 0.15)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles[0], CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// Every pixel must land in at least one tile — a gap is a stripe of the image where text is
    /// silently never looked for, which is the same silent-failure class as the height trap itself.
    func testTileGridCoversEveryPixel() {
        let width = 2600, height = 1500
        let tiles = TextMaskDetector.tileGrid(width: width, height: height, tileSize: 1024, overlap: 0.15)
        XCTAssertGreaterThan(tiles.count, 1)

        var covered = [Bool](repeating: false, count: width * height)
        for tile in tiles {
            for y in Int(tile.minY)..<Int(tile.maxY) {
                for x in Int(tile.minX)..<Int(tile.maxX) { covered[y * width + x] = true }
            }
        }
        XCTAssertFalse(covered.contains(false), "the tile grid left a gap")
    }

    /// No undersized tile: a short tile would change the derived minimum-height fraction and quietly
    /// apply a different detection threshold near the border.
    func testEveryTileIsFullSizeAndInBounds() {
        let width = 2600, height = 1500, size = 1024
        for tile in TextMaskDetector.tileGrid(width: width, height: height, tileSize: size, overlap: 0.15) {
            XCTAssertEqual(Int(tile.width), size)
            XCTAssertEqual(Int(tile.height), size)
            XCTAssertGreaterThanOrEqual(tile.minX, 0)
            XCTAssertGreaterThanOrEqual(tile.minY, 0)
            XCTAssertLessThanOrEqual(Int(tile.maxX), width)
            XCTAssertLessThanOrEqual(Int(tile.maxY), height)
        }
    }

    func testTilesOverlap() {
        let tiles = TextMaskDetector.tileGrid(width: 2600, height: 1024, tileSize: 1024, overlap: 0.15)
        let xs = Set(tiles.map(\.minX)).sorted()
        XCTAssertGreaterThan(xs.count, 1)
        for i in 1..<xs.count {
            XCTAssertLessThan(xs[i] - xs[i - 1], 1024, "consecutive tiles must overlap")
        }
    }

    // MARK: - Merge

    func testIoU() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(TextMaskDetector.iou(a, a), 1.0, accuracy: 1e-9)
        XCTAssertEqual(TextMaskDetector.iou(a, CGRect(x: 20, y: 20, width: 10, height: 10)), 0)
        // Half-overlap: intersection 50, union 150.
        let b = CGRect(x: 5, y: 0, width: 10, height: 10)
        XCTAssertEqual(TextMaskDetector.iou(a, b), 50.0 / 150.0, accuracy: 1e-9)
    }

    func testMergeDropsDuplicatesAcrossTilesAndKeepsDistinctRegions() {
        let near = region(x: 0, y: 0, w: 100, h: 20, source: .recognition, confidence: 0.9)
        let dupe = region(x: 3, y: 1, w: 100, h: 20, source: .recognition, confidence: 0.5)
        let far = region(x: 500, y: 500, w: 100, h: 20, source: .recognition, confidence: 0.8)

        let merged = TextMaskDetector.merge([near, dupe, far], iouThreshold: 0.35)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.confidence, 0.9, "the stronger duplicate survives")
    }

    /// 🔑 The union's whole value: recognition wins a collision (keeping the transcript), while a
    /// detection-only hit with no recognition neighbour is kept (keeping the recall).
    func testRecognitionWinsCollisionsButDetectionOnlyRegionsSurvive() {
        let recognized = region(x: 0, y: 0, w: 100, h: 20, source: .recognition,
                                confidence: 0.4, transcript: "STOP")
        let sameByAppearance = region(x: 2, y: 0, w: 100, h: 20, source: .detection, confidence: 0.99)
        let blurredOnly = region(x: 400, y: 0, w: 100, h: 20, source: .detection, confidence: 0.6)

        let merged = TextMaskDetector.merge([sameByAppearance, recognized, blurredOnly],
                                            iouThreshold: 0.35)
        XCTAssertEqual(merged.count, 2)
        let collided = merged.first { $0.quad.boundingBox.minX < 10 }
        XCTAssertEqual(collided?.source, .recognition,
                       "recognition must win despite the lower confidence — it answers the stronger question")
        XCTAssertEqual(collided?.transcript, "STOP")
        XCTAssertTrue(merged.contains { $0.source == .detection },
                      "a detection-only region with no recognition neighbour must survive")
    }

    // MARK: - Quad geometry

    func testQuadAreaIsShoelaceNotBoundingBox() {
        // A 45°-rotated square with diagonal 100 → area 5000, bounding box 10000.
        let q = TextQuad(topLeft: CGPoint(x: 50, y: 0), topRight: CGPoint(x: 100, y: 50),
                         bottomRight: CGPoint(x: 50, y: 100), bottomLeft: CGPoint(x: 0, y: 50))
        XCTAssertEqual(q.area, 5000, accuracy: 1e-6)
        XCTAssertEqual(q.boundingBox, CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    /// Rotated text is the case quads exist for — an axis-aligned box over this quad would mask
    /// nearly twice the area, half of it not text.
    func testRotatedQuadFillsOnlyItself() throws {
        let q = TextQuad(topLeft: CGPoint(x: 50, y: 0), topRight: CGPoint(x: 100, y: 50),
                         bottomRight: CGPoint(x: 50, y: 100), bottomLeft: CGPoint(x: 0, y: 50))
        var plane = [Float](repeating: 0, count: 100 * 100)
        TextMaskDetector.fill(quad: q, into: &plane, width: 100, height: 100)

        XCTAssertEqual(plane[50 * 100 + 50], 1, "the centre is inside")
        XCTAssertEqual(plane[2 * 100 + 2], 0, "the top-left corner of the bounding box is outside")
        XCTAssertEqual(plane[97 * 100 + 97], 0, "and so is the bottom-right")

        let filled = plane.reduce(0) { $0 + Int($1) }
        XCTAssertEqual(Double(filled), 5000, accuracy: 250, "≈ the shoelace area, not the box's 10000")
    }

    // MARK: - Mask synthesis

    func testDilationGrowsASinglePixelIntoASquare() {
        var plane = [Float](repeating: 0, count: 21 * 21)
        plane[10 * 21 + 10] = 1
        let out = TextMaskDetector.dilate(plane, width: 21, height: 21, radius: 3)
        XCTAssertEqual(out.reduce(0) { $0 + Int($1) }, 49, "(2·3+1)² = 49")
        XCTAssertEqual(out[7 * 21 + 7], 1)
        XCTAssertEqual(out[6 * 21 + 10], 0, "one past the radius is untouched")
    }

    func testMaskIsWhiteOnTextAndFeatheredAtTheBoundary() throws {
        let q = TextQuad(topLeft: CGPoint(x: 40, y: 40), topRight: CGPoint(x: 160, y: 40),
                         bottomRight: CGPoint(x: 160, y: 80), bottomLeft: CGPoint(x: 40, y: 80))
        let regions = [TextRegion(quad: q, transcript: "TEXT", confidence: 1, source: .recognition)]
        let image = try TextMaskDetector.mask(regions: regions, width: 200, height: 120,
                                              options: .init(dilation: 4, feather: 2))
        let plane = try gray(image)

        XCTAssertGreaterThan(plane[60 * 200 + 100], 250, "white inside the region")
        XCTAssertEqual(plane[10 * 200 + 10], 0, "black far outside")

        // The boundary is a ramp, not a step — otherwise two restoration policies meet at a visible edge.
        let column = (30...50).map { plane[$0 * 200 + 100] }
        let distinct = Set(column)
        XCTAssertGreaterThan(distinct.count, 3, "the edge must be a gradient, got \(distinct.sorted())")
    }

    func testMaskWithNoRegionsIsBlack() throws {
        let image = try TextMaskDetector.mask(regions: [], width: 64, height: 64)
        XCTAssertTrue(try gray(image).allSatisfy { $0 == 0 })
    }

    // MARK: - Vision, end to end

    /// 🚨 **The coordinate flip, which is the bug this row is most likely to ship.** Vision is
    /// normalized with a bottom-left origin; this codebase is pixels with a top-left origin. Text is
    /// rendered into the visual TOP of the frame, so a detected quad whose `y` lands in the bottom half
    /// means the flip is inverted — a mask that is vertically mirrored, which reads as "the detector is
    /// bad" rather than "the conversion is wrong".
    func testDetectedRegionLandsInTheSameHalfOfTheImageAsTheText() throws {
        let height = 400
        let image = try textImage(width: 900, height: height, text: "PARKING",
                                  fontSize: 64, atTopFraction: 0.12)

        let regions = try TextMaskDetector.regions(in: image, options: .init(includeDetectionOnlyPass: false))
        try XCTSkipIf(regions.isEmpty, "Vision produced no observations in this environment")

        let best = regions.max(by: { $0.quad.area < $1.quad.area })!
        XCTAssertLessThan(best.quad.boundingBox.midY, CGFloat(height) / 2,
                          "text drawn near the top must be detected near the top")
    }

    /// 🔑 **The row's headline claim, corrected by measurement — and note what is asserted.**
    ///
    /// The plan attributed small-text failure to Vision's `minimumTextHeight` default and prescribed
    /// forcing it to ~0. Probing showed that parameter is **non-monotonic and unstable**, so this test
    /// holds it at 0 in *both* arms and varies only the tiling.
    ///
    /// ⚠️ **The whole-image arm's count is reported, never asserted, and that is deliberate.** Vision's
    /// small-text behaviour moves under trivial changes to frame size and text position — the same
    /// instability that disqualified the parameter. On this fixture it has been measured at **0 of 3**
    /// planted strings whole-image vs **3 of 3** tiled, but pinning that zero would encode an
    /// environmental accident as a contract. What *is* asserted is the pair that holds regardless:
    /// tiling never finds less, and our shipped configuration finds every planted string.
    func testTilingNeverFindsLessAndOurConfigurationFindsEverything() throws {
        let planted = ["EXIT 27B", "NO PARKING", "STOP AHEAD"]
        let image = try multiTextImage(width: 3072, height: 2048, strings: planted, fontSize: 14)

        var wholeImage = TextMaskDetector.Options(minimumTextHeightPixels: 0,
                                                  includeDetectionOnlyPass: false)
        wholeImage.tileSize = 3072
        var tiled = wholeImage
        tiled.tileSize = 1024

        let whole = try TextMaskDetector.regions(in: image, options: wholeImage)
        let split = try TextMaskDetector.regions(in: image, options: tiled)
        try XCTSkipIf(split.isEmpty, "Vision produced no observations in this environment")

        XCTAssertGreaterThanOrEqual(split.count, whole.count,
                                    "tiling must never find less: whole=\(whole.count) tiled=\(split.count)")
        XCTAssertGreaterThanOrEqual(split.count, planted.count,
                                    "the shipped configuration must find all \(planted.count) planted strings, got \(split.count)")
    }

    /// The escape-hatch parameter must not be quietly load-bearing: the default is 0 and the recall
    /// claim above does not depend on it.
    func testMinimumTextHeightDefaultsToZero() {
        XCTAssertEqual(TextMaskDetector.Options.default.minimumTextHeightPixels, 0)
    }

    func testMaskCoversTheRenderedText() throws {
        let image = try textImage(width: 900, height: 300, text: "SLOW", fontSize: 90, atTopFraction: 0.3)
        let regions = try TextMaskDetector.regions(in: image, options: .init(includeDetectionOnlyPass: false))
        try XCTSkipIf(regions.isEmpty, "Vision produced no observations in this environment")

        let mask = try TextMaskDetector.mask(for: image, options: .init(includeDetectionOnlyPass: false))
        let plane = try gray(mask)
        let lit = plane.filter { $0 > 128 }.count
        XCTAssertGreaterThan(lit, 0)
        XCTAssertLessThan(Double(lit) / Double(plane.count), 0.5,
                          "the mask must be a region, not most of the frame")
    }

    // MARK: - Fixtures

    private func region(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                        source: TextRegion.Source, confidence: Float,
                        transcript: String? = nil) -> TextRegion {
        TextRegion(quad: TextQuad(topLeft: CGPoint(x: x, y: y),
                                  topRight: CGPoint(x: x + w, y: y),
                                  bottomRight: CGPoint(x: x + w, y: y + h),
                                  bottomLeft: CGPoint(x: x, y: y + h)),
                   transcript: transcript, confidence: confidence, source: source)
    }

    private func gray(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw TextMaskDetector.DetectorError.rasterFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    /// Several strings at one size, spread across the frame — the fixture the tiling measurement in
    /// `TextMaskDetector`'s type comment was taken on.
    private func multiTextImage(width: Int, height: Int, strings: [String],
                                fontSize: CGFloat) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TextMaskDetector.DetectorError.rasterFailed
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        for (index, string) in strings.enumerated() {
            let attributed = NSAttributedString(string: string, attributes: [
                .init("NSFont" as String): font,
                .init(kCTForegroundColorAttributeName as String): black,
            ] as [NSAttributedString.Key: Any])
            let x: CGFloat = CGFloat(60 + index * 400)
            let y: CGFloat = CGFloat(height) * CGFloat(0.25 + 0.25 * Double(index))
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        }
        guard let image = ctx.makeImage() else { throw TextMaskDetector.DetectorError.rasterFailed }
        return image
    }

    /// Black text on white, drawn with CoreText so the test target stays AppKit-free.
    /// `atTopFraction` is measured from the **visual top**, in this codebase's convention — the whole
    /// point of the flip test, so it must not be expressed in CoreGraphics' bottom-up terms.
    private func textImage(width: Int, height: Int, text: String,
                           fontSize: CGFloat, atTopFraction: CGFloat) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw TextMaskDetector.DetectorError.rasterFailed
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .init("NSFont" as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ] as [NSAttributedString.Key: Any])
        let line = CTLineCreateWithAttributedString(attributed)

        // CGContext is bottom-up; convert the top-relative position the test asked for.
        let yFromBottom = CGFloat(height) * (1 - atTopFraction) - fontSize
        ctx.textPosition = CGPoint(x: 40, y: yFromBottom)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else { throw TextMaskDetector.DetectorError.rasterFailed }
        return image
    }
}

