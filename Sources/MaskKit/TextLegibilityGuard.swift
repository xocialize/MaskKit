//
// TextLegibilityGuard.swift — MaskKit
//
// The text-legibility guard in front of a GENERATIVE restoration/upscale tier (SeedVR2, VOSR2 …).
//
// What was measured (2026-09-26, VOSR-EVAL §10–§11; receipts in `mlxengine-forge/Tools/vosr-gates/`):
//   • a generative tier reads MORE words correctly than its input in every set, including lines the input
//     already reads at Vision confidence 1.0 — it fixes wrong words at least as often as it breaks right ones;
//   • but ~10 % of the words the input reads *confidently and correctly* come back as plausible WRONG words
//     ("Mummie" → "Manunie", "dragging" → "drugging"). For signage that is the failure that matters: a soft price
//     is fine, a sharp wrong one is not (the N7 rule: an honestly-blurry STOP beats a razor-sharp SIOP);
//   • Vision's recognition confidence is effectively BINARY (0.3/0.5 uncertain, 1.0 certain), and on degraded
//     input a third of its "certain" reads are wrong;
//   • 🚨 compositing protected words (or lines) back into a generatively-sharpened frame is ITSELF a
//     degradation: the recognizer reads lines in context, and a mixed-fidelity line reads worse than either
//     uniform version. On inputs whose certain reads are mostly wrong (SA-Text lv1) that TRIPLED corruption
//     (23 → 66–97) and cost 0.06–0.07 F1; on dense legible pages (ScreenSR) it cut corruption 59 → 22 but still
//     lost fixes. Glyph-proportional dilation narrows the damage (97 → 66) without removing it;
//   • the image-level DOCUMENT GATE is the policy that is safe everywhere: it never fired on the illegible sets
//     (0 / 1,200 images) and, on the legible pages it routes to the base tier, corruption fell 59 → 3.
//
// Hence the defaults: **document gate on, word protection OFF.** `Policy.wordProtection = true` turns the
// composite route on for a caller who has measured it on their content (dense legible text at ×1 is where it
// pays). The verdict always reports the certain words, so a UI can show what would be protected.
//
// Doctrine: category A (Vision + CoreGraphics only, CPU, macOS 14). The composite here is the CGImage reference
// path; an app blends its own GPU-resident buffers with the mask this type produces.
//

import CoreGraphics
import Foundation

public enum TextLegibilityGuard {

    public enum GuardError: Error, Equatable {
        case rasterFailed
        case sizeMismatch
    }

    public struct Policy: Sendable {
        public enum Granularity: String, Sendable { case word, line }
        /// Protect per word (default — measured) or per line.
        public var granularity: Granularity
        /// Vision's "certain" level. The value is effectively binary; anything below 0.9 is an uncertain read
        /// that the generative tier improves more often than it damages.
        public var minimumConfidence: Float
        /// Alphanumeric characters a word needs to count as text worth protecting (drops punctuation debris).
        public var minimumWordLength: Int
        /// Route certain words to the base tier under a feathered mask (`.protectWords`). **Off by default —
        /// measured net-negative on inputs whose certain reads are mostly wrong** (see the type comment); turn it
        /// on for content you have measured (dense legible text at ×1 is where it pays).
        public var wordProtection: Bool
        /// Mask growth and feather as FRACTIONS of the protected quads' mean height (glyph-proportional — a fixed
        /// few pixels let the seam cut through ascenders and descenders; measured 97 → 66 corruptions on SA-Text lv1
        /// going from 4 px to 0.5 × height). `minimumDilation`/`minimumFeather` are the floors in source pixels.
        public var dilationFraction: Double
        public var featherFraction: Double
        public var minimumDilation: Int
        public var minimumFeather: Double
        /// Document gate: when this many certain words are found AND at least `documentCertainShare` of the
        /// detected lines are certain, the frame is a legible document — recommend the base tier for the
        /// whole frame instead of a word-level patchwork. `documentMinimumWords = Int.max` disables it.
        public var documentMinimumWords: Int
        public var documentCertainShare: Double
        /// Detector options. Recognition only: legibility is a recognition question, and the detection-only
        /// pass exists for the opposite purpose (finding text that could NOT be read).
        public var detector: TextMaskDetector.Options

        public init(granularity: Granularity = .word,
                    minimumConfidence: Float = 0.9,
                    minimumWordLength: Int = 2,
                    wordProtection: Bool = false,
                    dilationFraction: Double = 0.5,
                    featherFraction: Double = 0.15,
                    minimumDilation: Int = 4,
                    minimumFeather: Double = 2.0,
                    documentMinimumWords: Int = 10,
                    documentCertainShare: Double = 0.5,
                    detector: TextMaskDetector.Options = .init(includeDetectionOnlyPass: false)) {
            self.granularity = granularity
            self.minimumConfidence = minimumConfidence
            self.minimumWordLength = minimumWordLength
            self.wordProtection = wordProtection
            self.dilationFraction = dilationFraction
            self.featherFraction = featherFraction
            self.minimumDilation = minimumDilation
            self.minimumFeather = minimumFeather
            self.documentMinimumWords = documentMinimumWords
            self.documentCertainShare = documentCertainShare
            self.detector = detector
        }

        public static let `default` = Policy()
    }

    /// What the guard found on the INPUT, before any generative work runs.
    public struct Verdict: Sendable, Equatable {
        /// Every recognised line (source `.recognition`), as the detector reported it.
        public var regions: [TextRegion]
        /// The quads to protect — words (or lines) the input reads at the policy's confidence.
        public var protected: [TextQuad]
        /// Certain lines / all recognised lines (0 when nothing was recognised).
        public var certainLineShare: Double
        /// Whether the policy that produced this verdict routes certain words to the base tier.
        public var wordProtection: Bool
        /// Source image size, so the mask can be rendered at any output scale.
        public var width: Int
        public var height: Int
        /// True when the frame reads as a legible document page under the policy's document gate.
        public var isDocumentPage: Bool

