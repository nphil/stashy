import UIKit
import KSPlayer

/// KSPlayer-backed engine: AVPlayer/VideoToolbox hardware with an FFmpeg software fallback, so scenes
/// whose codec/profile native AVPlayer rejects still play with no transcoding. Used for the non-HLS
/// fallback stream. Exposes only the rendered view — no decoded frames — so it provides no live blur.
@MainActor
final class KSPlaybackEngine: PlaybackEngine, KSPlayerLayerDelegate {
    private let layer: KSPlayerLayer
    /// Only re-publish time once it advances ~0.1s so the controls rebuild at ~10 Hz, not per frame.
    private var lastEmittedTime: TimeInterval = -1

    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPlaying: ((Bool) -> Void)?

    var renderView: UIView? { layer.player.view }
    var liveBlurView: UIView? { nil }

    init(url: URL) {
        // Pass isAutoPlay explicitly to avoid touching KSOptions.isAutoPlay, a non-isolated mutable
        // static that Swift 6 strict concurrency rejects.
        layer = KSPlayerLayer(url: url, isAutoPlay: true, options: KSOptions())
        layer.delegate = self
    }

    func play() { layer.play() }
    func pause() { layer.pause() }

    func seek(to time: TimeInterval) {
        layer.seek(time: time, autoPlay: layer.player.isPlaying) { _ in }
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        onReady?(layer.player.isReadyToPlay)
        onPlaying?(layer.player.isPlaying)
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        if lastEmittedTime < 0 || currentTime < lastEmittedTime || abs(currentTime - lastEmittedTime) >= 0.1 {
            lastEmittedTime = currentTime
            onTime?(currentTime, totalTime)
        }
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        onPlaying?(false)
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    // MARK: - Stats

    // KSPlayer decodes via VideoToolbox when the codec is supported and falls back to FFmpeg software
    // decoding otherwise (which is exactly why exotic codecs are routed here).
    var decodeDescription: String { "VideoToolbox if supported, else FFmpeg (software)" }

    func liveStats() -> [StatLine] {
        // KSPlayer's live decode/network counters aren't part of its stable public surface, so we keep
        // this backend's diagnostics to what's guaranteed; the Media section (codec/res/bitrate/fps)
        // still comes from the scene metadata. A live-metrics hook can be added here later.
        [StatLine(label: "Live metrics", value: "n/a (KSPlayer backend)")]
    }
}
