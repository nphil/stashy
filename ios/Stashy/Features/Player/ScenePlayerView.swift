import SwiftUI

/// Observable facade over a `PlaybackEngine`. Today that's `AVPlaybackEngine` (native AVPlayer); the
/// on-device FFmpeg remux/transcode engine that will serve `.localFFmpeg` routes plugs in behind the
/// same protocol. The views bind only to this — the backend is swapped underneath. State pushed from
/// the engine is written *only when it actually changes*, so a per-frame time tick doesn't invalidate
/// the whole view tree (which previously forced a UIKit layout pass every frame and starved playback).
@Observable
@MainActor
final class ScenePlayerModel {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var isReady = false
    /// The actual decoded video aspect (w/h), once the player reports a presentation size. Drives
    /// layout/orientation when the server's file metadata is missing or wrong.
    var videoAspect: CGFloat?

    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private let route: PlaybackRoute

    /// The sharp-video render surface (re-parented into the zoom container).
    var renderView: UIView? { engine?.renderView }
    /// A live, frame-matched blurred backdrop vended by the engine.
    var liveBlurView: UIView? { engine?.liveBlurView }

    var backendName: String {
        switch route.engine {
        case .avPlayer: "AVPlayer"
        case .localFFmpeg: "FFmpeg (local)"
        }
    }
    var streamType: String { route.streamType }
    var routingReason: String { route.reason }

    /// Side-effect-free on purpose. SwiftUI evaluates `State(initialValue:)` on *every* view init, so
    /// building the engine here (which creates an AVPlayer, activates the audio session, and starts
    /// playback) spun up multiple overlapping players — duplicate audio that kept playing after pause.
    /// The engine is created exactly once in `start()`, from `.onAppear`.
    init(route: PlaybackRoute) {
        self.route = route
    }

    /// Create the engine and begin playback. Idempotent — safe to call on every `onAppear`.
    func start() {
        guard engine == nil else { return }
        // Phase 0: every route plays on AVPlayer (HLS, or direct). The on-device FFmpeg engine that
        // will serve `.localFFmpeg` routes is wired up in the next phase.
        let engine: PlaybackEngine = AVPlaybackEngine(url: route.url)
        engine.onTime = { [weak self] current, duration in
            guard let self else { return }
            self.currentTime = current
            if self.duration != duration { self.duration = duration }
            if !self.isReady { self.isReady = true }
        }
        engine.onReady = { [weak self] ready in
            guard let self, self.isReady != ready else { return }
            self.isReady = ready
        }
        engine.onPlaying = { [weak self] playing in
            guard let self, self.isPlaying != playing else { return }
            self.isPlaying = playing
        }
        engine.onPresentationSize = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            let aspect = size.width / size.height
            if self.videoAspect != aspect { self.videoAspect = aspect }
        }
        self.engine = engine
        isPlaying = true
    }

    /// Stop playback when leaving the scene so audio can't continue in the background.
    func stop() { engine?.pause() }

    func play() { engine?.play() }
    func pause() { engine?.pause() }
    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        currentTime = clamped
        engine?.seek(to: clamped)
    }

    /// Assemble a diagnostics snapshot for the Stats overlay: routing/backend facts + static media
    /// metadata + the engine's live metrics. Called ~1 Hz by the overlay, never on the render path.
    func snapshotStats(scene: StashScene) -> PlaybackStats {
        var sections: [StatSection] = []

        sections.append(StatSection(title: "Playback", lines: [
            StatLine(label: "Backend", value: backendName),
            StatLine(label: "Decode", value: engine?.decodeDescription ?? "—"),
            StatLine(label: "Stream", value: streamType),
            StatLine(label: "AVPlayer use", value: routingReason),
        ]))

        // Proof the self-built FFmpeg links + is callable (foundation for the local transcode pipeline).
        sections.append(StatSection(title: "Engine", lines: [
            StatLine(label: "FFmpeg", value: FFmpegProbe.versionInfo),
            StatLine(label: "VT h264 enc", value: FFmpegProbe.hasVideoToolboxH264 ? "yes" : "no"),
        ]))

        var media: [StatLine] = []
        if let c = scene.codecLabel { media.append(StatLine(label: "Codec", value: c)) }
        let container = scene.fileContainer
        if !container.isEmpty { media.append(StatLine(label: "Container", value: ".\(container)")) }
        if let r = scene.resolutionLabel { media.append(StatLine(label: "Resolution", value: r)) }
        if let ar = scene.aspectRatioLabel { media.append(StatLine(label: "Aspect", value: ar)) }
        if let b = scene.bitrateLabel { media.append(StatLine(label: "File bitrate", value: b)) }
        if let f = scene.frameRateLabel { media.append(StatLine(label: "Frame rate", value: f)) }
        if !media.isEmpty { sections.append(StatSection(title: "Media", lines: media)) }

        sections.append(StatSection(title: "Network", lines: engine?.liveStats() ?? []))

        // Reserved home for future Stash-transcoder details (only when actually transcoding).
        if streamType.localizedCaseInsensitiveContains("transcod") || streamType.localizedCaseInsensitiveContains("hls") {
            sections.append(StatSection(title: "Transcode", lines: [
                StatLine(label: "Source", value: "Stash transcoder"),
            ]))
        }

        return PlaybackStats(sections: sections)
    }
}

/// Scene player with custom controls and sprite scrubbing. Fullscreen is driven by a binding
/// from the parent, which simply resizes this same view in place — the render surface is never
/// re-parented, so it doesn't blank when rotating between inline and fullscreen.
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
                    showStats: $showStats,
                    isScrubbing: $isScrubbing,
                    scrubTime: $scrubTime,
                    videoRect: videoRect,
                    safeArea: safe,
                    spritePreviewTopLeading: isFullscreen && isPortraitVideo,
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
            guard let vtt = scene.vttURL(apiKey: apiKey),
                  let sprite = scene.spriteURL(apiKey: apiKey) else { return }
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
