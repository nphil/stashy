import SwiftUI
import AVFoundation
import UIKit

/// A moving, blurred backdrop behind the inline player. It loops the scene's cached low-res preview
/// clip (already downloaded, tiny) rather than decoding a second copy of the full stream — so it
/// gives a video-of-the-same-scene blur with negligible cost and zero contention with playback.
@Observable
@MainActor
final class BlurVideoModel {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init() {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .none
    }

    /// Load the local preview clip and loop it. No-op if already loaded.
    func load(_ localURL: URL) {
        guard looper == nil else { return }
        let item = AVPlayerItem(url: localURL)
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    func play() { player.play() }
    func pause() { player.pause() }
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
