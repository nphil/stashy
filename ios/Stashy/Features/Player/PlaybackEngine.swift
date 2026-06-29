import UIKit

/// Backend-agnostic playback engine behind `ScenePlayerModel`. Two implementations:
/// `AVPlaybackEngine` (native AVPlayer — used for HLS, exposes live frames for the blur backdrop)
/// and `KSPlaybackEngine` (KSPlayer/FFmpeg — used for non-HLS/exotic-codec direct streams).
///
/// The engine pushes state back to the facade through the three callbacks; the facade guards those
/// writes for equality so per-frame ticks don't invalidate the whole view tree.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// The view that renders the sharp video. May be nil until the backend creates it (KSPlayer).
    var renderView: UIView? { get }
    /// A live blurred-backdrop view, when the backend can vend decoded frames (AVPlayer only).
    var liveBlurView: UIView? { get }

    /// current, duration (seconds). Throttled by the engine to ~10 Hz.
    var onTime: ((TimeInterval, TimeInterval) -> Void)? { get set }
    var onReady: ((Bool) -> Void)? { get set }
    var onPlaying: ((Bool) -> Void)? { get set }

    func play()
    func pause()
    func seek(to time: TimeInterval)

    /// Short description of the decode path for the Stats overlay (e.g. "Hardware (VideoToolbox)").
    var decodeDescription: String { get }
    /// Backend-specific live diagnostics (buffer, throughput, dropped frames, …) for the Stats overlay.
    func liveStats() -> [StatLine]
}
