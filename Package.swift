// swift-tools-version: 6.2
import PackageDescription

// MaskKit — the **shared promptable-mask seam**. EdgeTAM (on-device SAM2) produces masks from a prompt
// (click / box) for an image, and tracks an object across a video. BOTH Extract (subject selection) and Erase
// (object selection + video tracking) consume that, so the seam lives in its own tiny net-clean package — not
// in either capability — so sibling verticals never depend on each other (the ERASE-PLAN decision). The
// engine-backed EdgeTAM implementation injects at the app layer; MaskKit stays MLX-free.
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
