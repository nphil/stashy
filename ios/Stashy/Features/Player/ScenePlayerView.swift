import SwiftUI

/// Scene player with custom controls and sprite scrubbing. Fullscreen is driven by a binding
/// from the parent, which simply resizes this same view in place — the render surface is never
/// re-parented, so it doesn't blank when rotating between inline and fullscreen.
///
/// Presentation only — playback orchestration lives in `ScenePlayerModel`.
struct ScenePlayerView: View {
    let scene: StashScene
    let apiKey: String
    /// The device safe-area insets, passed in because the player subtree zeroes them via
    /// `ignoresSafeArea`. Used to keep controls clear of the notch / home indicator in every mode, and
    /// (top edge) to reserve the status-bar strip for the blurred backdrop inline.
    var safeArea: EdgeInsets = EdgeInsets()
    @Binding var isFullscreen: Bool
    var onBack: (() -> Void)?
    @Environment(\.imageCache) private var imageCache
    @Environment(DownloadManager.self) private var downloads
    @State private var model: ScenePlayerModel
    @State private var sprites = SpriteThumbnails()
    @State private var suppressAutoFullscreen = false
    @State private var zoomScale: CGFloat = 1
    /// Live window geometry, used for fullscreen layout so it's identical regardless of the screen that
    /// presented the player (a plain stack vs a `.searchable` list report different ambient geometry).
    @State private var windowBounds: CGRect = .zero
    @State private var windowSafeArea = EdgeInsets()
    @State private var showControls = true
    @State private var showStats = false
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var hideTask: Task<Void, Never>?

    init(scene: StashScene, apiKey: String, route: PlaybackRoute, safeArea: EdgeInsets = EdgeInsets(), isFullscreen: Binding<Bool>, onBack: (() -> Void)? = nil) {
        self.scene = scene
        self.apiKey = apiKey
        self.safeArea = safeArea
        _isFullscreen = isFullscreen
        self.onBack = onBack
        _model = State(initialValue: ScenePlayerModel(route: route))
    }

    /// The video's display aspect. Prefer the *actual* decoded size reported by the player (correct
    /// for files whose server metadata is missing/wrong, e.g. some AVI/MPEG4), then file metadata,
    /// then a 16:9 default.
    private var aspect: CGFloat { model.videoAspect ?? scene.videoAspect ?? 16.0 / 9.0 }

    /// True when the video is taller than wide — from the actual decoded size when known, else metadata.
    private var isPortraitVideo: Bool { (model.videoAspect ?? scene.videoAspect).map { $0 < 1 } ?? false }

    var body: some View {
        GeometryReader { geo in
            // Fullscreen geometry comes from the actual window (live across rotation), so the player
            // lays out identically no matter what presented it — a plain stack and a `.searchable` list
            // hand a pushed view different ambient size/safe-area, which previously mis-sized the
            // fullscreen surface (zoomed past the screen, controls clipped) only on the search path.
            // Inline keeps the geometry of its fitted box.
            let fullscreenWindow = isFullscreen && windowBounds.width > 0 && windowBounds.height > 0
            let avail = fullscreenWindow ? windowBounds.size : geo.size
            let safe = fullscreenWindow ? windowSafeArea : safeArea
            // Inline: reserve the top strip for the status bar and bottom-align the sharp video so its
            // bottom sits flush with the box (never blurred) — the blur fills the top / sides as needed.
            // Fullscreen: the surface fills the whole screen so zoom is immersive (uses the entire
            // display, including behind the Dynamic Island) instead of being trapped in a fit box.
            let inset = isFullscreen ? 0 : safe.top
            let videoArea = CGSize(width: avail.width, height: max(avail.height - inset, 1))
            let surfaceSize = isFullscreen ? avail : Self.fitSize(aspect: aspect, in: videoArea)
            // The rectangle the sharp video actually occupies (bottom-aligned, horizontally centred),
            // used to centre the play/pause control and anchor the bottom control bar in every mode.
            let videoRect = CGRect(
                x: (avail.width - surfaceSize.width) / 2,
                y: avail.height - surfaceSize.height,
                width: surfaceSize.width,
                height: surfaceSize.height
            )

            ZStack(alignment: .bottom) {
                // Background blur that fills the status-bar strip and any letterbox gaps inline: a live,
                // frame-matched GPU blur of what's playing. Plain black in fullscreen, where letterbox
                // bars are fine because the video zooms (and the live blur pauses itself off-screen).
                Group {
                    if isFullscreen {
                        Color.black
                    } else if let blurView = model.liveBlurView {
                        PlayerBackdropHost(view: blurView)
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

                if model.didFail {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                        Text("Playback failed").font(.headline)
                        if let err = model.lastError {
                            Text(err).font(.caption).foregroundStyle(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        Text("Go back and try again.").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .frame(width: avail.width, height: avail.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                } else if model.isLoading {
                    VideoLoadingIndicator(progress: model.loadingProgress, message: model.loadingStage)
                        .frame(width: avail.width, height: avail.height)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                PlayerControlsView(
                    model: model,
                    sprites: sprites,
                    isFullscreen: $isFullscreen,
                    showControls: $showControls,
                    showStats: $showStats,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    videoRect: videoRect,
                    safeArea: safe,
                    spritePreviewTopLeading: false,   // always anchor the scrub preview above the bar
                    scheduleHide: { scheduleHide() },
                    onBack: onBack
                )
                .frame(width: avail.width, height: avail.height)

                if showStats && isFullscreen {
                    // Fullscreen-only debug overlay, anchored top-leading just below the back chevron.
                    StatsOverlayView(scene: scene, model: model,
                                     probeURL: scene.directFileURL(apiKey: apiKey),
                                     isLandscape: avail.width > avail.height)
                        .padding(.leading, max(videoRect.minX, safe.leading) + 12)
                        .padding(.top, max(videoRect.minY, safe.top) + 52)
                        .frame(width: avail.width, height: avail.height, alignment: .topLeading)
                }
            }
            .frame(width: avail.width, height: avail.height)
        }
        // Live window geometry for fullscreen layout (independent of the presenting screen's context).
        .background(WindowMetricsReader(bounds: $windowBounds, safeArea: $windowSafeArea))
        .task {
            // Prefer the locally-downloaded sprite sheet + VTT (instant, offline) when this scene has
            // been downloaded; fall back to the Stash endpoints otherwise.
            guard let vtt = downloads.localVTT(sceneID: scene.id) ?? scene.vttURL(apiKey: apiKey),
                  let sprite = downloads.localSprite(sceneID: scene.id) ?? scene.spriteURL(apiKey: apiKey) else { return }
            await sprites.load(vttURL: vtt, spriteURL: sprite, imageCache: imageCache)
        }
        // Landscape videos: rotating to landscape enters fullscreen (and back to portrait exits).
        // Portrait videos never auto-rotate into a landscape fullscreen — they go fullscreen in
        // portrait via the button instead.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard !isPortraitVideo else { return }
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
                OrientationController.lock(isPortraitVideo ? .portrait : [.landscapeLeft, .landscapeRight])
            } else {
                // Force back to portrait even if the phone is still held in landscape. Zoom is reset
                // automatically by the surface once zoom is disabled (zoomEnabled = isFullscreen).
                OrientationController.lock(.portrait)
                if UIDevice.current.orientation.isLandscape {
                    suppressAutoFullscreen = true
                }
            }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            model.start()
        }
        .onDisappear {
            OrientationController.lock(.portrait)
            hideTask?.cancel()
            // Leaving the scene: stop playback so audio can't keep running in the background.
            model.stop()
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
