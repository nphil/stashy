import UIKit
import AVFoundation
import CoreVideo

/// A UIView whose backing layer is an `AVPlayerLayer`, so the sharp video renders with no extra
/// compositing. Sized by the zoom surface (already aspect-fitted), so `.resizeAspect` fills it.
final class AVPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }
}

/// Native AVPlayer engine, used for HLS streams (Stash transcodes to an Apple-compatible codec, so
/// AVPlayer plays them directly). Because the item exposes decoded frames via `AVPlayerItemVideoOutput`,
/// this engine also vends a live, frame-matched blurred backdrop (`LiveBlurBackdropView`).
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let hostView = AVPlayerHostView()
    private let videoOutput: AVPlayerItemVideoOutput
    private let blurBackdrop = LiveBlurBackdropView()

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?

    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onPlaying: ((Bool) -> Void)?

    var renderView: UIView? { hostView }
    var liveBlurView: UIView? { blurBackdrop }

    init(url: URL) {
        // Route audio through the playback category so sound isn't muted by the ringer switch.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        item = AVPlayerItem(url: url)
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(videoOutput)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        hostView.player = player
        blurBackdrop.configure(output: videoOutput)

        // ~10 Hz so the scrubber/time label rebuild a handful of times a second, not per frame.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let duration = self.item.duration.seconds
                self.onTime?(time.seconds, duration.isFinite ? duration : 0)
            }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            Task { @MainActor in self?.onReady?(ready) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in self?.onPlaying?(playing) }
        }

        player.play()
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to time: TimeInterval) {
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
