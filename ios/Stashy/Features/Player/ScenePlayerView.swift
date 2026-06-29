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
    /// Inline only: top safe-area inset so the sharp video sits below the status bar while the
    /// blurred backdrop bleeds up behind the status bar / Dynamic Island.
    var contentTopInset: CGFloat = 0
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

    init(scene: StashScene, apiKey: String, url: URL, contentTopInset: CGFloat = 0, isFullscreen: Binding<Bool>, onBack: (() -> Void)? = nil) {
        self.scene = scene
        self.apiKey = apiKey
        self.contentTopInset = contentTopInset
        _isFullscreen = isFullscreen
        self.onBack = onBack
        _model = State(initialValue: ScenePlayerModel(url: url))
    }

    /// The video's display aspect (from file metadata, available immediately).
    private var aspect: CGFloat { scene.videoAspect ?? 16.0 / 9.0 }

    var body: some View {
        GeometryReader { geo in
            let avail = geo.size
            // Inline: reserve the top strip for the status bar and bottom-align the sharp video so its
            // bottom sits flush with the box (never blurred) — the blur fills the top / sides as needed.
            // Fullscreen: the surface fills the whole screen so zoom is immersive (uses the entire
            // display, including behind the Dynamic Island) instead of being trapped in a fit box.
            let inset = isFullscreen ? 0 : contentTopInset
            let videoArea = CGSize(width: avail.width, height: max(avail.height - inset, 1))
            let surfaceSize = isFullscreen ? avail : Self.fitSize(aspect: aspect, in: videoArea)

            ZStack(alignment: .bottom) {
                // Background: blurred poster inline (fills the gaps and the status-bar strip so
                // portrait/odd-ratio videos blend seamlessly); plain black in fullscreen, where
                // letterbox bars are fine because the video can be zoomed.
                Group {
                    if !isFullscreen, let poster {
                        Image(uiImage: poster).resizable().scaledToFill().blur(radius: 32)
                    } else {
                        Color.black
                    }
                }
                .frame(width: avail.width, height: avail.height)
                .clipped()
                .allowsHitTesting(false)

                // Tapping anywhere (including the blurred letterbox) toggles the controls.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { toggleControls() }
                    .frame(width: avail.width, height: avail.height)

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
                .frame(width: surfaceSize.width, height: surfaceSize.height)

                if !model.isReady {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: avail.width, height: avail.height)
                }

                PlayerControlsView(
                    model: model,
                    sprites: sprites,
                    isFullscreen: $isFullscreen,
                    showControls: $showControls,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    spritePreviewTopLeading: isFullscreen && scene.isPortraitVideo,
                    scheduleHide: { scheduleHide() },
                    onBack: onBack
                )
                .frame(width: avail.width, height: avail.height)
            }
            .frame(width: avail.width, height: avail.height)
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
        // Landscape videos: rotating to landscape enters fullscreen (and back to portrait exits).
        // Portrait videos never auto-rotate into a landscape fullscreen — they go fullscreen in
        // portrait via the button instead.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard !scene.isPortraitVideo else { return }
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
                // Portrait videos go fullscreen in portrait; everything else uses landscape.
                OrientationController.lock(scene.isPortraitVideo ? .portrait : [.landscapeLeft, .landscapeRight])
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

    /// Aspect-fit a video of `aspect` (w/h) inside `size`, returning the displayed size.
    static func fitSize(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, aspect > 0 else { return size }
        let containerAspect = size.width / size.height
        if aspect > containerAspect {
            return CGSize(width: size.width, height: size.width / aspect)
        } else {
            return CGSize(width: size.height * aspect, height: size.height)
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
