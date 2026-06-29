import SwiftUI
import AVFoundation
import UIKit

/// A second, low-resolution AVPlayer on the same stream used purely as a moving, blurred backdrop
/// behind the inline player. It's kept loosely in sync with the main player so the blur matches what's
/// playing, and scaled to fill (cropping) so its edges blend with the sharp video sitting on top.
@Observable
@MainActor
final class BlurVideoModel {
    let player: AVPlayer

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        // The backdrop is heavily blurred, so a tiny variant is plenty — keeps the extra decode cheap.
        item.preferredMaximumResolution = CGSize(width: 256, height: 256)
        item.preferredPeakBitRate = 600_000
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
    }

    func play() { player.play() }
    func pause() { player.pause() }

    /// Follow the main player: only seek when drift is noticeable (a blurred jump is imperceptible),
    /// and mirror its play/pause state.
    func sync(to time: TimeInterval, playing: Bool) {
        let current = player.currentTime().seconds
        if time.isFinite, abs(current - time) > 1.5 {
            player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                        toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
        }
        if playing { player.play() } else { player.pause() }
    }
}

/// Hosts the blur player's `AVPlayerLayer` (fill) under a `UIVisualEffectView`, which reliably blurs
/// live video (unlike SwiftUI `.blur`, which doesn't always update for AV content).
struct LiveBlurVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> BlurHostView {
        let view = BlurHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: BlurHostView, context: Context) {
        view.playerLayer.player = player
    }

    final class BlurHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private let effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        private let tint = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Clear so a poster placed behind shows through until the blur stream has frames.
            backgroundColor = .clear
            playerLayer.backgroundColor = UIColor.clear.cgColor
            // A faint dark tint keeps text/controls legible over bright footage.
            tint.backgroundColor = UIColor.black.withAlphaComponent(0.15)
            tint.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(effectView)
            addSubview(tint)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            effectView.frame = bounds
            tint.frame = bounds
        }
    }
}
