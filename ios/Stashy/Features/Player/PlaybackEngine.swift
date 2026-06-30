import UIKit

/// Backend-agnostic playback engine behind `ScenePlayerModel`. The implementation today is
/// `AVPlaybackEngine` (native AVPlayer — plays HLS and direct H.264/HEVC, and exposes live decoded
/// frames for the blur backdrop); the on-device FFmpeg remux/transcode engine plugs in behind the
/// same protocol for exotic containers/codecs.
///
/// The engine pushes state back to the facade through the callbacks; the facade guards those
/// writes for equality so per-frame ticks don't invalidate the whole view tree.
@MainActor
protocol PlaybackEngine: AnyObject {
    /// The view that renders the sharp video. May be nil until the backend creates it.
    var renderView: UIView? { get }
    /// A live blurred-backdrop view vended from the engine's decoded frames.
    var liveBlurView: UIView? { get }

    /// current, duration (seconds). Throttled by the engine to ~10 Hz.
    var onTime: ((TimeInterval, TimeInterval) -> Void)? { get set }
    var onReady: ((Bool) -> Void)? { get set }
    var onPlaying: ((Bool) -> Void)? { get set }
    /// Fired once if the underlying item fails to load/play (e.g. a bad local stream) so the facade can
    /// fall back to an alternative source.
    var onFailed: ((Error?) -> Void)? { get set }
    /// Actual decoded video size (after pixel-aspect/rotation), once known — for correct layout when
    /// the server's file dimensions are missing or wrong.
    var onPresentationSize: ((CGSize) -> Void)? { get set }

    func play()
    func pause()
    func seek(to time: TimeInterval)

    /// Short description of the decode path for the Stats overlay (e.g. "Hardware (VideoToolbox)").
    var decodeDescription: String { get }
    /// Backend-specific live diagnostics (buffer, throughput, dropped frames, …) for the Stats overlay.
    func liveStats() -> [StatLine]
}
