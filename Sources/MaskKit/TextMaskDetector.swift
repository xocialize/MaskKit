//
// TextMaskDetector.swift — MaskKit
//
// N7 — automatic text masks, Tier 1 (Apple Vision). See `mlxengine-todo/GAP-PROGRAM.md` §N7.
//
// **This beats the competitor's UX outright.** Their Preserve Text requires a *mandatory manual brush
// mask*; this is automatic, and the brush becomes an add/subtract override rather than the primary
// mechanism. Cost: zero. In-OS, on-device, ANE, no download, no bundle bytes, no licence, no EULA
// propagation, 18 languages.
//
// Why a text mask matters at all: TAIR/TeReDiff names the failure mode *"text-image hallucination"* —
// on SA-Text at Level-3 degradation, SUPIR scores 32.78 detection F1 / 11.77 end-to-end, **below the
// un-restored baseline.** The most aggressive generative upscaler actively destroys text that was
// readable before restoration. Hence the product rule this type exists to enable:
//
//     🔑 Inside the mask, run conservative NON-generative restoration.
//        An honestly-blurry "STOP" beats a razor-sharp "SIOP".
//
// 🚨 **The small-text failure is real. The mechanism the plan attributed it to is NOT.**
// Measured on macOS 27, 2026-07-29, rather than read from the header — and the measurement inverted the
// prescription, so it is recorded here in full.
//
// The plan said: Vision's `minimumTextHeight` defaults to 1/32 of image height, so a 3000 px frame
// silently ignores text under ~94 px; force the value to ~0 and tile to compensate. **The first half is
// wrong.** `minimumTextHeight` does not behave as a monotone size filter at all:
//
//     h=1024, 20 pt  →  found at 0, 0.01, 0.03125, 0.06 · LOST at 0.1+           (filter-like)
//     h=1024, 14 pt  →  found at EVERY value including 0.5                        (not a filter)
//     h=2048, 30 pt  →  found at 0, 0.01 · LOST at 0.03125, 0.06 · FOUND at 0.1+  (non-monotonic)
//
// It is a hint that steers an internal scale search; it can both add and remove detections, and the
// results move under trivial changes to image size and text position. **Do not build recall on it.**
//
// 🔑 **Tiling is the actual lever, and a controlled run shows it carries the whole effect.** Holding
// `minimumTextHeight = 0` in every arm, over three strings planted in one frame:
//
//     h=2048, 14 pt   whole-image 0/3   ·  tiled@1024 3/3  ·  tiled@512 3/3
//     h=3000, 24 pt   whole-image 0/3   ·  tiled@1024 3/3  ·  tiled@512 4/3*
//     h=2048, 20 pt   whole-image 3/3   ·  tiled@1024 3/3  ·  tiled@512 3/3
//
// The parameter is constant across every arm, so **the difference is tiling and nothing else**: a glyph
// that is 0.8% of a 3000 px frame is 2.3% of a 1024 px tile, and that is what moves it into range.
//
// So `minimumTextHeightPixels` defaults to **0** and exists only as an escape hatch. The recall this row
// promises comes from `tileSize`.
//
// *⚠️ The 4/3 is not a false positive but a **split**: a text run wider than the inter-tile overlap band
// can be reported as two regions, and IoU dedupe cannot merge two halves that barely overlap. Harmless
// for masking — the union still covers the text — but a caller reading `transcript` must expect it.
// Mitigate by keeping the overlap band wider than the widest expected text run.
//
// **Two detectors, unioned, because they fail differently:**
//   - `VNRecognizeTextRequest` couples detection to recognition — an observation exists only because a
//     string was produced. Strong on real consumer photography (it powers Live Text), so its degradation
//     distribution is much closer to our users' inputs than ICDAR-trained academic detectors, which
//     collapse under blur (FCENet 84.9 → 30.1).
//   - `VNDetectTextRectanglesRequest` is pure detection with no recognition gate. Mechanistically,
//     *"there is text here"* lives below the blur cutoff while *"this glyph is a 6 not an 8"* lives
//     above it — so this pass survives exactly the degradation the recognizer does not.
//
// 🔑 **Optimize for recall, not H-mean.** A missed region means visible hallucinated garbage; a false
// positive means one patch upscaled conservatively. The defaults here are deliberately recall-leaning.
//
// Not in scope for this Tier-1 row: **PP-OCRv6_small_det** (9.42 MB, Apache-2.0 code *and* weights,
// Blur H-mean 92.6 vs 84.1 average). It is the degradation-robust third member of the union and it is a
// model — so it belongs behind an engine-backed provider, not in a net-clean Kit.
//

