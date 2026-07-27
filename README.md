# MaskKit

The promptable-selection seam: *"click the thing you mean"* → a soft-alpha mask.

Two value types and two protocols, nothing else. MaskKit deliberately contains **no segmentation model**
— it defines the contract that Extract (cut the subject out) and Erase (remove the object) both speak, so
one engine-backed implementation serves both.

```swift
public protocol PromptMaskProvider: Sendable {
    var name: String { get }
    func mask(_ image: CGImage, prompt: MaskPrompt) async throws -> CGImage
}

public protocol TrackMaskProvider: Sendable {   // video: one mask per frame
    var name: String { get }
    func track(_ videoURL: URL, prompt: MaskPrompt) async throws -> [CGImage]
}
```

A `MaskPrompt` is click points (include/exclude) and/or a box, **in image pixels** — no normalized
coordinates to get wrong at a layer boundary.

```swift
let prompt = MaskPrompt.click(x: 512, y: 384)
let mask = try await provider.mask(image, prompt: prompt)   // grayscale, white = selected
```

## Why the model isn't here

This is the pattern the whole Forge stack uses: a **net-clean Kit** declares a narrow protocol for
anything needing a model, and the engine-backed implementation is injected from above. So MaskKit has no
MLX dependency, no weights, no download, and a macOS 14 floor — a host that wants the vocabulary isn't
forced into a GPU toolchain.

The MLX implementation (EdgeTAM) lives in [`ForgeCore`](https://github.com/xocialize/ForgeCore). Bring
your own: anything that turns a prompt into a grayscale mask conforms, including Vision or Core ML.

## Install

```swift
.package(url: "https://github.com/xocialize/MaskKit.git", from: "0.1.0")
```

Zero dependencies. MIT.
