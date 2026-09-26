import XCTest
import CoreGraphics
import CoreText
@testable import MaskKit

/// The guard's decision half is tested without Vision (that is where a policy bug would live); the Vision half
/// asserts the one pair that matters — it FIRES on legible rendered text and stays SILENT on the same text
/// blurred past legibility. A guard that fires on unreadable text freezes exactly the fixes the generative tier
/// exists for (measured: −0.02…−0.07 F1 on SA-Text when lines were protected on uncertain reads).
final class TextLegibilityGuardTests: XCTestCase {

    // MARK: - Decision (no Vision)

    func testCertainWordsAreProtectedAndUncertainLinesAreNot() {
        let certain = line(y: 10, confidence: 1.0, words: [("STOP", 10, 100), ("AHEAD", 120, 260)])
        let uncertain = line(y: 100, confidence: 0.5, words: [("PARKING", 10, 200)])
        let v = TextLegibilityGuard.verdict(regions: [certain, uncertain], width: 400, height: 200, policy: .default)
        XCTAssertEqual(v.protected.count, 2, "both certain words, neither uncertain word")
        XCTAssertEqual(v.recommendation, .generative, "word protection is OFF by default — measured net-negative off dense legible pages")
        XCTAssertTrue(v.firesOnText, "the certain words are still reported")
        let on = TextLegibilityGuard.verdict(regions: [certain, uncertain], width: 400, height: 200,
                                             policy: .init(wordProtection: true))
        XCTAssertEqual(on.recommendation, .protectWords, "opt-in turns the composite route on")
        XCTAssertEqual(v.certainLineShare, 0.5, accuracy: 1e-9)
        XCTAssertEqual(v.protected[0].boundingBox.minX, 10)
        XCTAssertEqual(v.protected[1].boundingBox.maxX, 260)
    }

    func testNothingRecognisedMeansGenerative() {
        let v = TextLegibilityGuard.verdict(regions: [], width: 100, height: 100, policy: .default)
        XCTAssertFalse(v.firesOnText)
        XCTAssertEqual(v.recommendation, .generative)
        XCTAssertEqual(v.certainLineShare, 0)
        XCTAssertEqual(v.protectedCoverage, 0)
    }

    func testDebrisAndSingleCharactersAreNotProtected() {
        let l = line(y: 10, confidence: 1.0, words: [("A", 10, 30), ("-", 40, 50), ("27", 60, 100), ("x.", 110, 130)])
        let v = TextLegibilityGuard.verdict(regions: [l], width: 400, height: 100, policy: .default)
        XCTAssertEqual(v.protected.count, 1, "only '27' has two alphanumerics")
        XCTAssertEqual(v.protected[0].boundingBox.minX, 60)
    }

    func testLineGranularityProtectsTheLineQuad() {
        let l = line(y: 10, confidence: 1.0, words: [("STOP", 10, 100), ("AHEAD", 120, 260)])
        let v = TextLegibilityGuard.verdict(regions: [l], width: 400, height: 100, policy: .init(granularity: .line))
        XCTAssertEqual(v.protected, [l.quad])
    }

