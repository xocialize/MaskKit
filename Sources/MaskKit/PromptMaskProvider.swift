import CoreGraphics
import Foundation

/// **Promptable segmentation seam** (EdgeTAM `promptSegment`) — a prompt → a soft-alpha mask for a still image.
/// The shared "click the object" mask source for Extract (subject) and Erase (object-to-remove); the
/// engine-backed EdgeTAM impl injects at the app layer (keeps the net-clean Kits MLX-free). The mask is a
/// grayscale `CGImage` at source resolution (the segmenter's convention — white = selected). `name` labels the
/// inspector + tags artifacts.
public protocol PromptMaskProvider: Sendable {
    var name: String { get }
    func mask(_ image: CGImage, prompt: MaskPrompt) async throws -> CGImage
}

/// **Promptable video tracking seam** (EdgeTAM `trackObject`) — click an object on the first frame and get its
/// mask on **every** frame (drift-free masklet propagation), the proper alternative to flow-warping a single
/// painted mask. Returns one grayscale mask per frame, in frame order, aligned to the clip the consumer reads
/// (Erase inpaints frame *i* with mask *i*; matting/extract composite per-frame).
///
/// NB: returns the full per-frame sequence — fine for short consumer clips (1-ch masks are small); a streaming
/// variant is a later refinement for long clips (EdgeTAM itself streams with a flat footprint).
public protocol TrackMaskProvider: Sendable {
    var name: String { get }
    func track(_ videoURL: URL, prompt: MaskPrompt) async throws -> [CGImage]
}