        public var firesOnText: Bool { !protected.isEmpty }
        /// Fraction of the frame the protected quads cover (before dilation).
        public var protectedCoverage: Double {
            guard width > 0, height > 0 else { return 0 }
            let area = protected.reduce(0.0) { $0 + Double($1.area) }
            return min(1.0, area / Double(width * height))
        }
        /// The recommendation a planner acts on.
        public enum Recommendation: String, Sendable { case generative, protectWords, keepBase }
        /// `.keepBase` for a legible document page; `.protectWords` only when the policy opted in AND certain words
        /// exist; otherwise `.generative` — the measured default (the generative tier fixes more than it breaks
        /// everywhere except dense legible pages, and those are what the document gate catches).
        public var recommendation: Recommendation {
            if isDocumentPage { return .keepBase }
            return (wordProtection && !protected.isEmpty) ? .protectWords : .generative
        }
    }

    // MARK: - Assess

    /// Read the input and decide what to protect. Runs Vision recognition (tiled, per `policy.detector`).
    public static func assess(_ image: CGImage, policy: Policy = .default) throws -> Verdict {
        var options = policy.detector
        options.includeDetectionOnlyPass = false
        let regions = try TextMaskDetector.regions(in: image, options: options)
            .filter { $0.source == .recognition }
        return verdict(regions: regions, width: image.width, height: image.height, policy: policy)
    }

    /// The decision half, split out so it is testable without Vision.
    static func verdict(regions: [TextRegion], width: Int, height: Int, policy: Policy) -> Verdict {
        let certain = regions.filter { $0.confidence >= policy.minimumConfidence }
        var protected: [TextQuad] = []
        var certainWords = 0
        for region in certain {
            switch policy.granularity {
            case .line:
                if alphanumerics(region.transcript ?? "") >= policy.minimumWordLength { protected.append(region.quad) }
                certainWords += (region.transcript ?? "").split(whereSeparator: \.isWhitespace)
                    .filter { alphanumerics(String($0)) >= policy.minimumWordLength }.count
            case .word:
                let words = region.words.filter { alphanumerics($0.text) >= policy.minimumWordLength }
                protected += words.map(\.quad)
                certainWords += words.count
            }
        }
        let share = regions.isEmpty ? 0 : Double(certain.count) / Double(regions.count)
        let isDocument = certainWords >= policy.documentMinimumWords && share >= policy.documentCertainShare
        return Verdict(regions: regions, protected: protected, certainLineShare: share,
                       wordProtection: policy.wordProtection,
                       width: width, height: height, isDocumentPage: isDocument)
    }

    static func alphanumerics(_ s: String) -> Int {
        s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
    }

    // MARK: - Mask

    /// The protect mask at the OUTPUT size — **white = protect (use the base tier)**. `width`/`height` may be
    /// a multiple of the verdict's source size (an ×N upscale): the quads scale with it, the dilation and
    /// feather are applied on the source grid and scaled too, so the ramp is the same fraction of a glyph
    /// at every output size.
    public static func mask(for verdict: Verdict, width: Int, height: Int,
                            policy: Policy = .default) throws -> CGImage {
        guard verdict.width > 0, verdict.height > 0, width > 0, height > 0 else { throw GuardError.sizeMismatch }
        let sx = CGFloat(width) / CGFloat(verdict.width), sy = CGFloat(height) / CGFloat(verdict.height)
        let scale = max(sx, sy)
        let regions = verdict.protected.map { q in
            TextRegion(quad: TextQuad(topLeft: scaled(q.topLeft, sx, sy), topRight: scaled(q.topRight, sx, sy),
                                      bottomRight: scaled(q.bottomRight, sx, sy), bottomLeft: scaled(q.bottomLeft, sx, sy)),
                       transcript: nil, confidence: 1, source: .recognition)
        }
        // Glyph-proportional growth: from the protected quads' mean height at the OUTPUT scale, floored at the
        // policy's pixel minimums (scaled too, so the ramp is the same fraction of a glyph at every output size).
        let heights = regions.map { Double($0.quad.boundingBox.height) }
        let meanHeight = heights.isEmpty ? 0 : heights.reduce(0, +) / Double(heights.count)
        var options = policy.detector
        options.dilation = max(Int((Double(policy.minimumDilation) * Double(scale)).rounded()),
                               Int((policy.dilationFraction * meanHeight).rounded()))
        options.feather = max(policy.minimumFeather * Double(scale), policy.featherFraction * meanHeight)
        return try TextMaskDetector.mask(regions: regions, width: width, height: height, options: options)
    }

    private static func scaled(_ p: CGPoint, _ sx: CGFloat, _ sy: CGFloat) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }

    // MARK: - Composite (CPU reference)

    /// `mask · base + (1 − mask) · generative`, all three at the output size. The reference implementation;
    /// an app blends on its own textures with the same mask.
    public static func composite(base: CGImage, generative: CGImage, mask: CGImage) throws -> CGImage {
        let w = generative.width, h = generative.height
        guard base.width == w, base.height == h, mask.width == w, mask.height == h else { throw GuardError.sizeMismatch }
        let b = try rgba(base), g = try rgba(generative), m = try gray(mask)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let t = Float(m[i]) / 255
            for c in 0..<3 {
                let v = t * Float(b[i * 4 + c]) + (1 - t) * Float(g[i * 4 + c])
                out[i * 4 + c] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw GuardError.rasterFailed }
        return image
    }

    static func rgba(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw GuardError.rasterFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    static func gray(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw GuardError.rasterFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }
}