    func testDocumentGateRecommendsTheBaseTier() {
        var lines: [TextRegion] = []
        for i in 0..<6 { lines.append(line(y: CGFloat(10 + i * 30), confidence: 1.0, words: [("WORD", 10, 80), ("MORE", 100, 170)])) }
        let v = TextLegibilityGuard.verdict(regions: lines, width: 400, height: 300, policy: .default)
        XCTAssertTrue(v.isDocumentPage, "12 certain words on all-certain lines is a document page — a reported fact")
        XCTAssertEqual(v.recommendation, .generative, "the gate is opt-in: a document page routes generative by default (SeedVR2 ×2 read better than the base on every dense page measured)")

        let gated = TextLegibilityGuard.verdict(regions: lines, width: 400, height: 300, policy: .init(documentGate: true))
        XCTAssertEqual(gated.recommendation, .keepBase, "opting into the gate routes the page to the base tier")

        let off = TextLegibilityGuard.verdict(regions: lines, width: 400, height: 300,
                                              policy: .init(documentGate: true, documentMinimumWords: Int.max))
        XCTAssertFalse(off.isDocumentPage)
        XCTAssertEqual(off.recommendation, .generative, "gate on but the page does not qualify → generative")
        XCTAssertEqual(TextLegibilityGuard.verdict(regions: lines, width: 400, height: 300,
                                                   policy: .init(wordProtection: true, documentMinimumWords: Int.max)).recommendation,
                       .protectWords)

        // Half the lines uncertain → below the certain share → no document gate, words still protected.
        let mixed = lines + (0..<6).map { line(y: CGFloat(200 + $0 * 10), confidence: 0.5, words: [("BLUR", 10, 80)]) }
        let m = TextLegibilityGuard.verdict(regions: mixed, width: 400, height: 300, policy: .init(documentGate: true))
        XCTAssertEqual(m.certainLineShare, 0.5, accuracy: 1e-9)
        XCTAssertTrue(m.isDocumentPage, "share exactly at the floor still counts")
        XCTAssertEqual(m.recommendation, .keepBase)
        XCTAssertEqual(m.protected.count, 12)
    }

    // MARK: - Mask

    func testMaskScalesWithTheOutputSize() throws {
        let l = line(y: 10, confidence: 1.0, words: [("STOP", 10, 50)])   // word quad x 10…50, y 10…30 at 100×100
        let v = TextLegibilityGuard.verdict(regions: [l], width: 100, height: 100, policy: .default)
        let mask = try TextLegibilityGuard.mask(for: v, width: 400, height: 400)
        let plane = try TextLegibilityGuard.gray(mask)
        XCTAssertEqual(mask.width, 400); XCTAssertEqual(mask.height, 400)
        // ×4: the word is x 40…200, y 40…120 (80 px tall) → dilation 0.5·80 = 40 px, feather σ 12.
        XCTAssertGreaterThan(plane[80 * 400 + 120], 250, "centre of the ×4-scaled word is white")
        XCTAssertGreaterThan(plane[80 * 400 + 10], 200, "dilation is proportional to the glyph height (40 px), not a fixed few pixels")
        XCTAssertEqual(plane[380 * 400 + 350], 0, "far from the word is black")
        // Down the centre column below the word: dilated edge at y 160, then a feathered ramp to black.
        let ramp = Set((150...220).map { plane[$0 * 400 + 120] })
        XCTAssertGreaterThan(ramp.count, 3, "the boundary is a ramp, not a step: \(ramp.sorted())")
        XCTAssertEqual(plane[300 * 400 + 120], 0, "and it reaches black well before the far edge")
    }

    // MARK: - Composite

    func testCompositeTakesTheBaseInsideAndTheGenerativeOutside() throws {
        let base = try solid(width: 64, height: 32, r: 255, g: 0, b: 0)
        let gen = try solid(width: 64, height: 32, r: 0, g: 0, b: 255)
        var plane = [Float](repeating: 0, count: 64 * 32)
        for y in 0..<32 { for x in 0..<32 { plane[y * 64 + x] = 1 } }        // left half protected
        let mask = try TextMaskDetector.grayImage(plane, width: 64, height: 32)
        let out = try TextLegibilityGuard.rgba(try TextLegibilityGuard.composite(base: base, generative: gen, mask: mask))
        XCTAssertEqual(Array(out[(10 * 64 + 5) * 4 ..< (10 * 64 + 5) * 4 + 3]), [255, 0, 0], "inside the mask = base")
        XCTAssertEqual(Array(out[(10 * 64 + 60) * 4 ..< (10 * 64 + 60) * 4 + 3]), [0, 0, 255], "outside = generative")
        XCTAssertThrowsError(try TextLegibilityGuard.composite(base: base, generative: gen,
                                                               mask: try TextMaskDetector.grayImage([Float](repeating: 0, count: 16), width: 4, height: 4)))
    }

