// swift-tools-version: 6.2
import PackageDescription

// MaskKit — the **shared mask package**: every way Forge produces a selection, in one net-clean place so
// sibling verticals never depend on each other (the ERASE-PLAN decision). Two sources today:
//
//   • the **promptable seam** (Tier 2) — EdgeTAM (on-device SAM2) turns a click/box prompt into a mask for
//     an image and tracks an object across a video. Extract (subject selection) and Erase (object to
//     remove) both consume it. The engine-backed implementation injects at the app layer.
//   • **`TextMaskDetector`** (Tier 1, GAP-PROGRAM §N7) — automatic text regions via Apple Vision, no
//     weights and no download. Scale's Preserve Text, and anywhere a generative pass must be held back
//     from glyphs. Ships the detector itself, not just a protocol, because Tier-1 Vision implementations
//     belong inside the Kit.
//
// MaskKit stays MLX-free and macOS-14. Vision and CoreGraphics are OS frameworks — Tier 1, not a
// dependency.
let package = Package(
    name: "MaskKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MaskKit", targets: ["MaskKit"]),
    ],
    targets: [
        .target(name: "MaskKit"),
        .testTarget(name: "MaskKitTests", dependencies: ["MaskKit"]),
    ]
)
