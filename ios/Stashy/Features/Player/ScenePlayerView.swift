import SwiftUI
import KSPlayer

/// Wraps KSPlayer's `IOSVideoPlayerView`, which internally chooses AVPlayer (VideoToolbox
/// hardware) for supported codecs and falls back to its FFmpeg software decoder for the
/// rest — so videos AVPlayer alone can't decode still play, with no transcoding.
struct ScenePlayerView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        let playerView = IOSVideoPlayerView()
        let options = KSOptions()
        options.isAutoPlay = true
        let resource = KSPlayerResource(url: url, options: options)
        playerView.set(resource: resource)
        return playerView
    }

    func updateUIView(_ uiView: IOSVideoPlayerView, context: Context) {}
}
