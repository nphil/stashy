import SwiftUI
import KSPlayer

/// Drives a single `KSPlayerLayer` (which internally picks AVPlayer/VideoToolbox hardware
/// or its FFmpeg software decoder) and exposes observable playback state so we can render a
/// fully custom controls overlay — required for the Stash sprite-preview scrubber.
@Observable
@MainActor
final class ScenePlayerModel: KSPlayerLayerDelegate {
    let layer: KSPlayerLayer
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var isReady = false

    init(url: URL) {
        // Pass isAutoPlay explicitly to avoid touching KSOptions.isAutoPlay, a non-isolated
        // mutable static that Swift 6 strict concurrency rejects.
        layer = KSPlayerLayer(url: url, isAutoPlay: true, options: KSOptions())
        layer.delegate = self
    }

    func play() { layer.play(); isPlaying = true }
    func pause() { layer.pause(); isPlaying = false }
    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        currentTime = clamped
        layer.seek(time: clamped, autoPlay: isPlaying) { _ in }
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        isReady = layer.player.isReadyToPlay
        isPlaying = layer.player.isPlaying
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        self.currentTime = currentTime
        self.duration = totalTime
        isReady = true
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        isPlaying = false
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}
}

/// Hosts the KSPlayer render surface (`player.view`), which may appear asynchronously once
/// the player is ready; we (re)attach it on each SwiftUI update.
struct KSPlayerSurface: UIViewRepresentable {
    let model: ScenePlayerModel
    /// Reading an observable (passed from the parent) forces `updateUIView` to run once the
    /// player's render view exists, so we can attach it.
    var isReady: Bool

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attach(to: uiView)
    }

    private func attach(to container: UIView) {
        guard let playerView = model.layer.player.view else { return }
        if playerView.superview !== container {
            playerView.removeFromSuperview()
            playerView.frame = container.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(playerView)
        }
    }
}

/// Inline + fullscreen scene player with custom controls and sprite scrubbing.
struct ScenePlayerView: View {
    let scene: StashScene
    let apiKey: String
    @Environment(\.imageCache) private var imageCache
    @State private var model: ScenePlayerModel
    @State private var sprites = SpriteThumbnails()
    @State private var isFullscreen = false

    init(scene: StashScene, apiKey: String, url: URL) {
        self.scene = scene
        self.apiKey = apiKey
        _model = State(initialValue: ScenePlayerModel(url: url))
    }

    var body: some View {
        surface(fullscreen: false)
            .fullScreenCover(isPresented: $isFullscreen) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    surface(fullscreen: true)
                        .ignoresSafeArea()
                }
            }
            .task {
                guard let vtt = scene.vttURL(apiKey: apiKey),
                      let sprite = scene.spriteURL(apiKey: apiKey) else { return }
                await sprites.load(vttURL: vtt, spriteURL: sprite, imageCache: imageCache)
            }
            // Rotate to landscape → fullscreen; back to portrait → inline.
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                let orientation = UIDevice.current.orientation
                if orientation.isLandscape, !isFullscreen {
                    isFullscreen = true
                } else if orientation.isPortrait, isFullscreen {
                    isFullscreen = false
                }
            }
            .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
            .onDisappear { if !isFullscreen { model.pause() } }
    }

    private func surface(fullscreen: Bool) -> some View {
        ZStack {
            KSPlayerSurface(model: model, isReady: model.isReady)
            PlayerControlsView(
                model: model,
                sprites: sprites,
                isFullscreen: $isFullscreen
            )
        }
    }
}
