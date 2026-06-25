import XCTest
import CoreGraphics
@testable import MaskKit

final class MaskKitTests: XCTestCase {
    func testEmptyPrompt() {
        XCTAssertTrue(MaskPrompt().isEmpty)
        XCTAssertFalse(MaskPrompt.click(x: 5, y: 5).isEmpty)
        XCTAssertFalse(MaskPrompt(box: CGRect(x: 0, y: 0, width: 4, height: 4)).isEmpty)
    }

    func testClickIsPositivePoint() {
        let p = MaskPrompt.click(x: 12, y: 8)
        XCTAssertEqual(p.points.count, 1)
        XCTAssertEqual(p.points[0].x, 12); XCTAssertEqual(p.points[0].y, 8)
        XCTAssertTrue(p.points[0].include)
        XCTAssertNil(p.box)
    }

    func testIncludeExcludeAndBox() {
        let p = MaskPrompt(points: [MaskPoint(x: 1, y: 1), MaskPoint(x: 9, y: 9, include: false)],
                           box: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(p.points.filter { $0.include }.count, 1)
        XCTAssertEqual(p.points.filter { !$0.include }.count, 1, "negative click carries through")
        XCTAssertEqual(p.box?.width, 10)
    }

    /// A stub provider conforms to the seam (the contract Extract/Erase + the engine adapter share).
    func testProviderSeamConforms() async throws {
        struct Stub: PromptMaskProvider {
            let name = "stub"
            func mask(_ image: CGImage, prompt: MaskPrompt) async throws -> CGImage { image }
        }
        var b = [UInt8](repeating: 128, count: 16)
        let img = CGContext(data: &b, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        let out = try await Stub().mask(img, prompt: .click(x: 2, y: 2))
        XCTAssertEqual(out.width, 4)
    }
}
