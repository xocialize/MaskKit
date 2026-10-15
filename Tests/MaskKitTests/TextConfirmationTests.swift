//
// TextConfirmationTests.swift — MaskKit
//
// The word-confirmation step (`TextLegibilityGuard.confirm`): an agreement ensemble that keeps only the certain
// Vision words a second reader also read. Pure functions, no Vision.
//

import CoreGraphics
import XCTest
@testable import MaskKit

final class TextConfirmationTests: XCTestCase {

    private func quad(_ x: CGFloat) -> TextQuad {
        TextQuad(topLeft: CGPoint(x: x, y: 0), topRight: CGPoint(x: x + 10, y: 0),
                 bottomRight: CGPoint(x: x + 10, y: 8), bottomLeft: CGPoint(x: x, y: 8))
    }

    private func region(_ words: [String], confidence: Float) -> TextRegion {
        TextRegion(quad: quad(0), transcript: words.joined(separator: " "), confidence: confidence, source: .recognition,
                   words: words.enumerated().map { TextWord(text: $1, quad: quad(CGFloat($0) * 12)) })
    }

    private var policy: TextLegibilityGuard.Policy {
        var p = TextLegibilityGuard.Policy.default
        p.wordProtection = true
        p.wordConfirmation = true
        return p
    }

    func testKeepsOnlyAgreedCertainWords() {
        let regions = [region(["STOP", "AHEAD"], confidence: 1.0), region(["SLOW", "ZONE"], confidence: 0.3)]
        let v = TextLegibilityGuard.verdict(regions: regions, width: 100, height: 100, policy: policy)
        XCTAssertEqual(v.protected.count, 2, "Vision alone: the two certain words")
        XCTAssertNil(v.confirmed)
        let c = TextLegibilityGuard.confirm(v, with: ["stop sign", "zone"], policy: policy)
        XCTAssertEqual(c.protected, [regions[0].words[0].quad], "only STOP is certain AND read by the second reader")
        XCTAssertEqual(c.confirmed?.words, 1)
        XCTAssertEqual(c.confirmed?.ofCertain, 2)
        XCTAssertEqual(c.recommendation, .protectWords)
    }

    func testNormalisationIsUpperAsciiAlphanumeric() {
        let v = TextLegibilityGuard.verdict(regions: [region(["Mummie,", "I'll", "Café"], confidence: 1.0)],
                                            width: 100, height: 100, policy: policy)
        let c = TextLegibilityGuard.confirm(v, with: ["mummie ill caf"], policy: policy)
        XCTAssertEqual(c.protected.count, 3, "punctuation and non-ASCII letters are stripped on both sides")
    }

    func testMultisetConsumesOneConfirmationPerWord() {
        let v = TextLegibilityGuard.verdict(regions: [region(["5", "5", "5"], confidence: 1.0)],
                                            width: 100, height: 100, policy: policy)
        // minimumWordLength 2 drops single digits; use two-character words instead
        let v2 = TextLegibilityGuard.verdict(regions: [region(["AB", "AB", "AB"], confidence: 1.0)],
                                             width: 100, height: 100, policy: policy)
        XCTAssertEqual(v.protected.count, 0)
        let c = TextLegibilityGuard.confirm(v2, with: ["ab", "ab"], policy: policy)
        XCTAssertEqual(c.protected.count, 2, "two reads confirm two of the three words, not all three")
    }

    func testNothingAgreedFallsBackToGenerative() {
        let v = TextLegibilityGuard.verdict(regions: [region(["STOP"], confidence: 1.0)], width: 100, height: 100, policy: policy)
        let c = TextLegibilityGuard.confirm(v, with: ["a lion's face"], policy: policy)
        XCTAssertTrue(c.protected.isEmpty)
        XCTAssertEqual(c.confirmed?.words, 0)
        XCTAssertEqual(c.recommendation, .generative, "no agreed word → nothing to protect → the generative route")
    }

    func testOffPolicyOrLineGranularityIsUntouched() {
        var off = policy; off.wordConfirmation = false
        let v = TextLegibilityGuard.verdict(regions: [region(["STOP"], confidence: 1.0)], width: 100, height: 100, policy: off)
        XCTAssertEqual(TextLegibilityGuard.confirm(v, with: [], policy: off), v)
        var line = policy; line.granularity = .line
        let vl = TextLegibilityGuard.verdict(regions: [region(["STOP"], confidence: 1.0)], width: 100, height: 100, policy: line)
        XCTAssertEqual(TextLegibilityGuard.confirm(vl, with: [], policy: line), vl)
        XCTAssertNil(TextLegibilityGuard.confirm(vl, with: [], policy: line).confirmed)
    }

    func testDocumentPageFactIsUnchangedByConfirmation() {
        let words = (0..<12).map { "WORD\($0)" }
        let v = TextLegibilityGuard.verdict(regions: [region(words, confidence: 1.0)], width: 100, height: 100, policy: policy)
        XCTAssertTrue(v.isDocumentPage)
        let c = TextLegibilityGuard.confirm(v, with: [], policy: policy)
        XCTAssertTrue(c.isDocumentPage, "confirmation narrows the protected set; it does not re-decide whether the frame is a page")
    }
}