import CoreGraphics
import Foundation
import Vision

/// A four-corner region in **image-pixel** coordinates, top-left origin — the same convention as the
/// brush and `MaskPrompt`, and deliberately *not* Vision's normalized bottom-left space.
///
/// 🔑 Quads, not rectangles, and this is free rather than clever: `VNRecognizedTextObservation`
/// subclasses `VNRectangleObservation`, so rotated and skewed text masks correctly with no extra work.
/// Collapsing to an axis-aligned box would mask a large wedge of non-text on any tilted sign.
public struct TextQuad: Sendable, Equatable {
    public var topLeft: CGPoint
    public var topRight: CGPoint
    public var bottomRight: CGPoint
    public var bottomLeft: CGPoint

    public init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft; self.topRight = topRight
        self.bottomRight = bottomRight; self.bottomLeft = bottomLeft
    }

    public var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    public var boundingBox: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Shoelace area — used for merge decisions, and correct for a skewed quad where the bounding box
    /// would overstate the region substantially.
    public var area: CGFloat {
        let p = corners
        var sum: CGFloat = 0
        for i in 0..<p.count {
            let q = p[(i + 1) % p.count]
            sum += p[i].x * q.y - q.x * p[i].y
        }
        return abs(sum) / 2
    }

    /// Translate by a tile origin — the tiling seam.
    public func offset(dx: CGFloat, dy: CGFloat) -> TextQuad {
        func t(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        return TextQuad(topLeft: t(topLeft), topRight: t(topRight),
                        bottomRight: t(bottomRight), bottomLeft: t(bottomLeft))
    }
}

/// One detected text region.
/// One recognised word inside a `TextRegion` line — its own quad, from `VNRecognizedText.boundingBox(for:)`.
/// Word granularity exists for `TextLegibilityGuard`: protecting a whole line to keep one legible word
/// measured too coarse (it also freezes the words on that line the generative tier would have fixed).
public struct TextWord: Sendable, Equatable {
    public var text: String
    public var quad: TextQuad
    public init(text: String, quad: TextQuad) {
        self.text = text
        self.quad = quad
    }
}

public struct TextRegion: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// `VNRecognizeTextRequest` — a string was produced, so the region is certainly text.
        case recognition
        /// `VNDetectTextRectanglesRequest` — appearance only. Survives blur the recognizer does not.
        case detection
    }

    public var quad: TextQuad
    /// The recognized string, when it came from the recognition pass. `nil` from the detection pass —
    /// **`nil` is not lower confidence, it is a different question having been asked.**
    public var transcript: String?
    public var confidence: Float
    public var source: Source
    /// Per-word quads for a `.recognition` region (empty for `.detection`). Same pixel space as `quad`.
    public var words: [TextWord]

    public init(quad: TextQuad, transcript: String?, confidence: Float, source: Source,
                words: [TextWord] = []) {
        self.quad = quad; self.transcript = transcript
        self.confidence = confidence; self.source = source
        self.words = words
    }
}

/// Automatic text-region detection and mask synthesis. Tier 1: Apple Vision, on-device, no weights, no
/// download, no licence exposure.
///
/// ⚠️ **Synchronous by design.** `VNImageRequestHandler.perform` is synchronous, so wrapping it in
/// `async` here would only hide where the time goes. Tiling a large frame takes real time — call this
/// off the main actor.
public enum TextMaskDetector {

    public enum DetectorError: Error, Equatable {
        case rasterFailed
        case imageTooSmall
    }

