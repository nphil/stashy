import UIKit

/// Coarse playback state used to drive the loading indicator vs. play/pause control.
enum PlaybackPhase: Sendable { case paused, waiting, playing }

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
    /// Coarse transport state (paused / waiting-to-play / playing) — drives the loading donut vs. the
    /// play-pause control, so a stuttery start no longer flickers the play/pause icon.
    var onState: ((PlaybackPhase) -> Void)? { get set }
    /// How full the start-up buffer is (0…1), pushed as it fills — ties the loading donut to real progress.
    var onLoadProgress: ((Double) -> Void)? { get set }
    /// Fired once if the underlying item fails to load/play (e.g. a bad local stream) so the facade can
    /// fall back to an alternative source. Carries the player's error text (Sendable) for diagnostics.
    var onFailed: ((String?) -> Void)? { get set }
    /// Actual decoded video size (after pixel-aspect/rotation), once known — for correct layout when
    /// the server's file dimensions are missing or wrong.
    var onPresentationSize: ((CGSize) -> Void)? { get set }
    /// Playback reached the end of the item (player parked at the end). The facade uses this so the next
    /// play() restarts from the beginning instead of no-opping at the end.
    var onEnded: (() -> Void)? { get set }

    /// Muted state. Starts muted unless a private audio route (headphones / AirPods / other Bluetooth)
    /// is connected, so audio never blasts out of the phone speaker unexpectedly.
    var isMuted: Bool { get set }

    func play()
    func pause()
    /// `precise` seeks frame-accurately (zero tolerance) so the frame lands exactly where the scrub
    /// preview showed — affordable for local media (direct file / loopback remux). Non-precise keeps a
    /// tolerance for server HLS, where a frame-exact seek stalls waiting on the transcoder.
    func seek(to time: TimeInterval, precise: Bool)
    /// Deterministic cleanup before release (remove observers, stop playback) — must run on the main
    /// actor while the backend is still alive, since a nonisolated deinit can't touch its members.
    func teardown()

    /// The furthest time (seconds) the player can currently seek to — the end of its seekable ranges.
    /// For a growing local-HLS stream this is what AVPlayer actually honors (it can lag the remux's
    /// produced position), so the facade uses it to decide between an in-stream seek and a remux restart.
    var seekableEnd: TimeInterval { get }

    /// Short description of the decode path for the Stats overlay (e.g. "Hardware (VideoToolbox)").
    var decodeDescription: String { get }
    /// Backend-specific live diagnostics (buffer, throughput, dropped frames, …) for the Stats overlay.
    func liveStats() -> [StatLine]
}
