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
.package(url: "https://github.com/xocialize/MaskKit.git", from: "0.3.0")
```

Zero dependencies. MIT.

## Automatic text masks and the text-legibility guard (Tier 1, no weights)

Two Vision-backed tools ship inside the Kit, because Tier-1 OS implementations belong in the Kit rather
than behind a protocol:

- **`TextMaskDetector`** (v0.2.0) — every text region in an image, tiled at 1024 px (tiling, not
  Vision's `minimumTextHeight`, is what finds small text), as quads with transcripts, confidences and
  **per-word quads** (v0.3.0), plus a white-on-text mask with dilation and feather.
- **`TextLegibilityGuard`** (v0.3.0) — the guard in front of a *generative* restoration or upscale
  tier. It reads the input, reports the words the input already reads with certainty, and recommends a
  route:

```swift
let verdict = try TextLegibilityGuard.assess(input)          // Vision, synchronous — call off the main actor
switch verdict.recommendation {
case .keepBase:     /* a legible document page: run the non-generative tier only */
case .generative:   /* nothing certain: run the generative tier */
case .protectWords: /* opt-in only: run both, then */
    let mask = try TextLegibilityGuard.mask(for: verdict, width: out.width, height: out.height)
    let image = try TextLegibilityGuard.composite(base: fidelityOutput, generative: generativeOutput, mask: mask)
}
```

**Defaults are measured, and the measurement inverted the obvious design** (2026-09-26, 1,200 SA-Text
images with ground truth + 130 ScreenSR pages; receipts in `mlxengine-forge/Tools/vosr-gates/`):

- a generative tier (VOSR2) fixes more wrong words than it breaks, everywhere — but turns ~10 % of the
  words the input reads *correctly and with certainty* into plausible wrong words;
- Vision's confidence is effectively binary and a third of its "certain" reads on degraded input are
  wrong, so "protect what the input reads" protects garbage too;
- compositing protected words back into a sharpened frame is itself a degradation: the recognizer reads
  lines in context, and a mixed-fidelity line reads worse than either uniform version — on the
  illegible-input set it *tripled* corruption and cost 0.06 F1; on dense legible pages it cut corruption
  59 → 22 but still lost fixes;
- the image-level **document gate** (≥ 10 certain words on ≥ 50 % certain lines) never fired on the
  1,200 illegible inputs and cut corruption 59 → 3 on the pages it routed to the base tier.

So `Policy.default` is **document gate on, `wordProtection` off**. Turn word protection on only for
content you have measured (dense legible text at ×1); its dilation and feather are glyph-proportional
(0.5× / 0.15× the word height) because a fixed few pixels let the seam cut through ascenders.

Product rule this enforces: *an honestly-blurry STOP beats a razor-sharp SIOP.* Where the guard says
`.keepBase`, run conservative, non-generative restoration.