    public struct Options: Sendable {
        /// 🔑 **The recall lever.** Tile edge in pixels; 1024 is the measured working point. Smaller
        /// tiles find smaller text (a glyph is a larger fraction of the tile) at more Vision passes.
        public var tileSize: Int
        /// Fractional overlap between tiles, so a word straddling a seam is whole in at least one tile.
        /// ⚠️ **A text run wider than the overlap band can be reported as two regions** — harmless for
        /// masking, visible to anyone reading `transcript`. 0.25 of a 1024 tile is a 256 px band.
        public var tileOverlap: Double
        /// Vision's `minimumTextHeight`, expressed in pixels and converted per tile. **Defaults to 0,
        /// and should stay there.** Measured to be non-monotonic and unstable — see the type comment.
        /// Kept only as an escape hatch for a caller who has measured something better on real content.
        public var minimumTextHeightPixels: Int
        /// Run the recognition-free `VNDetectTextRectanglesRequest` pass and union it in. Recall-leaning
        /// default: on.
        public var includeDetectionOnlyPass: Bool
        /// Recognition confidence floor. Deliberately low — recall over precision (see the type comment).
        public var minimumConfidence: Float
        /// Bounding-box IoU above which two regions from different tiles are treated as the same region.
        public var mergeIoU: Double
        /// Mask dilation in pixels, applied after rasterization.
        public var dilation: Int
        /// Mask feather (Gaussian sigma in pixels) applied after dilation, so the boundary is a blend
        /// rather than a visible switch between two restoration policies.
        public var feather: Double
        /// `false` is right for masking: we need where the text *is*, not what it says, and correction
        /// costs time without moving a single region boundary.
        public var usesLanguageCorrection: Bool
        /// `nil` → Vision's default language set.
        public var recognitionLanguages: [String]?

        public init(tileSize: Int = 1024,
                    tileOverlap: Double = 0.25,
                    minimumTextHeightPixels: Int = 0,
                    includeDetectionOnlyPass: Bool = true,
                    minimumConfidence: Float = 0.0,
                    mergeIoU: Double = 0.35,
                    dilation: Int = 6,
                    feather: Double = 3.0,
                    usesLanguageCorrection: Bool = false,
                    recognitionLanguages: [String]? = nil) {
            self.tileSize = tileSize
            self.tileOverlap = tileOverlap
            self.minimumTextHeightPixels = minimumTextHeightPixels
            self.includeDetectionOnlyPass = includeDetectionOnlyPass
            self.minimumConfidence = minimumConfidence
            self.mergeIoU = mergeIoU
            self.dilation = dilation
            self.feather = feather
            self.usesLanguageCorrection = usesLanguageCorrection
            self.recognitionLanguages = recognitionLanguages
        }

        public static let `default` = Options()
    }

    // MARK: - Regions

    /// Detect text regions across the whole image, tiling as needed.
    public static func regions(in image: CGImage, options: Options = .default) throws -> [TextRegion] {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw DetectorError.imageTooSmall }

