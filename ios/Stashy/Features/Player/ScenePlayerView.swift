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
    @State private var poster: UIImage?
    @State private var showControls = true
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?

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

            ZoomablePlayerSurface(
                model: model,
                isReady: model.isReady,
                zoomEnabled: isFullscreen,
                zoomScale: $zoomScale,
                isScrubbing: $isScrubbing,
                scrubTime: $scrubTime,
                onSingleTap: { toggleControls() },
                onScrubStart: { hideTask?.cancel(); showControls = true },
                onScrubEnd: { scheduleHide() },
                onSwipeDownDismiss: { if isFullscreen { isFullscreen = false } }
            )
            .ignoresSafeArea(edges: isFullscreen ? .all : [])

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
                showControls: $showControls,
                isScrubbing: $isScrubbing,
                scrubTime: $scrubTime,
                scheduleHide: { scheduleHide() },
                onBack: onBack
            )
        }
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
                // Force back to portrait even if the phone is still held in landscape. Zoom is reset
                // automatically by the surface once zoom is disabled (zoomEnabled = isFullscreen).
                OrientationController.lock(.portrait)
                if UIDevice.current.orientation.isLandscape {
                    suppressAutoFullscreen = true
                }
            }
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear {
            OrientationController.lock(.portrait)
            hideTask?.cancel()
            if !isFullscreen { model.pause() }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, model.isPlaying, !isScrubbing else { return }
            showControls = false
        }
    }

    private func toggleControls() {
        showControls.toggle()
        if showControls { scheduleHide() }
    }
}
