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
    /// Owns the on-device local stream (seekable HLS or linear remux) for a `.localFFmpeg` route.
    @ObservationIgnored private var localStream: (any LocalPlaybackStream)?
    /// Set once if the local pipeline fails and we switch to the HLS fallback (so we never loop).
    @ObservationIgnored private var didFallback = false
    /// Absolute time (seconds) the current local stream starts at. The linear remux is zero-based from a
    /// seek point, so the player's local time + this offset = the real scrub position. 0 until a far seek.
    @ObservationIgnored private var timeOffset: TimeInterval = 0
    /// True while a local zero-based remux drives playback (so time is offset and duration stays the full
    /// metadata value). False for direct play / HLS (incl. after a fallback), where engine time is absolute.
    private var usesAbsoluteTime: Bool { route.engine == .localFFmpeg && !didFallback }
    /// Guards re-entrant starts, and discards an engine built after the scene was already left.
    @ObservationIgnored private var startInProgress = false
    @ObservationIgnored private var stopped = false
    /// Overrides the displayed stream label after a fallback / transcode decision.
    var activeStreamType: String?
    /// Last engine failure reason (AVPlayer error / watchdog), surfaced in Stats for diagnosis.
    var lastError: String?
    /// Loopback server request log captured at the moment of fallback, for diagnosing remux stalls.
    var loopbackLog: [String] = []
    /// Fires a fallback if the local path produces no frames in time (covers stalls AVPlayer never
    /// reports as a hard failure).
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    /// The sharp-video render surface (re-parented into the zoom container).
    var renderView: UIView? { engine?.renderView }
    /// A live, frame-matched blurred backdrop vended by the engine.
    var liveBlurView: UIView? { engine?.liveBlurView }

    var backendName: String {
        if didFallback { return "AVPlayer (HLS fallback)" }
        switch route.engine {
        case .avPlayer: return "AVPlayer"
        case .localFFmpeg: return "FFmpeg remux → AVPlayer"
        }
    }
    var streamType: String { activeStreamType ?? route.streamType }
    var routingReason: String { route.reason }

    /// Side-effect-free on purpose. SwiftUI evaluates `State(initialValue:)` on *every* view init, so
    /// building the engine here (which creates an AVPlayer, activates the audio session, and starts
    /// playback) spun up multiple overlapping players — duplicate audio that kept playing after pause.
    /// The engine is created exactly once in `start()`, from `.onAppear`.
    init(route: PlaybackRoute) {
        self.route = route
        // Seed the scrubber's duration from Stash metadata. The local-HLS path is a growing EVENT
        // playlist (no ENDLIST until the remux finishes), so AVPlayer reports an *indefinite* duration
        // while playing — without this the scrubber would have nothing to map a swipe onto and seeking
        // would appear dead. Direct play / Stash VOD HLS overwrite this with the engine's real value.
        self.duration = max(0, route.duration)
    }

    /// Begin playback. Idempotent — safe to call on every `onAppear`. For `.localFFmpeg` routes this
    /// first decides (cached) whether Apple can decode the pixel format, so HEVC the device can't decode
    /// (4:2:2/4:4:4) skips the doomed remux and goes straight to HLS instead of stalling on it.
    func start() {
        guard engine == nil, !startInProgress else { return }
        startInProgress = true
        stopped = false
        RemoteLog.shared.log("▶︎ start: \(route.streamType) · \(route.reason) · engine=\(route.engine)")
        switch route.engine {
        case .avPlayer:
            adopt(makeEngine(url: route.url), stream: nil)
        case .localFFmpeg:
            beginLocalFFmpeg()
        }
    }

    private func beginLocalFFmpeg() {
        let key = route.url.path
        // Known-undecodable pixel format (cached): straight to HLS, skip opening the file entirely.
        if AppleDecodeCache.shared.decision(forKey: key) == true {
            buildFallback(reason: "HLS (Apple can't decode this pixel format)")
            return
        }
        // Probe the pixel format (off-main) for the decode decision, then play via the linear continuous
        // remux. The on-demand *segmented* HLS path (buildHLS) gave great seeking but choppy playback
        // across multiple files — independent per-segment muxing introduces frame-timing/audio-priming
        // discontinuities. The linear continuous remux played smoothly, so it's the default again; fast
        // seeking will be re-added on top of it (seek-by-reinit) rather than via per-segment muxing.
        Task { [weak self] in
            guard let self else { return }
            let info = await FFmpegSource(url: self.route.url).probeVideoInfo()
            let needsTranscode = info.map { ScenePlayerModel.needsTranscode(pixFmt: $0.pixFmt) } ?? false
            if info != nil { AppleDecodeCache.shared.setDecision(needsTranscode, forKey: key) }
            if needsTranscode {
                self.buildFallback(reason: "HLS (Apple can't decode this pixel format)")
            } else {
                self.buildLinear()
            }
        }
    }

    /// Seekable on-demand HLS from a prepared producer (mp4/mov). Best path: AVPlayer gets a VOD playlist
    /// it can seek anywhere in, and each segment is remuxed on demand.
    private func buildHLS(producer: HLSSegmentProducer) {
        guard !stopped else { producer.teardown(); return }
        do {
            let stream = LocalHLSStream(producer: producer)
            let url = try stream.start()
            activeStreamType = "On-device HLS (seekable)"
            if duration <= 0 { duration = producer.totalDuration }
            adopt(makeEngine(url: url), stream: stream)
            if engine != nil { armWatchdog() }
        } catch {
            producer.teardown()
            buildFallback(reason: "HLS (fallback)")
        }
    }

    /// Linear growing-file remux (containers without a usable keyframe table, e.g. some MKVs). Forward-only.
    private func buildLinear() {
        guard !stopped else { return }
        do {
            let stream = LocalRemuxStream(source: route.url, duration: route.duration)
            let url = try stream.start()
            activeStreamType = "On-device remux (linear)"
            adopt(makeEngine(url: url), stream: stream)
            if engine != nil { armWatchdog() }
        } catch {
            buildFallback(reason: "HLS (fallback)")
        }
    }

    /// Give up on the local path and play the Stash HLS (server transcode) fallback.
    private func buildFallback(reason: String) {
        guard !stopped else { return }
        didFallback = true
        activeStreamType = reason
        adopt(makeEngine(url: route.fallbackURL ?? route.url), stream: nil)
    }

    /// Commit a freshly-built engine + remux stream — unless the scene was left while we were starting
    /// (then discard them so no stray player or loopback server survives).
    private func adopt(_ engine: PlaybackEngine, stream: (any LocalPlaybackStream)?) {
        startInProgress = false
        guard !stopped else {
            engine.teardown()
            stream?.stop()
            return
        }
        self.engine = engine
        self.localStream = stream
        isPlaying = true
    }

    /// Apple's H.264/HEVC decoders handle only 4:2:0 (8/10-bit); 4:2:2, 4:4:4 and 12-bit need transcode.
    static func needsTranscode(pixFmt: String) -> Bool {
        let f = pixFmt.lowercased()
        return f.contains("422") || f.contains("444") || f.contains("12le") || f.contains("12be") || f.contains("gbr")
    }

    /// Build an AVPlayer engine for `url` and wire its callbacks into this facade.
    private func makeEngine(url: URL) -> PlaybackEngine {
        let engine: PlaybackEngine = AVPlaybackEngine(url: url)
        engine.onTime = { [weak self] current, duration in
            guard let self else { return }
            // Local zero-based remux: report absolute time (offset + local) and keep the full metadata
            // duration. Direct/HLS: engine time is already absolute and its duration is authoritative.
            self.currentTime = self.usesAbsoluteTime ? self.timeOffset + current : current
            if current > 0 { self.watchdog?.cancel() }   // real frames are flowing — disarm the stall watchdog
            if !self.usesAbsoluteTime, duration > 0, self.duration != duration { self.duration = duration }
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
        engine.onFailed = { [weak self] error in self?.fallbackToHLS(error: error) }
        return engine
    }

    /// Fall back if the local path produces no frames within 20s — catches stalls AVPlayer never reports
    /// as a hard `.failed`. Generous because the local-HLS first segment is a whole GOP that must be
    /// remuxed before playback can start (longest on a 4K long-GOP file).
    private func armWatchdog() {
        watchdog?.cancel()
        let startedAt = currentTime   // for a reinit this is the seek offset, not 0
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, !self.stopped, !self.didFallback,
                  self.currentTime <= startedAt + 0.1 else { return }
            self.fallbackToHLS(error: "local playback produced no frames in 20s")
        }
    }

    /// The local remux/loopback path failed (or stalled) — switch to the Stash HLS stream, once.
    /// Resetting `isReady` makes the zoom surface re-attach the new engine's render view.
    private func fallbackToHLS(error: String? = nil) {
        guard !didFallback, let fallback = route.fallbackURL else { return }
        didFallback = true
        watchdog?.cancel()
        RemoteLog.shared.log("⤵︎ fallback to Stash HLS: \(error ?? "—")")
        if let error { lastError = error }
        activeStreamType = "HLS (fallback)"
        loopbackLog = localStream?.diagnostics() ?? loopbackLog   // capture before tearing the server down
        engine?.teardown()
        localStream?.stop()
        localStream = nil
        timeOffset = 0            // the Stash HLS fallback is the full video from 0 (absolute time)
        isReady = false
        videoAspect = nil
        currentTime = 0
        engine = makeEngine(url: fallback)
        isPlaying = true
    }

    /// Tear down on leaving the scene: stop playback, remove the engine's observers (so the AVPlayer
    /// can't crash on dealloc), and stop the on-device remux + loopback server. Niling the engine lets
    /// `start()` rebuild cleanly if the scene is reopened.
    func stop() {
        stopped = true
        startInProgress = false
        watchdog?.cancel()
        engine?.teardown()
        engine = nil
        localStream?.stop()
        localStream = nil
        timeOffset = 0
    }

    func play() { engine?.play() }
    func pause() { engine?.pause() }
    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration > 0 ? duration : time))
        guard usesAbsoluteTime else {           // direct play / HLS — engine time is absolute
            currentTime = clamped
            engine?.seek(to: clamped)
            return
        }
        // Local linear remux: an in-stream seek only works within what's been produced from this stream's
        // start. A target before the stream start, or beyond the produced frontier, needs a remux restart
        // near the target keyframe (seek-by-reinit) — fast (~one startup) and stays smooth (continuous mux).
        let local = clamped - timeOffset
        let produced = localStream?.producedSeconds() ?? 0
        if local >= 0, local <= produced + 1.0 {
            currentTime = clamped
            engine?.seek(to: local)
        } else {
            reinitLocal(at: clamped)
        }
    }

    /// Restart the local linear remux from `time` (zero-based) and re-point AVPlayer at the new loopback
    /// stream — the way far seeks stay fast without the per-segment muxing that made playback choppy.
    private func reinitLocal(at time: TimeInterval) {
        guard !stopped else { return }
        RemoteLog.shared.log("↻ reinit local @\(Int(time))s")
        watchdog?.cancel()
        engine?.teardown()
        localStream?.stop()
        localStream = nil
        timeOffset = time
        currentTime = time
        isReady = false
        videoAspect = nil
        do {
            let stream = LocalRemuxStream(source: route.url, duration: route.duration, startTime: time)
            let url = try stream.start()
            adopt(makeEngine(url: url), stream: stream)
            if engine != nil { armWatchdog() }
        } catch {
            buildFallback(reason: "HLS (fallback)")
        }
    }

    /// Assemble a diagnostics snapshot for the Stats overlay: routing/backend facts + static media
    /// metadata + the engine's live metrics. Called ~1 Hz by the overlay, never on the render path.
    func snapshotStats(scene: StashScene) -> PlaybackStats {
        var sections: [StatSection] = []

        var playback = [
            StatLine(label: "Backend", value: backendName),
            StatLine(label: "Decode", value: engine?.decodeDescription ?? "—"),
            StatLine(label: "Stream", value: streamType),
            StatLine(label: "Routing", value: routingReason),
        ]
        if let lastError { playback.append(StatLine(label: "Error", value: lastError)) }
        sections.append(StatSection(title: "Playback", lines: playback))

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

        // Live loopback/index/remux state while the local-HLS path is actually playing (so we can see
        // produced bytes climb + which byte ranges AVPlayer is fetching, esp. during scrubbing).
        if let live = localStream?.diagnostics(), !live.isEmpty {
            sections.append(StatSection(title: "Loopback (live)", lines: live.map {
                StatLine(label: "·", value: $0)
            }))
        }

        // Loopback request log captured at fallback — diagnoses what AVPlayer asked the remux server for.
        if !loopbackLog.isEmpty {
            sections.append(StatSection(title: "Loopback", lines: loopbackLog.map {
                StatLine(label: "·", value: $0)
            }))
        }

        // Stash-transcoder details — only when we're actually using the server transcode (fell back, or
        // the route itself is server HLS), never for the on-device local-HLS path.
        let usingServerTranscode = didFallback || (route.engine == .avPlayer && streamType.localizedCaseInsensitiveContains("hls"))
        if usingServerTranscode {
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