        var found: [TextRegion] = []
        for tile in tileGrid(width: width, height: height,
                             tileSize: options.tileSize, overlap: options.tileOverlap) {
            guard let cropped = image.cropping(to: tile) else { continue }
            found += try detect(in: cropped, options: options)
                .map { region in
                    var moved = region
                    moved.quad = region.quad.offset(dx: tile.minX, dy: tile.minY)
                    moved.words = region.words.map { TextWord(text: $0.text, quad: $0.quad.offset(dx: tile.minX, dy: tile.minY)) }
                    return moved
                }
        }
        return merge(found, iouThreshold: options.mergeIoU)
    }

    /// A grayscale mask at source resolution — **white = text**, matching `PromptMaskProvider`'s
    /// convention so both mask sources compose without a polarity flip at the seam.
    public static func mask(for image: CGImage, options: Options = .default) throws -> CGImage {
        let regions = try regions(in: image, options: options)
        return try mask(regions: regions, width: image.width, height: image.height, options: options)
    }

    /// Rasterize regions to a mask. Split out so a caller can edit the region list first — which is the
    /// point of the whole design: **automatic detection, manual override.**
    public static func mask(regions: [TextRegion], width: Int, height: Int,
                            options: Options = .default) throws -> CGImage {
        guard width > 0, height > 0 else { throw DetectorError.imageTooSmall }
        var plane = [Float](repeating: 0, count: width * height)

        for region in regions {
            fill(quad: region.quad, into: &plane, width: width, height: height)
        }
        if options.dilation > 0 {
            plane = dilate(plane, width: width, height: height, radius: options.dilation)
        }
        if options.feather > 0 {
            plane = blur(plane, width: width, height: height,
                         kernel: gaussianKernel(sigma: Float(options.feather)))
        }
        return try grayImage(plane, width: width, height: height)
    }

    // MARK: - Vision

    private static func detect(in tile: CGImage, options: Options) throws -> [TextRegion] {
        let tileHeight = CGFloat(tile.height)
        // Pixels → Vision's fraction, against the TILE's height. Zero by default; see the type comment
        // for why this parameter is not the recall mechanism it looks like.
        let minimumFraction = Float(max(0.0, Double(options.minimumTextHeightPixels) / Double(tile.height)))

        let handler = VNImageRequestHandler(cgImage: tile, options: [:])
        var out: [TextRegion] = []

        let recognize = VNRecognizeTextRequest()
        recognize.recognitionLevel = .accurate
        recognize.usesLanguageCorrection = options.usesLanguageCorrection
        recognize.minimumTextHeight = minimumFraction
        if let languages = options.recognitionLanguages { recognize.recognitionLanguages = languages }

        var requests: [VNRequest] = [recognize]
        let detectOnly = VNDetectTextRectanglesRequest()
        detectOnly.reportCharacterBoxes = false
        if options.includeDetectionOnlyPass { requests.append(detectOnly) }

        try handler.perform(requests)

        for observation in recognize.results ?? [] {
            guard observation.confidence >= options.minimumConfidence else { continue }
            let candidate = observation.topCandidates(1).first
            out.append(TextRegion(
                quad: quad(from: observation, width: CGFloat(tile.width), height: tileHeight),
                transcript: candidate?.string,
                confidence: observation.confidence,
                source: .recognition,
                words: candidate.map { words(of: $0, width: CGFloat(tile.width), height: tileHeight) } ?? []))
        }

        if options.includeDetectionOnlyPass {
            for observation in detectOnly.results ?? [] {
                out.append(TextRegion(
                    quad: quad(from: observation, width: CGFloat(tile.width), height: tileHeight),
                    transcript: nil,
                    confidence: observation.confidence,
                    source: .detection))
            }
        }
        return out
    }

    /// Vision → image-pixel space. **Vision is normalized with a bottom-left origin; this codebase is
    /// pixels with a top-left origin.** Flipping y here, once, is why nothing downstream has to think
    /// about it — and getting it wrong produces a mask that is vertically mirrored, which reads as
    /// "the detector is bad" rather than "the conversion is wrong".
    static func quad(from observation: VNRectangleObservation,
                     width: CGFloat, height: CGFloat) -> TextQuad {
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * width, y: (1 - p.y) * height)
        }
        // The y-flip also swaps top and bottom: Vision's topLeft is the *visually* top-left corner in
        // its own space, which lands at the bottom in ours.
        return TextQuad(topLeft: point(observation.bottomLeft),
                        topRight: point(observation.bottomRight),
                        bottomRight: point(observation.topRight),
                        bottomLeft: point(observation.topLeft))
    }

    /// Whitespace-separated words of a recognised line, each with its own quad. Vision reports lines; the
    /// per-word geometry comes from `boundingBox(for:)` on the candidate. A word whose box Vision cannot
    /// produce is skipped rather than approximated — an invented box would protect the wrong pixels.
    static func words(of candidate: VNRecognizedText, width: CGFloat, height: CGFloat) -> [TextWord] {
        let string = candidate.string
        var result: [TextWord] = []
        var index = string.startIndex
        while index < string.endIndex {
            while index < string.endIndex, string[index].isWhitespace { index = string.index(after: index) }
            guard index < string.endIndex else { break }
            var end = index
            while end < string.endIndex, !string[end].isWhitespace { end = string.index(after: end) }
            if let box = try? candidate.boundingBox(for: index..<end) {
                result.append(TextWord(text: String(string[index..<end]),
                                       quad: quad(from: box, width: width, height: height)))
            }
            index = end
        }
        return result
    }

    // MARK: - Tiling

    /// Overlapping tile grid covering the image. The last row/column is clamped flush to the far edge
    /// rather than shrunk, so no tile is ever undersized — an undersized tile changes the derived
    /// minimum-height fraction and would silently apply a different detection threshold at the border.
    static func tileGrid(width: Int, height: Int, tileSize: Int, overlap: Double) -> [CGRect] {
        let size = max(64, tileSize)
        guard width > size || height > size else {
            return [CGRect(x: 0, y: 0, width: width, height: height)]
        }
        let stride = max(1, Int(Double(size) * (1.0 - max(0, min(0.9, overlap)))))

        func origins(_ extent: Int) -> [Int] {
            guard extent > size else { return [0] }
            var values: [Int] = []
            var v = 0
            while v + size < extent {
                values.append(v)
                v += stride
            }
            values.append(extent - size)          // flush to the far edge
            return values
        }

        var tiles: [CGRect] = []
        for y in origins(height) {
            for x in origins(width) {
                tiles.append(CGRect(x: x, y: y,
                                    width: min(size, width), height: min(size, height)))
            }
        }
        return tiles
    }

    // MARK: - Merge

    /// Deduplicate across tile overlaps by bounding-box IoU.
    ///
    /// 🔑 **A recognition hit beats a detection hit when they collide, and this is not an arbitrary
    /// tie-break.** The two passes answer different questions, so the merged region should carry the
    /// stronger claim — "this is text and it says X" — while the detection pass's value is the regions
    /// where recognition produced *nothing at all*. Preferring recognition on collision keeps the
    /// transcript; unioning keeps the recall.
    static func merge(_ regions: [TextRegion], iouThreshold: Double) -> [TextRegion] {
        var kept: [TextRegion] = []
        // Recognition first, so it wins collisions by arriving first.
        let ordered = regions.sorted { a, b in
            if (a.source == .recognition) != (b.source == .recognition) { return a.source == .recognition }
            return a.confidence > b.confidence
        }
        for region in ordered {
            let box = region.quad.boundingBox
            if kept.contains(where: { iou($0.quad.boundingBox, box) >= iouThreshold }) { continue }
            kept.append(region)
        }
        return kept
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let overlap = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height) + Double(b.width * b.height) - overlap
        return union > 0 ? overlap / union : 0
    }

    // MARK: - Rasterization

    /// Fill a convex quad by scanline, with a half-pixel sample at each pixel centre. Written out rather
    /// than deferred to CoreGraphics so the mask is deterministic and testable without a drawing context.
    static func fill(quad: TextQuad, into plane: inout [Float], width: Int, height: Int) {
        let box = quad.boundingBox
        let minY = max(0, Int(box.minY.rounded(.down)))
        let maxY = min(height - 1, Int(box.maxY.rounded(.up)))
        let minX = max(0, Int(box.minX.rounded(.down)))
        let maxX = min(width - 1, Int(box.maxX.rounded(.up)))
        guard minY <= maxY, minX <= maxX else { return }

        let corners = quad.corners
        for y in minY...maxY {
            let py = CGFloat(y) + 0.5
            for x in minX...maxX {
                let px = CGFloat(x) + 0.5
                if contains(corners, x: px, y: py) { plane[y * width + x] = 1 }
            }
        }
    }

    /// Convex-polygon containment by consistent cross-product sign. Tolerates either winding order.
    static func contains(_ corners: [CGPoint], x: CGFloat, y: CGFloat) -> Bool {
        var sawPositive = false, sawNegative = false
        for i in 0..<corners.count {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
            if cross > 0 { sawPositive = true }
            if cross < 0 { sawNegative = true }
            if sawPositive && sawNegative { return false }
        }
        return true
    }

    /// Separable max filter — dilation on a binary plane.
    static func dilate(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return src }
        var tmp = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var m: Float = 0
                for k in -radius...radius {
                    m = max(m, src[row + min(max(x + k, 0), width - 1)])
                }
                tmp[row + x] = m
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var m: Float = 0
                for k in -radius...radius {
                    m = max(m, tmp[min(max(y + k, 0), height - 1) * width + x])
                }
                out[y * width + x] = m
            }
        }
        return out
    }

    static func gaussianKernel(sigma: Float) -> [Float] {
        let radius = max(1, Int(ceilf(sigma * 3)))
        var k = [Float](); k.reserveCapacity(radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = expf(-Float(i * i) / (2 * sigma * sigma))
            k.append(v); sum += v
        }
        return k.map { $0 / sum }
    }

    static func blur(_ src: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
        let r = kernel.count / 2
        var tmp = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var acc: Float = 0
                for k in -r...r { acc += src[row + min(max(x + k, 0), width - 1)] * kernel[k + r] }
                tmp[row + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for k in -r...r { acc += tmp[min(max(y + k, 0), height - 1) * width + x] * kernel[k + r] }
                out[y * width + x] = acc
            }
        }
        return out
    }

    static func grayImage(_ plane: [Float], width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<plane.count {
            bytes[i] = UInt8(max(0, min(255, (plane[i] * 255).rounded())))
        }
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage() else {
            throw DetectorError.rasterFailed
        }
        return image
    }
}