    // MARK: - Vision, end to end: what it fires on

    func testFiresOnLegibleTextAndStaysSilentWhenTheSameTextIsUnreadable() throws {
        let crisp = try textImage(width: 900, height: 300, text: "STOP AHEAD", fontSize: 90)
        let v = try TextLegibilityGuard.assess(crisp)
        try XCTSkipIf(v.regions.isEmpty, "Vision produced no observations in this environment")
        XCTAssertTrue(v.firesOnText)
        XCTAssertGreaterThanOrEqual(v.protected.count, 2, "two crisp words → two protected word quads, got \(v.protected.count)")
        XCTAssertEqual(v.recommendation, .generative, "two words are not a document page, and word protection is opt-in")
        XCTAssertEqual(try TextLegibilityGuard.assess(crisp, policy: .init(wordProtection: true)).recommendation, .protectWords)
        XCTAssertLessThan(v.protectedCoverage, 0.5, "a region, not the frame")
        let mask = try TextLegibilityGuard.mask(for: v, width: 900, height: 300)
        let plane = try TextLegibilityGuard.gray(mask)
        let centre = v.protected[0].boundingBox
        XCTAssertGreaterThan(plane[Int(centre.midY) * 900 + Int(centre.midX)], 250, "the mask is white over the word")

        let unreadable = try smeared(crisp, factor: 24)
        let u = try TextLegibilityGuard.assess(unreadable)
        XCTAssertFalse(u.firesOnText,
                       "unreadable text must not be protected — that freezes the generative tier's fixes; protected=\(u.protected.count) regions=\(u.regions.map { ($0.transcript ?? "", $0.confidence) })")
        XCTAssertEqual(u.recommendation, .generative)
    }

    // MARK: - Fixtures

    private func line(y: CGFloat, confidence: Float, words: [(String, CGFloat, CGFloat)]) -> TextRegion {
        let x0 = words.map(\.1).min() ?? 0, x1 = words.map(\.2).max() ?? 0
        return TextRegion(quad: quad(x0: x0, x1: x1, y0: y, y1: y + 20),
                          transcript: words.map(\.0).joined(separator: " "), confidence: confidence, source: .recognition,
                          words: words.map { TextWord(text: $0.0, quad: quad(x0: $0.1, x1: $0.2, y0: y, y1: y + 20)) })
    }

    private func quad(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat) -> TextQuad {
        TextQuad(topLeft: CGPoint(x: x0, y: y0), topRight: CGPoint(x: x1, y: y0),
                 bottomRight: CGPoint(x: x1, y: y1), bottomLeft: CGPoint(x: x0, y: y1))
    }

    private func solid(width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TextLegibilityGuard.GuardError.rasterFailed }
        // In the context's own (sRGB) space — a generic-RGB CGColor would be converted on draw and read back as 255/38/0.
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [r / 255, g / 255, b / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw TextLegibilityGuard.GuardError.rasterFailed }
        return image
    }

    private func textImage(width: Int, height: Int, text: String, fontSize: CGFloat) throws -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TextLegibilityGuard.GuardError.rasterFailed }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .init("NSFont" as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ] as [NSAttributedString.Key: Any])
        ctx.textPosition = CGPoint(x: 40, y: CGFloat(height) * 0.5 - fontSize / 2)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
        guard let image = ctx.makeImage() else { throw TextLegibilityGuard.GuardError.rasterFailed }
        return image
    }

    /// Destroy legibility by resampling down by `factor` and back up — the glyphs become blobs.
    private func smeared(_ image: CGImage, factor: Int) throws -> CGImage {
        func resample(_ img: CGImage, _ w: Int, _ h: Int) throws -> CGImage {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw TextLegibilityGuard.GuardError.rasterFailed }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let out = ctx.makeImage() else { throw TextLegibilityGuard.GuardError.rasterFailed }
            return out
        }
        let small = try resample(image, max(1, image.width / factor), max(1, image.height / factor))
        return try resample(small, image.width, image.height)
    }
}
