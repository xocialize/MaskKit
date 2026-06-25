import CoreGraphics

/// A single click that points the segmenter at (or away from) an object. Coordinates are **image-pixel**
/// (the selection UI maps display→image, same as the brush). `include == false` is a *negative* click — "not
/// this" — to carve a region back out of the mask (EdgeTAM supports include/exclude prompts).
public struct MaskPoint: Sendable, Equatable {
    public var x: CGFloat
    public var y: CGFloat
    public var include: Bool
    public init(x: CGFloat, y: CGFloat, include: Bool = true) {
        self.x = x; self.y = y; self.include = include
    }
}

/// A promptable-segmentation **prompt** — the "what to select" signal: click points (include/exclude) and/or a
/// bounding box, all in image-pixel coordinates. Net-clean value type; the engine (EdgeTAM `promptSegment` /
/// `trackObject`) turns it into a mask. A box + a positive click is the typical "select this object" prompt.
public struct MaskPrompt: Sendable, Equatable {
    public var points: [MaskPoint]
    public var box: CGRect?
    public init(points: [MaskPoint] = [], box: CGRect? = nil) {
        self.points = points; self.box = box
    }

    public var isEmpty: Bool { points.isEmpty && box == nil }

    /// Convenience: a single positive click at `(x, y)`.
    public static func click(x: CGFloat, y: CGFloat) -> MaskPrompt {
        MaskPrompt(points: [MaskPoint(x: x, y: y, include: true)])
    }
}
