import SwiftUI

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
    var isReady = false
    /// True while the player is waiting on data (start-up or a rebuffer) — drives the loading donut
    /// instead of a play/pause icon that flickers as the transport state toggles.
    var isBuffering = false
    /// Short, human label for the current load stage (e.g. "Connecting…", "Remuxing on device…").
    var loadingStage = "Connecting…"
    /// Start-up buffer fill (0…1) for the donut; nil = indeterminate (pre-buffer stages).
    var loadingProgress: Double?
    /// Show the loading donut until the first frame is up *and* the player isn't waiting on data.
    var isLoading: Bool { !isReady || isBuffering }
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
    /// After a seek, hold the scrubber at the requested time until the player actually lands there — so
    /// time ticks reporting the pre-seek position don't make the thumb pop back then forward.
    @ObservationIgnored private var seekTarget: TimeInterval?
    /// Safety cap on the seek-hold so a player that stalls just short of the target can't freeze the thumb.
    @ObservationIgnored private var seekHoldUntil = Date.distantPast
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
            loadingStage = route.streamType.localizedCaseInsensitiveContains("hls") ? "Transcoding on server…" : "Loading…"
            adopt(makeEngine(url: route.url), stream: nil)
            // AV1 direct play carries an HLS fallback (its pixel format isn't pre-probed like the remux
            // path). If a 4:2:2/4:4:4/12-bit AV1 renders no frames, fall back rather than sit on black.
            if engine != nil, route.fallbackURL != nil { armWatchdog() }
        case .localFFmpeg:
            beginLocalFFmpeg()
        }
    }

    private func beginLocalFFmpeg() {
        let key = route.url.path
        loadingStage = "Reading video…"
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
            let absolute = self.usesAbsoluteTime ? self.timeOffset + current : current
            self.localStream?.updatePlayhead(current)   // lets the remux pace production to the playhead
            if current > 0 { self.watchdog?.cancel() }   // real frames are flowing — disarm the stall watchdog
            if !self.usesAbsoluteTime, duration > 0, self.duration != duration { self.duration = duration }
            if !self.isReady { self.isReady = true }
            // Hold the scrubber at a just-issued seek target until the player reaches it (no pop-back).
            // Tolerance exceeds AVPlayer's ±1s seek tolerance; the deadline guards a stall short of target.
            if let target = self.seekTarget {
                if abs(absolute - target) < 1.5 || Date() > self.seekHoldUntil { self.seekTarget = nil }
                else { return }
            }
            self.currentTime = absolute
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
            if self.loadingProgress != progress { self.loadingProgress = progress }
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
        loadingStage = "Transcoding on server…"
        loadingProgress = nil
        seekTarget = nil
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
        seekTarget = nil
    }

    func play() { engine?.play() }
    func pause() { engine?.pause() }
    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        // Never seek to the literal end — AVPlayer then waits for a forward buffer that can't exist past
        // EOF and hangs on "waiting to minimize stalls". Land a hair before the end instead.
        let ceiling = duration > 0 ? max(0, duration - 0.3) : time
        let clamped = max(0, min(time, ceiling))
        currentTime = clamped
        seekTarget = clamped                    // hold the scrubber here until the player lands (no pop-back)
        seekHoldUntil = Date().addingTimeInterval(4)
        guard usesAbsoluteTime else {           // direct play / HLS — engine time is absolute
            engine?.seek(to: clamped)
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
        loadingStage = "Seeking…"
        loadingProgress = nil
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
