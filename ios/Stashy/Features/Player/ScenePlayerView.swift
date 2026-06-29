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
        // Clear so the blurred poster behind shows through any letterbox bars.
        container.backgroundColor = .clear
        attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attach(to: uiView)
    }

    private func attach(to container: UIView) {
        guard let playerView = model.layer.player.view else { return }
        playerView.backgroundColor = .clear
        if playerView.superview !== container {
            playerView.removeFromSuperview()
            playerView.frame = container.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(playerView)
        }
    }
}

/// Scene player with custom controls and sprite scrubbing. Fullscreen is driven by a binding
/// from the parent, which simply resizes this same view in place — the render surface is never
/// re-parented, so it doesn't blank when rotating between inline and fullscreen.
struct ScenePlayerView: View {
    let scene: StashScene
    let apiKey: String
    @Binding var isFullscreen: Bool
    var onBack: (() -> Void)?
    @Environment(\.imageCache) private var imageCache
    @State private var model: ScenePlayerModel
    @State private var sprites = SpriteThumbnails()
    @State private var suppressAutoFullscreen = false
    @State private var zoomScale: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var zoomAnchor: UnitPoint = .center
    @State private var poster: UIImage?

    init(scene: StashScene, apiKey: String, url: URL, isFullscreen: Binding<Bool>, onBack: (() -> Void)? = nil) {
        self.scene = scene
        self.apiKey = apiKey
        _isFullscreen = isFullscreen
        self.onBack = onBack
        _model = State(initialValue: ScenePlayerModel(url: url))
    }

    var body: some View {
        ZStack {
            // Blurred poster fills the frame so portrait/odd-ratio videos sit on a seamless
            // backdrop instead of black bars (GPU blur, cheap — it's a single still image).
            Group {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill().blur(radius: 30)
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea(edges: isFullscreen ? .all : [])
            .clipped()
            .allowsHitTesting(false)

            KSPlayerSurface(model: model, isReady: model.isReady)
                .scaleEffect(isFullscreen ? zoomScale : 1, anchor: zoomAnchor)
                .ignoresSafeArea(edges: isFullscreen ? .all : [])
                .clipped()

            // Smooth loading indicator while the file spins up (e.g. NAS) before the first frame.
            if !model.isReady {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            PlayerControlsView(
                model: model,
                sprites: sprites,
                isFullscreen: $isFullscreen,
                zoomScale: $zoomScale,
                onBack: onBack
            )
        }
        // Pinch to zoom into the focal point (fullscreen only); the zoom persists after release.
        .simultaneousGesture(magnifyGesture)
        .task {
            guard let vtt = scene.vttURL(apiKey: apiKey),
                  let sprite = scene.spriteURL(apiKey: apiKey) else { return }
            await sprites.load(vttURL: vtt, spriteURL: sprite, imageCache: imageCache)
        }
        .task(id: scene.id) {
            guard let url = scene.thumbnailURL(apiKey: apiKey) else { return }
            poster = try? await imageCache.image(for: url)
        }
        // Rotate to landscape → fullscreen; back to portrait → inline. A manual exit while still
        // landscape suppresses auto re-entry until the device returns to portrait.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let orientation = UIDevice.current.orientation
            if orientation.isLandscape {
                if !suppressAutoFullscreen { isFullscreen = true }
            } else if orientation.isPortrait {
                suppressAutoFullscreen = false
                isFullscreen = false
            }
        }
        .onChange(of: isFullscreen) { _, now in
            if now {
                // Fullscreen is the only landscape surface in the app.
                OrientationController.lock([.landscapeLeft, .landscapeRight])
            } else {
                // Force back to portrait even if the phone is still held in landscape.
                OrientationController.lock(.portrait)
                resetZoom()
                if UIDevice.current.orientation.isLandscape {
                    suppressAutoFullscreen = true
                }
            }
        }
        // Keep the stored base zoom in sync when the controls reset zoom (swipe down while zoomed).
        .onChange(of: zoomScale) { _, value in
            if value <= 1 { baseZoom = 1; zoomAnchor = .center }
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear {
            OrientationController.lock(.portrait)
            if !isFullscreen { model.pause() }
        }
    }

    private func resetZoom() {
        zoomScale = 1
        baseZoom = 1
        zoomAnchor = .center
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard isFullscreen else { return }
                zoomAnchor = value.startAnchor
                zoomScale = min(4, max(1, baseZoom * value.magnification))
            }
            .onEnded { _ in
                guard isFullscreen else { return }
                if zoomScale < 1.05 {
                    withAnimation(.easeOut(duration: 0.2)) { zoomScale = 1 }
                    baseZoom = 1
                    zoomAnchor = .center
                } else {
                    baseZoom = zoomScale
                }
            }
    }
}
