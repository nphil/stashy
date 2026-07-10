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
    @Binding var quality: ServerQuality
    /// Written by the controls just before a quality switch so the rebuilt player resumes at this second.
    @Binding var resumeTime: Double
    var onBack: (() -> Void)?
    @Environment(\.imageCache) private var imageCache
    @Environment(DownloadManager.self) private var downloads
    @State private var model: ScenePlayerModel
    @State private var sprites = SpriteThumbnails()
    /// After exiting fullscreen while the phone is still physically landscape, suppress re-entering
    /// fullscreen until the device returns to portrait (so ✕ doesn't immediately bounce back to landscape).
    @State private var suppressReentry = false
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
    /// False until the first `.onAppear`. A return here (popping back from a pushed performer / external
    /// link, which tore the engine down via `.onDisappear`) is a re-appear — it resumes AT the position but
    /// stays paused, per iOS norms. The first appear auto-plays.
    @State private var didAppear = false

    init(scene: StashScene, apiKey: String, route: PlaybackRoute, safeArea: EdgeInsets = EdgeInsets(), isFullscreen: Binding<Bool>, quality: Binding<ServerQuality>, resumeTime: Binding<Double>, onBack: (() -> Void)? = nil) {
        self.scene = scene
        self.apiKey = apiKey
        self.safeArea = safeArea
        _isFullscreen = isFullscreen
        _quality = quality
        _resumeTime = resumeTime
        self.onBack = onBack
        // Seed the (rebuilt) model with the position captured just before the source changed, plus the
        // file's load weight so the loading donut's expected time scales with how heavy this scene is.
        _model = State(initialValue: ScenePlayerModel(route: route, startAt: resumeTime.wrappedValue,
                                                      loadProfile: scene.loadProfile))
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

                // AI slow-mo (opt-in): the synthesised frame stream renders on a view hosted INSIDE this
                // surface's zoom container (see `syncSlowMoView`), so pinch/pan zoom it identically to the
                // video — reading `overlayActive` here also drives attach/detach.
                ZoomablePlayerSurface(
                    model: model,
                    isReady: model.isReady,
                    zoomEnabled: isFullscreen,
                    overlayActive: model.overlayActive,
                    zoomScale: $zoomScale,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    onSingleTap: { toggleControls() },
                    onScrubStart: { hideTask?.cancel(); showControls = true },
                    onScrubEnd: { scheduleHide() },
                    onSwipeDownDismiss: { if isFullscreen { isFullscreen = false } },
                    cueIndex: { sprites.cueIndex(at: $0) }
                )
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                // Best of both: the parent player box animates the fullscreen flip (smooth), but strip the
                // animation transaction from THIS scroll-view-backed surface so its zoom/contentSize setup
                // commits instantly & deterministically — the frame still follows the animated box each
                // tick, it just isn't wrapped in the Core-Animation transaction that raced (and killed)
                // pinch-zoom. Zero effect on slow-mo (hosted inside this same container).
                .transaction { $0.animation = nil }

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
                    scene: scene,
                    isFullscreen: $isFullscreen,
                    showControls: $showControls,
                    showStats: $showStats,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    quality: $quality,
                    resumeTime: $resumeTime,
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
            // NB: no `.animation(value: isFullscreen)` here. Animating this subtree animated the
            // ZoomablePlayerSurface's frame during fullscreen entry, racing the scroll view's zoom /
            // contentSize setup — which settled correctly only *sometimes*, so pinch-zoom died on ~8 of 10
            // playbacks (per-session, not per-pinch — the tell). Instant flip = deterministic zoom setup.
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
        // Orientation model — deliberately "sticky": tilting the phone to landscape ENTERS fullscreen, but
        // fullscreen is only ever LEFT via the ✕ button (or swipe-down), never by tilting back. This kills
        // the old auto-exit-on-portrait-tilt path, whose race with the geometry lock was the regression
        // ("UI stuck in landscape"). While fullscreen, device-orientation notifications are ignored entirely;
        // only the inline state reacts to tilt. faceUp/faceDown/unknown are ignored.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            guard !isFullscreen else { return }          // fullscreen is sticky — tilt can't exit it
            guard !isPortraitVideo else { return }       // vertical videos: button-only fullscreen (portrait)
            let orientation = UIDevice.current.orientation
            if orientation.isLandscape {
                if !suppressReentry { isFullscreen = true }
            } else if orientation.isPortrait {
                suppressReentry = false                  // back to portrait → allow tilt-to-enter again
            }
        }
        .onChange(of: isFullscreen) { _, now in
            // Park the edge-swipe-back while fullscreen: its always-armed edge-pan claims pinch touches
            // that start near the left edge (thumbs do, in landscape), killing zoom. Restored on exit.
            EnableSwipeBack.suppressed = now
            if now {
                // Portrait (vertical) videos go fullscreen in portrait; everything else forces landscape.
                OrientationController.lock(isPortraitVideo ? .portrait : [.landscapeLeft, .landscapeRight])
            } else {
                // Exit (✕ / swipe-down): force back to portrait even if the phone is still held landscape,
                // and suppress an immediate tilt-re-entry until the device physically returns to portrait.
                OrientationController.lock(.portrait)
                if UIDevice.current.orientation.isLandscape { suppressReentry = true }
            }
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            // First open auto-plays; a re-appear (returned from a pushed performer / external link) resumes
            // at the remembered position but stays paused — tap play to continue.
            model.start(autoplay: !didAppear)
            didAppear = true
        }
        .onDisappear {
            EnableSwipeBack.suppressed = false   // never leave the app-wide back-swipe parked
            hideTask?.cancel()
            // Leaving the scene: stop playback so audio can't keep running in the background.
            // NOTE: no orientation reset here — this view is rebuilt (`.id(route.url)`) on every
            // quality switch, and resetting to portrait here would kick fullscreen landscape back to
            // portrait mid-switch. Restoring portrait on a real exit is owned by SceneDetailView.
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
