import SwiftUI
import AVFoundation

/// Observable facade over a `PlaybackEngine`. Today that's `AVPlaybackEngine` (native AVPlayer); the
/// on-device FFmpeg remux/transcode engine that will serve `.localFFmpeg` routes plugs in behind the
/// same protocol. The views bind only to this — the backend is swapped underneath. State pushed from
/// the engine is written *only when it actually changes*, so a per-frame time tick doesn't invalidate
/// the whole view tree (which previously forced a UIKit layout pass every frame and starved playback).
///
/// Owns playback orchestration: routing dispatch, the engine facade + callback wiring, seek-by-reinit,
/// the pacing playhead feed, the no-frames watchdog, absolute-time/offset mapping, seek-hold, loading
/// state, and the Stats snapshot. The SwiftUI presentation lives in `ScenePlayerView`.
@Observable
@MainActor
final class ScenePlayerModel {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isPlaying = false
    var isReady = false { didSet { if isReady != oldValue { syncLoadEstimate() } } }
    /// True while the player is waiting on data (start-up or a rebuffer) — drives the loading donut
    /// instead of a play/pause icon that flickers as the transport state toggles.
    var isBuffering = false { didSet { if isBuffering != oldValue { syncLoadEstimate() } } }
    /// Short, human label for the current load stage (e.g. "Connecting…", "Remuxing on device…").
    var loadingStage = "Connecting…"
    /// Start-up buffer fill (0…1) for the donut; nil = indeterminate (pre-buffer stages).
    var loadingProgress: Double?
    /// Show the loading donut until the first frame is up *and* the player isn't waiting on data.
    var isLoading: Bool { !isReady || isBuffering }
    /// The actual decoded video aspect (w/h), once the player reports a presentation size. Drives
    /// layout/orientation when the server's file metadata is missing or wrong.
    var videoAspect: CGFloat?
    /// The actual decoded frame size the player is rendering (NOT the source file's metadata). This is the
    /// honest "what am I really watching" gauge — e.g. it drops to 1280×720 when a server transcode
    /// downscales, so the Stats overlay can prove whether a manual quality switch actually took effect.
    var presentationSize: CGSize = .zero
    /// Linear playback volume 0…1. Every scene starts silent (0); the volume control raises it, and the
    /// level carries across engine swaps (quality switch / seek-reinit / fallback).
    var volume: Double = 0
    /// Convenience for the UI: silent when the volume is (effectively) zero.
    var isMuted: Bool { volume <= 0.001 }
    /// The last non-zero level, so a tap-to-mute can restore the previous volume.
    @ObservationIgnored private var lastNonZeroVolume: Double = 1
    /// Playback speed (1 = normal). Applied live to the engine and re-applied to every rebuilt engine
    /// (seek-reinit / quality / fallback swaps all go through `makeEngine`), so speed survives them.
    private(set) var playbackRate: Double = 1
    /// When true, audio is muted while playing slower than 1× (slowed audio is usually unwanted); when
    /// false it plays pitch-corrected at the slow speed. Persisted across launches. Only affects sub-1×.
    var muteWhenSlowed: Bool = UserDefaults.standard.object(forKey: "player.muteWhenSlowed") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(muteWhenSlowed, forKey: "player.muteWhenSlowed")
            applySlowMute()
        }
    }
    /// **Opt-in** for on-device AI slow-mo interpolation (default OFF). Apple's `VTLowLatencyFrame
    /// Interpolation` (iOS 26) hard-crashes inside the framework on certain inputs (undocumented dimension/
    /// format restrictions — not catchable from Swift), so it must not auto-engage on a daily-driven app.
    /// Persisted; toggling re-evaluates engagement.
    var aiSlowMoEnabled: Bool = UserDefaults.standard.bool(forKey: "player.aiSlowMo") {
        didSet {
            UserDefaults.standard.set(aiSlowMoEnabled, forKey: "player.aiSlowMo")
            updateSlowMo()
        }
    }
    /// On-device AI slow-mo (VTFrameProcessor frame interpolation) live telemetry, surfaced in the Stats
    /// overlay. Driven by `slowMoRunner` while playback is ≤0.5×. Read ~1 Hz by the overlay, so it needn't
    /// be observable — it's snapshotted on each poll.
    @ObservationIgnored private var slowMoTelemetry = SlowMoTelemetry()
    /// Live AI-interpolation telemetry, read once a second by the Stats overlay's compute graphic (the
    /// Neural-Engine row). `@ObservationIgnored` on the storage keeps the render path from churning; the
    /// overlay's periodic tick re-reads it.
    var slowMoStats: SlowMoTelemetry { slowMoTelemetry }
    /// Runs the frame-interpolation pipeline while slow-mo is engaged (nil when disengaged).
    @ObservationIgnored private var slowMoRunner: SlowMoRunner?
    /// Pending auto re-engage after a seek/pause suspended slow-mo (debounced; cancelled by the next
    /// suspension or teardown).
    @ObservationIgnored private var slowMoReengage: Task<Void, Never>?
    /// True while the AI slow-mo render overlay should be shown — drives `ScenePlayerView` to overlay the
    /// interpolated frame stream on top of the (hidden) player surface.
    var slowMoActive = false
    /// The runner's render view (interpolated frame stream). Read by `ScenePlayerView` when `slowMoActive`.
    @ObservationIgnored var slowMoRenderView: UIView?
    /// True once playback has run to the end (player parked there). The next play() restarts from 0.
    @ObservationIgnored private var reachedEnd = false

    @ObservationIgnored private var engine: PlaybackEngine?
    @ObservationIgnored private let route: PlaybackRoute
    /// Plugin-free descriptor of how heavy this file is to start/seek — scales the loading-donut estimate
    /// (see LoadProfile). Constant for the model's lifetime, so the load and seek weights match.
    @ObservationIgnored private let loadProfile: LoadProfile
    private var loadWeight: Double { loadProfile.weight }
    /// Owns the on-device local stream (seekable HLS or linear remux) for a `.localFFmpeg` route.
    @ObservationIgnored private var localStream: (any LocalPlaybackStream)?
    /// Set once if the local pipeline fails and we switch to the HLS fallback (so we never loop).
    @ObservationIgnored private var didFallback = false
    /// Absolute time (seconds) the current local stream starts at. The linear remux is zero-based from a
    /// seek point, so the player's local time + this offset = the real scrub position. 0 until a far seek.
    @ObservationIgnored private var timeOffset: TimeInterval = 0
    /// After a seek, hold the scrubber at the requested time until the player actually lands there — so
    /// time ticks reporting the pre-seek position don't make the thumb pop back then forward.
    @ObservationIgnored private var seekTarget: TimeInterval?
    /// Safety cap on the seek-hold so a player that stalls just short of the target can't freeze the thumb.
    @ObservationIgnored private var seekHoldUntil = Date.distantPast
    /// True while a local zero-based remux drives playback (so time is offset and duration stays the full
    /// metadata value). False for direct play / HLS (incl. after a fallback), where engine time is absolute.
    private var usesAbsoluteTime: Bool { route.engine == .localFFmpeg && !didFallback }
    /// Whether a seek can be frame-accurate (zero tolerance) so the video lands exactly where the scrub
    /// sprite previewed. True for local media — the on-device loopback remux, and direct play of a file/
    /// direct stream (both seek near-instantly). False once we've fallen back to a Stash *server* HLS
    /// transcode, or for an initial server-HLS (`.m3u8`) route, where a zero-tolerance seek would stall.
    private var seekPrecise: Bool {
        if didFallback { return false }
        if route.engine == .localFFmpeg { return true }
        return route.url.pathExtension.lowercased() != "m3u8"
    }
    /// Guards re-entrant starts, and discards an engine built after the scene was already left.
    @ObservationIgnored private var startInProgress = false
    @ObservationIgnored private var stopped = false
    /// When true, the first engine adopts paused instead of auto-playing. Set by `start(autoplay:)` so a
    /// return-from-navigation (performer / external link) resumes AT the position but stays paused — the
    /// user taps play to continue, matching iOS norms (a pushed-then-popped video shouldn't silently resume).
    /// Consumed once, on the first `adopt`.
    @ObservationIgnored private var startPaused = false

    // Loading-donut estimate: blend the real buffer fill with a time-based curve paced by a learned
    // per-tier average, so the ring never sits at 0 (server transcode) nor snaps 0→100.
    @ObservationIgnored private var bufferFraction: Double = 0     // real buffer signal from the engine
    @ObservationIgnored private var loadStart: Date?              // wall-clock start of this load episode
    @ObservationIgnored private var expectedLoad: Double = 1      // learned expected seconds for the curve
    @ObservationIgnored private var loadTier: PlaybackTier = .direct
    @ObservationIgnored private var loadCurve: LoadCurveParams = .forTier(.direct)  // fill shape for this episode
    /// True while the current loading episode was kicked by a seek (reinit or an in-stream re-buffer) — it
    /// picks the warm per-seek estimate + snappy fill curve instead of the cold first-load ones, and files
    /// the recorded duration into the seek bucket. Cleared when the episode ends.
    @ObservationIgnored private var loadIsSeek = false
    @ObservationIgnored private var loadTicker: Task<Void, Never>?
    @ObservationIgnored private var wasLoading = false
    /// Overrides the displayed stream label after a fallback / transcode decision.
    var activeStreamType: String?
    /// Last engine failure reason (AVPlayer error / watchdog), surfaced in Stats for diagnosis.
    var lastError: String?
    /// Terminal playback failure with no fallback route left — drives an honest error overlay instead of
    /// a loading donut that would otherwise spin forever. Resets naturally: reopening the scene builds a
    /// fresh model.
    var didFail = false
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

    /// Frames actually presented to screen since stats sampling was armed (decode-fps row). 0 when off.
    var presentedFrameCount: Int { (engine as? AVPlaybackEngine)?.presentedFrameCount ?? 0 }
    /// Cumulative frames the player dropped (arrived too late) — the dropped-frames-per-second row deltas it.
    var droppedFrameCount: Int { (engine as? AVPlaybackEngine)?.droppedFrameCount ?? 0 }

    /// Whether the Stats overlay is open — arms the engine's presented-frame counter. Remembered so an
    /// engine rebuild (seek-reinit / quality / fallback) re-arms it. Set by `StatsOverlayView`.
    @ObservationIgnored private var statsSampling = false
    func setStatsSampling(_ on: Bool) {
        statsSampling = on
        (engine as? AVPlaybackEngine)?.setFrameRateProbeActive(on)
    }

    /// Side-effect-free on purpose. SwiftUI evaluates `State(initialValue:)` on *every* view init, so
    /// building the engine here (which creates an AVPlayer, activates the audio session, and starts
    /// playback) spun up multiple overlapping players — duplicate audio that kept playing after pause.
    /// The engine is created exactly once in `start()`, from `.onAppear`.
    /// `startAt` > 0 resumes playback at that timestamp once the new engine is ready — used to keep the
    /// exact position when the source is rebuilt (e.g. switching server-transcode quality via the gear).
    init(route: PlaybackRoute, startAt: Double = 0, loadProfile: LoadProfile = LoadProfile()) {
        self.route = route
        self.loadProfile = loadProfile
        self.resumeAt = max(0, startAt)
        // Seed the scrubber's duration from Stash metadata. The local-HLS path is a growing EVENT
        // playlist (no ENDLIST until the remux finishes), so AVPlayer reports an *indefinite* duration
        // while playing — without this the scrubber would have nothing to map a swipe onto and seeking
        // would appear dead. Direct play / Stash VOD HLS overwrite this with the engine's real value.
        self.duration = max(0, route.duration)
        // Show the scrubber at the resume point immediately so it doesn't flash 0:00 before the seek lands.
        self.currentTime = self.resumeAt
    }

    /// One-time resume seek target (set at init); consumed the first time the engine reports ready.
    private let resumeAt: Double
    private var didResumeSeek = false
    /// Position (seconds) to resume from the next time the engine restarts. Set on teardown so leaving for
    /// a performer / external link and coming back resumes where you were instead of restarting from 0.
    /// The model persists across the navigation (SceneDetailView stays in the stack), so this survives.
    @ObservationIgnored private var pendingResume: Double = 0

    /// Begin playback. Idempotent — safe to call on every `onAppear`. For `.localFFmpeg` routes this
    /// first decides (cached) whether Apple can decode the pixel format, so HEVC the device can't decode
    /// (4:2:2/4:4:4) skips the doomed remux and goes straight to HLS instead of stalling on it.
    func start(autoplay: Bool = true) {
        guard engine == nil, !startInProgress else { return }
        startInProgress = true
        startPaused = !autoplay
        stopped = false
        RemoteLog.shared.log("▶︎ start: \(route.streamType) · \(route.reason) · engine=\(route.engine)")
        switch route.engine {
        case .avPlayer:
            loadingStage = route.streamType.localizedCaseInsensitiveContains("hls") ? "Transcoding on server…" : "Loading…"
            adopt(makeEngine(url: route.url), stream: nil)
            // AV1 direct play carries an HLS fallback (its pixel format isn't pre-probed like the remux
            // path). If a 4:2:2/4:4:4/12-bit AV1 renders no frames, fall back rather than sit on black.
            if engine != nil, route.fallbackURL != nil { armWatchdog() }
        case .localFFmpeg:
            beginLocalFFmpeg()
        }
        syncLoadEstimate()   // kick the loading-donut estimate for the initial load (isReady already false)
    }

    private func beginLocalFFmpeg() {
        let key = route.url.path
        loadingStage = "Reading video…"
        // A downloaded local file: remux straight away. The pixel-format probe below uses FFmpegSource,
        // which reads over HTTP (URLSession range requests) and can't open a `file://` URL — running it
        // here would hang/fail. The common downloaded case (8-bit 4:2:0 HEVC) remuxes fine; a rare
        // undecodable pixel format has no server fallback offline anyway, so probing buys nothing.
        if route.url.isFileURL {
            buildLinear()
            return
        }
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

    /// Linear continuous remux → byte-range HLS over the loopback. Plays smoothly (one continuous mux);
    /// far seeks restart it at the target (seek-by-reinit). The default for the remux class.
    private func buildLinear() {
        guard !stopped else { return }
        do {
            loadingStage = "Remuxing on device…"
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
        loadingStage = "Transcoding on server…"
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
        // A return-from-navigation start adopts paused: keep the engine parked so the video resumes at the
        // remembered position (via the first-ready seek) but doesn't silently start playing. The user taps
        // play. Consumed here so any later engine rebuild (seek-reinit / quality / fallback) auto-plays.
        if startPaused {
            startPaused = false
            engine.pause()
            isPlaying = false
        } else {
            isPlaying = true
        }
    }

    /// Apple's H.264/HEVC decoders handle only 4:2:0 (8/10-bit); 4:2:2, 4:4:4 and 12-bit need transcode.
    static func needsTranscode(pixFmt: String) -> Bool {
        let f = pixFmt.lowercased()
        return f.contains("422") || f.contains("444") || f.contains("12le") || f.contains("12be") || f.contains("gbr")
    }

    /// Build an AVPlayer engine for `url` and wire its callbacks into this facade.
    private func makeEngine(url: URL) -> PlaybackEngine {
        let engine: PlaybackEngine = AVPlaybackEngine(url: url)
        // Every engine (the initial one and any seek-reinit / quality / fallback swap) inherits the
        // current volume — which starts at 0, so playback always begins silent until the user raises it.
        engine.volume = Float(volume)
        // …and the current playback speed + slow-mute policy, so a mid-scene rate change survives reinit.
        engine.playbackRate = Float(playbackRate)
        engine.slowMute = playbackRate < 1 && muteWhenSlowed
        engine.onTime = { [weak self] current, duration in
            guard let self else { return }
            let absolute = self.usesAbsoluteTime ? self.timeOffset + current : current
            self.localStream?.updatePlayhead(current)   // lets the remux pace production to the playhead
            if current > 0 { self.watchdog?.cancel() }   // real frames are flowing — disarm the stall watchdog
            if !self.usesAbsoluteTime, duration > 0, self.duration != duration { self.duration = duration }
            if !self.isReady {
                self.isReady = true
                // Resume point on first ready: a nav-away teardown (pendingResume — set every time we leave
                // for a performer / external link, so returning resumes instead of restarting from 0), or
                // the one-time quality-switch resume (resumeAt). Seek once, before releasing the scrubber.
                let resumeTarget = self.pendingResume > 0 ? self.pendingResume
                                 : (!self.didResumeSeek ? self.resumeAt : 0)
                if resumeTarget > 0 {
                    self.didResumeSeek = true
                    self.pendingResume = 0
                    self.seek(to: resumeTarget)
                    return
                }
            }
            // Hold the scrubber at a just-issued seek target until the player reaches it (no pop-back).
            // Tolerance exceeds AVPlayer's ±1s seek tolerance; the deadline guards a stall short of target.
            if let target = self.seekTarget {
                if abs(absolute - target) < 1.5 || Date() > self.seekHoldUntil { self.seekTarget = nil }
                else { return }
            }
            // Never let the reported time exceed the known duration (a zero-based remux can produce a
            // hair past the end, and rounding at the very end could otherwise show > total).
            self.currentTime = self.duration > 0 ? min(absolute, self.duration) : absolute
        }
        engine.onReady = { [weak self] ready in
            guard let self, self.isReady != ready else { return }
            self.isReady = ready
        }
        engine.onState = { [weak self] phase in
            guard let self else { return }
            let playing = phase == .playing
            if self.isPlaying != playing { self.isPlaying = playing }
            let buffering = phase == .waiting
            if self.isBuffering != buffering { self.isBuffering = buffering }
        }
        engine.onLoadProgress = { [weak self] progress in
            guard let self else { return }
            // Feed the real buffer signal into the estimate; the ticker owns `loadingProgress` so the
            // donut blends this with the time curve (never stuck at 0, never a raw 0→100 snap).
            self.bufferFraction = progress
        }
        engine.onEnded = { [weak self] in
            guard let self else { return }
            self.reachedEnd = true
            self.isPlaying = false
        }
        engine.onPresentationSize = { [weak self] size in
            guard let self, size.width > 0, size.height > 0 else { return }
            let aspect = size.width / size.height
            if self.videoAspect != aspect { self.videoAspect = aspect }
            let firstFrame = self.presentationSize == .zero
            if self.presentationSize != size { self.presentationSize = size }
            if firstFrame {
                // Now that the decoded frame size is known, engage slow-mo if the user is already ≤0.5×
                // (e.g. the rate was set before the first frame, or the engine was just rebuilt).
                self.updateSlowMo()
            }
        }
        engine.onFailed = { [weak self] error in self?.fallbackToHLS(error: error) }
        // If the Stats overlay is open, re-arm the presented-frame counter on this (possibly rebuilt) engine.
        if statsSampling { (engine as? AVPlaybackEngine)?.setFrameRateProbeActive(true) }
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
        guard !stopped else { return }   // the scene was already left — don't resurrect a zombie engine
        guard !didFallback, let fallback = route.fallbackURL else {
            // No fallback route (direct play / server-HLS / downloaded / last-resort), or the HLS fallback
            // itself already failed — this is terminal. Surface it instead of spinning the donut forever.
            if let error { lastError = error }
            isBuffering = false
            loadingStage = "Playback failed"
            didFail = true
            return
        }
        didFallback = true
        watchdog?.cancel()
        RemoteLog.shared.log("⤵︎ fallback to Stash HLS: \(error ?? "—")")
        if let error { lastError = error }
        activeStreamType = "HLS (fallback)"
        engine?.teardown()
        localStream?.stop()
        localStream = nil
        timeOffset = 0            // the Stash HLS fallback is the full video from 0 (absolute time)
        isReady = false
        loadingStage = "Transcoding on server…"
        loadingProgress = nil
        seekTarget = nil
        videoAspect = nil
        presentationSize = .zero
        currentTime = 0
        engine = makeEngine(url: fallback)
        isPlaying = true
    }

    /// Tear down on leaving the scene: stop playback, remove the engine's observers (so the AVPlayer
    /// can't crash on dealloc), and stop the on-device remux + loopback server. Niling the engine lets
    /// `start()` rebuild cleanly if the scene is reopened.
    func stop() {
        // Remember where we were so a rebuild (returning from a performer / external link) resumes here
        // rather than restarting from 0. Harmless on a true leave (the model is discarded).
        if currentTime > 1 { pendingResume = currentTime }
        stopped = true
        startInProgress = false
        slowMoReengage?.cancel(); slowMoReengage = nil
        slowMoRunner?.stop()
        slowMoRunner = nil
        slowMoRenderView = nil
        slowMoActive = false
        watchdog?.cancel()
        loadTicker?.cancel(); loadTicker = nil
        loadStart = nil
        wasLoading = false
        engine?.teardown()
        engine = nil
        localStream?.stop()
        localStream = nil
        timeOffset = 0
        seekTarget = nil
    }

    // MARK: - Loading-donut estimate

    /// Detect the edge of the loading state (`!isReady || isBuffering`) and start/stop the estimate.
    private func syncLoadEstimate() {
        let loading = isLoading
        if loading, !wasLoading { beginLoadEstimate() }
        else if !loading, wasLoading { finishLoadEstimate() }
        wasLoading = loading
    }

    private func beginLoadEstimate() {
        loadStart = Date()
        loadTier = playbackTier
        // A seek's re-buffer is warm (source already open) — fill from the per-seek estimate + curve so the
        // ring races to near-full quickly, rather than crawling on the slower cold-start estimate.
        if loadIsSeek {
            expectedLoad = LoadEstimator.shared.expectedSeek(for: loadTier, weight: loadWeight)
            loadCurve = .seek
        } else {
            expectedLoad = LoadEstimator.shared.expected(for: loadTier, weight: loadWeight)
            loadCurve = .forTier(loadTier)
        }
        bufferFraction = 0
        tickLoadingProgress()
        loadTicker?.cancel()
        loadTicker = Task { @MainActor [weak self] in
            while let self, self.isLoading, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                self.tickLoadingProgress()
            }
        }
    }

    private func finishLoadEstimate() {
        loadTicker?.cancel(); loadTicker = nil
        if let loadStart {
            let seconds = Date().timeIntervalSince(loadStart)
            if loadIsSeek { LoadEstimator.shared.recordSeek(tier: loadTier, seconds: seconds, weight: loadWeight) }
            else { LoadEstimator.shared.record(tier: loadTier, seconds: seconds, weight: loadWeight) }
        }
        loadStart = nil
        loadIsSeek = false   // the next episode is cold unless another seek sets it
        loadingProgress = 1
    }

    /// Donut fill = the real buffer signal OR a time estimate (whichever is further), capped just below
    /// full until playback is genuinely ready.
    ///
    /// The estimate tracks **fraction of the expected load time**: it fills roughly linearly to ~0.9 by
    /// the expected completion (so when the video is ready around that time, the ring is near-full and the
    /// snap to 100% is small), then eases toward a cap for over-long loads so it keeps creeping without
    /// ever hitting 100% early. (The previous `elapsed/(elapsed+k)` shape mathematically maxed at ~0.57 at
    /// the expected time — hence the ring consistently stalling around half while the video was ready.)
    private func tickLoadingProgress() {
        guard let loadStart else { return }
        let elapsed = Date().timeIntervalSince(loadStart)
        // Per-episode shaping (cold-start-per-tier, or the snappy seek curve) applied to the real learned
        // time — fast local modes fill ahead of real time, server transcode fills near real time with a
        // brisk tail. Chosen once in beginLoadEstimate. See LoadCurveParams.
        let p = loadCurve
        let e = max(0.3, expectedLoad / p.pace)
        let timeCurve: Double
        if elapsed <= e {
            timeCurve = p.knee * (elapsed / e)                                            // steady fill → knee
        } else {
            timeCurve = p.knee + (p.cap - p.knee) * (1 - exp(-(elapsed - e) / (e * p.tailFrac)))  // brisk tail
        }
        let display = min(p.cap, max(bufferFraction, timeCurve))
        if loadingProgress != display { loadingProgress = display }
    }

    func play() {
        if reachedEnd {
            // Playback was parked at the end — restart from the beginning instead of no-opping at EOF.
            reachedEnd = false
            seek(to: 0)
        }
        engine?.play()
        // Resuming after a pause (which suspended slow-mo) re-arms the fresh engage.
        scheduleSlowMoReengage()
    }
    func pause() {
        engine?.pause()
        // Pausing suspends AI slow-mo (runner torn down, RATE KEPT — the pill stays at 0.25×/0.5×);
        // play() re-arms a fresh engage once playback stabilises.
        suspendSlowMo()
    }
    func togglePlayPause() { isPlaying ? pause() : play() }

    /// Suspend AI slow-mo across a user interaction (seek/pause): tear the runner down exactly like the
    /// manual toggle-off does, keeping the playback rate. Re-engagement goes through
    /// `scheduleSlowMoReengage` — a FRESH runner on stabilised playback is the one proven-smooth path;
    /// the in-place pipeline repairs this replaces were fragile and jittery (three attempts, all reverted).
    private func suspendSlowMo() {
        slowMoReengage?.cancel(); slowMoReengage = nil
        guard slowMoRunner != nil else { return }
        slowMoRunner?.stop()
        slowMoRunner = nil
        slowMoRenderView = nil
        slowMoActive = false
        slowMoTelemetry = SlowMoTelemetry()
    }

    /// Debounced auto re-engage — the programmatic equivalent of toggling AI slow-mo off/on: once playback
    /// has stabilised (playing, ready, not buffering) build a brand-new runner. The 0.4s poll debounces
    /// rapid scrubbing into a single engage after the last seek settles; it gives up after ~6s (the next
    /// play()/seek re-arms). No-op unless the AI toggle is on and the rate is a slow-mo rung.
    private func scheduleSlowMoReengage() {
        slowMoReengage?.cancel()
        guard aiSlowMoEnabled, playbackRate > 0, playbackRate <= 0.5, slowMoRunner == nil else { return }
        slowMoReengage = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled, !self.stopped else { return }
                if self.isPlaying, self.isReady, !self.isBuffering {
                    self.updateSlowMo()   // re-checks the toggle/rate/engine at fire time
                    return
                }
            }
        }
    }

    /// Set the linear volume (from the volume slider); applies to the live engine immediately.
    /// Quantised to whole-percent steps so the control is a true 0–100 in-1-increments scale.
    func setVolume(_ v: Double) {
        let clamped = (min(1, max(0, v)) * 100).rounded() / 100
        if clamped > 0 { lastNonZeroVolume = clamped }
        volume = clamped
        engine?.volume = Float(clamped)
    }

    /// The current volume as a whole 0–100 percentage (for the readout / stepper).
    var volumePercent: Int { Int((volume * 100).rounded()) }

    /// Nudge the volume by ±1 percent (for tap-to-step fine control).
    func stepVolume(_ delta: Int) { setVolume(Double(volumePercent + delta) / 100) }

    /// Tap-to-mute: drop to 0, or restore the previous level.
    func toggleMute() { setVolume(volume > 0.001 ? 0 : lastNonZeroVolume) }

    /// Change playback speed (0.25…2×). Takes effect immediately on the live engine and, via `makeEngine`,
    /// survives every engine rebuild. Re-evaluates the slow-mute policy for the new rate.
    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        engine?.playbackRate = Float(rate)
        applySlowMute()
        updateSlowMo()
    }

    /// Apply the "mute while slowed" policy to the live engine (mute only below 1×, and only when the
    /// preference is on). Called whenever the rate or the preference changes.
    private func applySlowMute() {
        engine?.slowMute = playbackRate < 1 && muteWhenSlowed
    }

    /// Engage the AI slow-mo interpolation pipeline at ≤0.5× (once the decoded frame size is known), or
    /// disengage above it. Purely additive telemetry today (Phase 1b(A)) — it never alters normal playback,
    /// so if VTFrameProcessor is unavailable or the pipeline can't keep up, playback is unaffected.
    private func updateSlowMo() {
        // Engage only when the user has opted in, at ≤0.5×, AND the item can actually slow-play. The opt-in
        // is required because VTFrameProcessor can hard-crash on some inputs (see `aiSlowMoEnabled`).
        let engage = aiSlowMoEnabled && playbackRate > 0 && playbackRate <= 0.5 && (engine?.canSlowForward ?? false)
        if engage {
            guard slowMoRunner == nil else { return }
            let runner = SlowMoRunner(
                outputProvider: { [weak self] in self?.engine?.frameOutput },
                rateProvider: { [weak self] in self?.playbackRate ?? 0.5 },
                onTelemetry: { [weak self] telemetry in self?.slowMoTelemetry = telemetry }
            )
            slowMoRunner = runner
            slowMoRenderView = runner.renderView
            slowMoTelemetry = SlowMoTelemetry(active: true)
            slowMoActive = true
            runner.start()
        } else if slowMoRunner != nil {
            slowMoRunner?.stop()
            slowMoRunner = nil
            slowMoRenderView = nil
            slowMoActive = false
            slowMoTelemetry = SlowMoTelemetry()
        }
    }

    func seek(to time: TimeInterval) {
        // Seeking suspends AI slow-mo (rate kept) and re-arms a fresh engage once playback stabilises at
        // the target — debounced, so rapid scrubbing collapses into one re-engage after the last seek.
        suspendSlowMo()
        scheduleSlowMoReengage()
        reachedEnd = false   // any seek means we're no longer parked at EOF
        // Mark this (and any re-buffer it triggers) as a warm seek so the loading donut fills on the
        // per-seek estimate/curve. Purely bookkeeping — it does NOT affect the seekTarget hold below that
        // keeps the scrub thumb pinned where the finger released.
        loadIsSeek = true
        // Never seek to the literal end — AVPlayer then waits for a forward buffer that can't exist past
        // EOF and hangs on "waiting to minimize stalls". Land a hair before the end instead.
        let ceiling = duration > 0 ? max(0, duration - 0.3) : time
        let clamped = max(0, min(time, ceiling))
        currentTime = clamped
        seekTarget = clamped                    // hold the scrubber here until the player lands (no pop-back)
        seekHoldUntil = Date().addingTimeInterval(4)
        guard usesAbsoluteTime else {           // direct play / HLS — engine time is absolute
            engine?.seek(to: clamped, precise: seekPrecise)
            return
        }
        // Local linear remux: an in-stream seek only works within what AVPlayer can actually reach right
        // now (its seekable range — which, for a growing EVENT playlist, lags the remux's produced
        // position because AVPlayer re-fetches the playlist only periodically). A target beyond that, or
        // before this stream's start, restarts the remux near the target keyframe (seek-by-reinit) — fast
        // (~one startup) and stays smooth (continuous mux).
        let local = clamped - timeOffset
        let seekEnd = engine?.seekableEnd ?? 0
        let inStream = local >= 0 && local <= seekEnd + 1.0
        RemoteLog.shared.log("seek →\(Int(clamped))s local=\(Int(local)) seekEnd=\(Int(seekEnd)) \(inStream ? "in-stream" : "REINIT")")
        if inStream {
            engine?.seek(to: local, precise: seekPrecise)   // loopback remux is local → frame-accurate
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
        loadingStage = "Seeking…"
        loadingProgress = nil
        videoAspect = nil
        presentationSize = .zero
        do {
            // Rebuild the linear remux seeked to the target keyframe — seek-by-reinit keeps one continuous
            // mux so playback stays smooth.
            let stream: any LocalPlaybackStream = LocalRemuxStream(source: route.url, duration: route.duration, startTime: time)
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
            // The honest "what is actually on screen" gauge — the real decoded frame size, distinct from
            // the source file's metadata below. If a manual quality switch worked, this drops (e.g. to
            // 1280×720); if the server ignored `resolution=`, it stays at the source size.
            StatLine(label: "Playing", value: presentationSize.width > 0
                     ? "\(Int(presentationSize.width))×\(Int(presentationSize.height))"
                     : "—"),
            // The exact URL being played, apikey redacted — so a manual server-quality switch can be
            // verified: the `resolution=…` query param must be present and byte-for-byte one of
            // LOW / STANDARD / STANDARD_HD / FULL_HD / FOUR_K / ORIGINAL (Stash matches it case-sensitively).
            StatLine(label: "URL", value: Self.redactedURL(route.url)),
        ]
        if let lastError { playback.append(StatLine(label: "Error", value: lastError)) }
        sections.append(StatSection(title: "Playback", lines: playback))

        // AI slow-mo (VTFrameProcessor frame interpolation) — opt-in (see aiSlowMoEnabled). Shown whenever
        // enabled so the Stats box reflects state + the decoded-frame diagnostics used to debug crashes.
        let sm = slowMoTelemetry
        if aiSlowMoEnabled || sm.synthesized > 0 {
            sections.append(StatSection(title: "Slow-mo (AI · beta)", lines: [
                StatLine(label: "Interpolation",
                         value: !sm.skipReason.isEmpty ? "Skipped (\(sm.skipReason))"
                              : !sm.supported ? "Unsupported on device"
                              : (sm.active ? "Active" : (playbackRate <= 0.5 ? "Idle (unsupported stream)" : "Idle (≥0.75×)"))),
                StatLine(label: "Engine", value: "VTFrameProcessor (low-latency 2×)"),
                StatLine(label: "Speed", value: PlaybackSpeed.closest(to: playbackRate).label),
                StatLine(label: "Source", value: sm.sourceWidth > 0
                         ? "\(sm.sourceWidth)×\(sm.sourceHeight) \(sm.sourceFormat)" : "—"),
                StatLine(label: "Interp size", value: sm.interpSize.isEmpty ? "—" : sm.interpSize),
                StatLine(label: "Color", value: sm.sourceColor.isEmpty ? "—" : sm.sourceColor),
                StatLine(label: "Source frames", value: "\(sm.sourceFrames)"),
                StatLine(label: "Synthesized frames", value: "\(sm.synthesized)"),
                StatLine(label: "Dropped pairs", value: "\(sm.droppedPairs)"),
                StatLine(label: "Last interp", value: String(format: "%.1f ms", sm.lastMs)),
            ]))
        }

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

    /// The playback cost tier for the badge on the overlay — derived from the route + whether we fell
    /// back. Server (Stash HLS, manual quality, or a fallback) is the costliest; a plain local file is
    /// direct; `.localFFmpeg` is a cheap remux unless its stream type says it's a re-encode (M-A).
    var playbackTier: PlaybackTier {
        if didFallback { return .server }
        switch route.engine {
        case .avPlayer:
            return streamType.localizedCaseInsensitiveContains("hls") ? .server : .direct
        case .localFFmpeg:
            return .remux
        }
    }

    /// A stream URL with any `apikey`/`api_key` value replaced by "…", so the Stats overlay can show
    /// exactly which URL (and its `resolution=` query) is playing without leaking the credential in a
    /// shared screenshot.
    static func redactedURL(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        if var items = comps.queryItems {
            for i in items.indices where items[i].name.lowercased() == "apikey" || items[i].name.lowercased() == "api_key" {
                items[i].value = "…"
            }
            comps.queryItems = items
        }
        return comps.string ?? url.absoluteString
    }
}
