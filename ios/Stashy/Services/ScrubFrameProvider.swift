import UIKit
import AVFoundation

/// Frame-exact scrub previews for **local** (downloaded) files. While you drag the scrubber, this decodes
/// the actual frame at the finger's position with `AVAssetImageGenerator` (zero tolerance → the exact
/// frame, not the nearest sprite/keyframe), so the preview matches where playback resumes (the release
/// seek is already frame-exact for local media). Streaming isn't supported — decoding arbitrary frames
/// there needs the network per frame — so it's gated to `file://` URLs; elsewhere the caller shows the
/// VTT sprite tile as before.
///
/// **Coalescing:** a fast drag issues far more positions than can be decoded. Each request cancels the
/// in-flight generation and asks for the newest time, so intermediate positions are skipped and a frame
/// only lands once the finger slows enough for one decode to finish — exactly the "snaps exact when you
/// settle" feel. The VTT sprite (shown by the caller until `image` is non-nil) covers the fast-drag gap.
@Observable
@MainActor
final class ScrubFrameProvider {
    /// The most recently decoded frame (nil until the first lands, or when not a local file).
    private(set) var image: UIImage?
    /// The media time `image` corresponds to (the generator's actual returned time).
    private(set) var imageTime: TimeInterval = 0

    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var currentURL: URL?

    /// A tiny `@unchecked Sendable` box to carry the decoded `UIImage` from the generator's completion
    /// (an arbitrary queue) back to the main actor — the image is an immutable snapshot here.
    private final class Box: @unchecked Sendable { let image: UIImage; init(_ i: UIImage) { self.image = i } }

    /// Point this at a scene's local file (or nil to disable). No-op if already configured for that URL.
    func configure(url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        generator?.cancelAllCGImageGeneration()
        image = nil
        imageTime = 0
        guard let url, url.isFileURL else { generator = nil; return }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true          // honour rotation metadata
        gen.requestedTimeToleranceBefore = .zero            // exact frame, not nearest keyframe
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: 480, height: 480)   // preview-sized decode → cheap
        generator = gen
    }

    /// Request the exact frame at `time`. Cancels any in-flight decode (coalesce to the newest position).
    func request(_ time: TimeInterval) {
        guard let generator else { return }
        generator.cancelAllCGImageGeneration()
        let cmt = CMTime(seconds: max(0, time), preferredTimescale: 600)
        generator.generateCGImageAsynchronously(for: cmt) { [weak self] cg, actual, _ in
            guard let cg else { return }   // nil ⇒ cancelled (superseded) or failed — ignore
            let box = Box(UIImage(cgImage: cg))
            let t = actual.seconds
            Task { @MainActor in
                self?.image = box.image
                self?.imageTime = t
            }
        }
    }

    /// Drop the current preview (e.g. when a scrub ends) so the next scrub doesn't flash a stale frame.
    func clear() {
        generator?.cancelAllCGImageGeneration()
        image = nil
    }
}
