import UIKit
import AVFoundation
import CoreVideo
import VideoEngine

/// A UIView whose backing layer is an `AVPlayerLayer`, so the sharp video renders with no extra
/// compositing. Sized by the zoom surface (already aspect-fitted), so `.resizeAspect` fills it.
final class AVPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
    }

    /// The "Enhance picture" layer (engine 3.0.0), a sublayer of the player layer so it draws right above the video
    /// and shares this view's frame, zoom and transforms. Nil unless the setting is on.
    private var enhanceLayer: CALayer?
    /// Told the picture area in screen pixels whenever the layout changes (the enhancer sizes its upscale by it).
    var onPixelSize: ((CGSize) -> Void)?

    /// Host `layer` above the video (nil removes the current one). The layer is never re-parented afterwards.
    func hostEnhanceLayer(_ layer: CALayer?) {
        enhanceLayer?.removeFromSuperlayer()
        enhanceLayer = layer
        guard let layer else { return }
        layer.contentsScale = pixelScale
        playerLayer.addSublayer(layer)
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Screen pixels per point; never 0 (an unconfigured trait collection reports 0).
    var pixelScale: CGFloat { max(traitCollection.displayScale, 1) }
    var pixelSize: CGSize { CGSize(width: bounds.width * pixelScale, height: bounds.height * pixelScale) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let enhanceLayer else { return }
        // Same frame as the player layer, with no implicit animation so it never trails the video through a rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        enhanceLayer.frame = bounds
        CATransaction.commit()
        onPixelSize?(pixelSize)
    }
}

/// Native AVPlayer engine, used for HLS streams (Stash transcodes to an Apple-compatible codec, so
/// AVPlayer plays them directly). Because the item exposes decoded frames via `AVPlayerItemVideoOutput`,
/// this engine also vends a live, frame-matched blurred backdrop (`LiveBlurBackdropView`).
@MainActor
final class AVPlaybackEngine: PlaybackEngine {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let hostView = AVPlayerHostView()
    private let videoOutput: AVPlayerItemVideoOutput
    private let blurBackdrop = LiveBlurBackdropView()

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var lastStatLog: CFTimeInterval = 0

    // Debug-only presented-frame counter (Stats overlay decode-fps row). A dedicated video output +
    // display link count how many distinct decoded frames actually reach the screen — `copyPixelBuffer`
    // hands back a *reference* to the already-decoded buffer (IOSurface-backed, no pixel copy), so counting
    // is cheap and doesn't perturb what it measures. Armed only while the overlay is open.
    private var probeOutput: AVPlayerItemVideoOutput?
    private var probeLink: CADisplayLink?
    private var presentedFrames = 0

    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onState: ((PlaybackPhase) -> Void)?
    var onLoadProgress: ((Double) -> Void)?
    var onPresentationSize: ((CGSize) -> Void)?
    var onFailed: ((String?) -> Void)?
    var onEnded: (() -> Void)?
    private var didFail = false
    private var lastPresentation: CGSize = .zero
    /// Whether playback is wanted. The start and `play()` set it and `pause()` clears it; the player's own state
    /// moves it too when something outside the app plays or pauses the player (Picture in Picture, the Lock
    /// Screen), so a pause made there isn't undone when an interruption ends.
    private var wantsPlay = false
    /// An audio interruption (a call, an alarm, another app's audio) took the session and hasn't given it back:
    /// `resumes` when playback was wanted as it began, so its end plays on; `stays` when it wasn't.
    private enum Interruption { case none, resumes, stays }
    private var interruption = Interruption.none
    private var interruptionObservers: [NSObjectProtocol] = []

    var renderView: UIView? { hostView }
    var liveBlurView: UIView? { blurBackdrop }

    /// Second AVPlayerLayer on the SAME player, for the glasses window (Apple's AVLoupe pattern —
    /// multiple layers per player are supported and stay frame-locked). Lazy: costs nothing until a
    /// glasses session asks for it.
    private var externalHostView: AVPlayerHostView?
    var externalRenderView: UIView? {
        if let externalHostView { return externalHostView }
        let v = AVPlayerHostView()
        v.player = player
        externalHostView = v
        return v
    }

    /// The system Picture in Picture window for `hostView`'s layer (nil where the device has none). It lives
    /// and dies with this engine — a rebuilt engine gets a fresh one — and `teardown()` closes it BEFORE the
    /// layer lets go of the player.
    private(set) var pictureInPicture: PictureInPictureWindow?

    // MARK: Enhance picture state (engine 3.0.0)

    /// What the viewer asked for. `.off` (the default) means NO enhancer object and NO layer exist at all.
    var enhanceOptions: EnhanceOptions = .off {
        didSet {
            guard enhanceOptions != oldValue else { return }
            syncEnhancer()
        }
    }
    /// The model's hold: AI slow-mo's overlay or the glasses own the picture, so the enhancer steps aside.
    var enhanceHeld = false {
        didSet {
            guard enhanceHeld != oldValue else { return }
            updateEnhanceActive()
        }
    }
    private var enhancer: PictureEnhancer?
    private var enhanceStateTask: Task<Void, Never>?
    private var enhanceObservers: [NSObjectProtocol] = []
    /// Last value handed to `setActive` (the enhancer starts active).
    private var enhanceActive = true
    private var itemReady = false
    private var appInBackground = false
    private var pipOpen = false

    init(url: URL, normalizationGain: Float = 1) {
        self.normalizationGain = normalizationGain
        // Claim the session so sound plays through the ringer switch. The category is re-asserted
        // rather than trusted: `DownloadKeepAlive` leaves the session mixing (`.mixWithOthers`, mode
        // `.default`) so a background download can't silence the owner's music, and it deliberately
        // doesn't restore it — changing the category of an already-active session interrupts other
        // apps, so the right moment is here, when the user has actually pressed play. Setting a
        // category is cheap and idempotent; activating an already-active session is a no-op.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Self.activateAudioSession()

        // Inject the Stash apikey as an HTTP header so HLS segment requests — which can drop the query
        // param when AVPlayer resolves relative segment URLs — still authenticate (otherwise HLS plays
        // audio/black or errors on auth, not on rendering).
        var assetOptions: [String: Any] = [:]
        if let apiKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "apikey" })?.value {
            assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = ["ApiKey": apiKey]
        }
        item = AVPlayerItem(asset: AVURLAsset(url: url, options: assetOptions))
        videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(videoOutput)
        // Pitch-correct audio when the playback speed isn't 1× (so 1.5×/0.75× keep natural pitch instead
        // of chipmunking). Time-domain is the low-CPU choice that sounds clean for speech-heavy content.
        item.audioTimePitchAlgorithm = .timeDomain
        // Cap how far ahead AVPlayer buffers. The on-device HLS loopback answers instantly, so AVPlayer
        // otherwise treats bandwidth as infinite and prefetches the *entire* VOD — driving the segment
        // producer to remux hundreds of segments back-to-back, which pegs the CPU and starves 4K decode
        // (the stutter/lag). 30s keeps a healthy buffer while leaving the producer near the playhead.
        item.preferredForwardBufferDuration = 15
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        // Always start silent (volume 0), regardless of audio route — the owner wants every video to
        // begin muted. `isMuted` stays false so that when the volume control raises `volume`, sound
        // actually comes through (a muted player would ignore the volume).
        player.volume = 0
        player.isMuted = false
        hostView.player = player
        pictureInPicture = PictureInPictureWindow(layer: hostView.playerLayer)
        pictureInPicture?.onActiveChange = { [weak self] open in
            guard let self else { return }
            self.pipOpen = open
            self.updateEnhanceActive()
        }
        blurBackdrop.configure(output: videoOutput)

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            RemoteLog.shared.log("⏸ AVPlayer playback STALLED")
            MainActor.assumeIsolated {
                self?.logStallSnapshot("stalled")
                // And once more if it is still waiting 5 s on: what the player holds when the app's net restarts it.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(4500))
                    guard let self, self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
                    self.logStallSnapshot("wait5")
                }
            }
        }

        // Playback reached the end — the player stays parked at the end (actionAtItemEnd = .pause), so
        // the facade knows a subsequent play() must restart from the beginning.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }

        // ~10 Hz so the scrubber/time label rebuild a handful of times a second, not per frame.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let duration = self.item.duration.seconds
                self.onTime?(time.seconds, duration.isFinite ? duration : 0)
                let presentation = self.item.presentationSize
                if presentation.width > 0, presentation != self.lastPresentation {
                    self.lastPresentation = presentation
                    self.onPresentationSize?(presentation)
                }
                // Throttled decode telemetry (~every 2s): distinguishes dropped frames (decode/GPU
                // bottleneck) from stalls (buffer) from healthy playback, when diagnosing choppiness.
                let now = CACurrentMediaTime()
                if now - self.lastStatLog >= 2 {
                    self.lastStatLog = now
                    let ev = self.item.accessLog()?.events.last
                    let nowT = self.player.currentTime().seconds
                    let ahead = self.item.loadedTimeRanges.compactMap { range -> Double? in
                        let r = range.timeRangeValue
                        let s = r.start.seconds, e = (r.start + r.duration).seconds
                        return (nowT >= s && nowT <= e) ? e - nowT : nil
                    }.max() ?? 0
                    let w = Int(presentation.width), h = Int(presentation.height)
                    RemoteLog.shared.log(String(format: "av t=%.0f rate=%.2f keepUp=%@ empty=%@ buf=%.1fs dropped=%d stalls=%d %dx%d",
                        nowT.isFinite ? nowT : -1, self.player.rate,
                        self.item.isPlaybackLikelyToKeepUp ? "Y" : "N",
                        self.item.isPlaybackBufferEmpty ? "Y" : "N",
                        ahead,
                        ev?.numberOfDroppedVideoFrames ?? -1,
                        ev?.numberOfStalls ?? -1, w, h))
                }
            }
        }

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let ready = item.status == .readyToPlay
            let failed = item.status == .failed
            let errorText = item.error?.localizedDescription
            Task { @MainActor in
                self?.attachEnhancerIfReady(ready)
                guard let self else { return }
                self.onReady?(ready)
                if failed, !self.didFail {
                    self.didFail = true
                    self.onFailed?(errorText)
                }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let phase: PlaybackPhase
            switch player.timeControlStatus {
            case .paused: phase = .paused
            case .waitingToPlayAtSpecifiedRate: phase = .waiting
            case .playing: phase = .playing
            @unknown default: phase = .paused
            }
            Task { @MainActor in
                self?.followPlayerState()
                self?.onState?(phase)
            }
        }

        // Buffer fill drives the loading donut. loadedTimeRanges changes as data arrives (including while
        // waiting to play, when the periodic time observer doesn't tick), so observe it directly.
        bufferObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.pushLoadProgress() }
        }

        observeInterruptions()
        wantsPlay = true
        player.play()
    }

    /// Claim the session without stalling the main thread: activation waits while the system settles audio with
    /// other apps (a call, music), and iOS 27 warns about doing that on the main thread. Nothing waits for it:
    /// the player starts muted, and a claim that fails is as ignored as the synchronous one was.
    private nonisolated static func activateAudioSession() {
        if #available(iOS 27.0, *) {
            AVAudioSession.sharedInstance().activate { _, _ in }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { try? AVAudioSession.sharedInstance().setActive(true) }
        }
    }

    /// Deterministic teardown, called from the facade when leaving the scene. Removing the periodic time
    /// observer is mandatory — AVPlayer traps ("deallocated while a periodic time observer was
    /// registered") if released with one still attached, a crash that accumulates as scenes are opened
    /// and closed. (A nonisolated `deinit` can't touch these MainActor/non-Sendable members under strict
    /// concurrency, so cleanup happens here instead.)
    func teardown() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObservation?.invalidate(); statusObservation = nil
        timeControlObservation?.invalidate(); timeControlObservation = nil
        bufferObservation?.invalidate(); bufferObservation = nil
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver); self.stallObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        for observer in interruptionObservers { NotificationCenter.default.removeObserver(observer) }
        interruptionObservers = []
        wantsPlay = false
        interruption = .none
        setFrameRateProbeActive(false)
        dropEnhancer()
        player.pause()
        // Close the Picture in Picture window while the layer still has its player (it holds the layer), and
        // stop it reporting.
        pictureInPicture?.tearDown()
        pictureInPicture = nil
        // Detach the render layer + backdrop so an engine swap (far-seek reinit / HLS fallback) doesn't
        // strand the whole previous AVPlayer stack: `AVPlayerLayer.player` is a strong ref (tens of MB with
        // the 15s forward buffer on 4K), and the backdrop's CADisplayLink would keep ticking at 20 Hz. Both
        // removeFromSuperview calls are idempotent no-ops if the view was already swapped out.
        hostView.player = nil
        hostView.removeFromSuperview()
        externalHostView?.player = nil   // AVPlayerLayer.player is a strong ref — same as hostView above
        externalHostView?.removeFromSuperview()
        externalHostView = nil
        blurBackdrop.invalidate()
        blurBackdrop.removeFromSuperview()
        // The LAST release of an AVPlayer tears its whole media pipeline down on the releasing thread — here the main
        // thread, right as the user closes the player and flicks the grid. Everything above is already detached, so
        // keep the stack alive a beat and let it go off the main thread.
        PlayerGraveyard.bury([player, item, videoOutput])
    }

    /// Compute the start-up buffer fill (0…1) and push it for the loading donut.
    private func pushLoadProgress() {
        if item.isPlaybackLikelyToKeepUp { onLoadProgress?(1); return }
        let now = player.currentTime().seconds
        let n = now.isFinite ? now : 0
        let ahead = item.loadedTimeRanges.compactMap { value -> Double? in
            let r = value.timeRangeValue
            let s = r.start.seconds, e = (r.start + r.duration).seconds
            return (n >= s - 0.5 && n <= e) ? e - n : nil
        }.max() ?? 0
        onLoadProgress?(min(1, max(0, ahead / 3.0)))   // ~3s buffered feels "ready to start"
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    // The user's chosen level and the slow-mute flag are kept separately from the player's applied
    // `volume`, so toggling one never clobbers the other; `applyOutputVolume()` combines them.
    private var storedVolume: Float = 0
    private var slowMuted = false
    /// Per-scene loudness-normalization gain (0…1, attenuation-only) folded into the output volume so it
    /// composes with the user's slider instead of clobbering it. 1 = no normalization (no served data).
    private let normalizationGain: Float

    var volume: Float {
        get { storedVolume }
        set { storedVolume = newValue; if newValue > 0 { player.isMuted = false }; applyOutputVolume() }
    }

    var slowMute: Bool {
        get { slowMuted }
        set { slowMuted = newValue; applyOutputVolume() }
    }

    private func applyOutputVolume() { player.volume = slowMuted ? 0 : storedVolume * normalizationGain }

    /// The live decoded-frame output (shared with the blur) for the slow-mo frame interpolator.
    var frameOutput: AVPlayerItemVideoOutput? { videoOutput }

    private var desiredRate: Float = 1
    var playbackRate: Float {
        get { desiredRate }
        set {
            desiredRate = newValue
            // The current item may not support the requested rate: a growing/live **loopback-remux HLS**
            // stream reports `canPlayFastForward`/`canPlaySlowForward == false`, and applying an unsupported
            // rate is ignored at best and *raises* at worst (the remux-path crash: >1× did nothing, <1×
            // crashed). Clamp to a rate the item can actually honor.
            let effective = supportedRate(newValue)
            // With `automaticallyWaitsToMinimizeStalling` on, `play()` sets the live rate to `defaultRate`
            // (setting `rate` directly is discouraged / logs). Publish via defaultRate, then re-invoke
            // play() to apply it live — but only if already playing, so changing speed while paused doesn't
            // force playback to start.
            player.defaultRate = effective
            if player.timeControlStatus != .paused { player.play() }
        }
    }

    /// The requested rate if the current item can honor it, else 1.0. A live/loopback HLS stream can't
    /// fast- or slow-forward, so applying such a rate there is unsafe.
    private func supportedRate(_ rate: Float) -> Float {
        guard let item = player.currentItem else { return 1 }
        if rate > 1 { return item.canPlayFastForward ? rate : 1 }
        if rate < 1 { return item.canPlaySlowForward ? rate : 1 }
        return 1
    }

    /// Whether the current item supports slow-forward playback (false for a live/loopback HLS stream). The
    /// player model uses this to avoid engaging slow-mo interpolation where slow playback isn't possible.
    var canSlowForward: Bool { player.currentItem?.canPlaySlowForward ?? false }

    /// True when audio is routed somewhere private (wired headphones, AirPods / other Bluetooth, USB or
    /// AirPlay) rather than the built-in phone speaker.
    static var privateAudioRouteActive: Bool {
        let privatePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio, .airPlay, .carAudio
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { privatePorts.contains($0.portType) }
    }

    func play() { wantsPlay = true; interruption = .none; player.play() }
    func pause() { wantsPlay = false; interruption = .none; player.pause() }

    // MARK: - Audio interruptions

    /// When a call, an alarm or another app's audio takes the session the system pauses the player, and when it
    /// gives the session back the app decides what happens next. So an interruption's pause ends with playback
    /// resuming if it was wanted, including a start that was still loading when the interruption came. iOS 27
    /// reports this as the session going inactive and, later, a recommendation to resume, and deprecates the
    /// begin/end notification of earlier releases, so both are watched; they feed one state that is safe to
    /// hear twice.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        interruptionObservers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    .flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
                guard let type else { return }
                let began = type == .began
                let shouldResume = options.contains(.shouldResume)
                MainActor.assumeIsolated { self?.interrupted(began: began, shouldResume: shouldResume) }
            }
        ]
        if #available(iOS 27.0, *) {
            interruptionObservers.append(center.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
                guard context?.source == .system else { return }
                MainActor.assumeIsolated { self?.interrupted(began: true, shouldResume: false) }
            })
            interruptionObservers.append(center.addObserver(
                forName: AVAudioSession.resumptionRecommendationNotification, object: nil, queue: .main) { [weak self] note in
                let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext
                guard let recommendation = context?.recommendation else { return }
                let shouldResume = recommendation == .shouldResume
                MainActor.assumeIsolated { self?.resumptionRecommended(shouldResume) }
            })
        }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        RemoteLog.shared.log("audio interruption \(began ? "began" : "ended") (resume \(shouldResume), wanted \(wantsPlay))")
        if began {
            // The wish to play is what counts, not the player's state: a stream still loading, or one AVPlayer
            // paused before the news reached us, plays on all the same.
            if interruption != .resumes { interruption = wantsPlay ? .resumes : .stays }
        } else {
            let resumes = interruption == .resumes
            interruption = .none
            if shouldResume, resumes { play() }
        }
    }

    /// iOS 27: the system says whether to carry on, after an interruption or after refusing a start that came
    /// while a call was under way. No interruption was seen in the second case, so a player that is paused
    /// while playback is wanted resumes as well.
    private func resumptionRecommended(_ shouldResume: Bool) {
        RemoteLog.shared.log("audio resumption recommended: \(shouldResume) (wanted \(wantsPlay))")
        let resumes = interruption == .resumes || (wantsPlay && player.timeControlStatus == .paused)
        interruption = .none
        if shouldResume, resumes { play() }
    }

    /// The player's own state tells a pause from outside apart from an interruption's: one that arrives with
    /// no interruption under way came from Picture in Picture, the Lock Screen or pulled headphones, and is
    /// kept. A play from outside is kept too.
    private func followPlayerState() {
        switch player.timeControlStatus {
        case .paused: if interruption == .none { wantsPlay = false }
        case .waitingToPlayAtSpecifiedRate, .playing: wantsPlay = true
        @unknown default: break
        }
        updateEnhanceActive()
    }

    func seek(to time: TimeInterval, precise: Bool) {
        // Precise = zero tolerance → the player lands on the exact frame the scrub sprite previewed,
        // instead of snapping up to ±1s to the nearest keyframe. The caller only asks for precise on
        // local media (direct file / on-device loopback remux), where a frame-exact seek is near-instant.
        // For a Stash *server* HLS transcode it passes precise=false: a zero-tolerance seek there stalls
        // while the server renders the exact frame, so the 1s tolerance keeps scrubbing responsive.
        let tolerance = precise ? .zero : CMTime(seconds: 1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    // MARK: - Decode-health probe (debug Stats overlay)

    /// Cumulative decoded frames the player has thrown away (arrived too late to display), summed across
    /// the access log's events. A steadily-climbing value under 1× = the device is compute-bound.
    var droppedFrameCount: Int {
        (item.accessLog()?.events ?? []).reduce(0) { $0 + max(0, Int($1.numberOfDroppedVideoFrames)) }
    }

    /// Cumulative frames actually presented to the screen since the probe was armed (0 when disarmed).
    var presentedFrameCount: Int { presentedFrames }

    /// Arm/disarm the presented-frame counter. Called by the model when the Stats overlay opens/closes, so
    /// there's no extra output or display link running when the overlay is shut.
    func setFrameRateProbeActive(_ active: Bool) {
        if active {
            guard probeOutput == nil else { return }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            probeOutput = output
            presentedFrames = 0
            let proxy = FrameProbeLinkProxy(target: self)
            let link = CADisplayLink(target: proxy, selector: #selector(FrameProbeLinkProxy.tick))
            proxy.link = link
            // 60 Hz polling counts every distinct frame of ≤60fps content at half the main-thread wakeups
            // of the default cadence — the probe is part of the debug overlay, so it must stay featherweight.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            probeLink = link
        } else {
            probeLink?.invalidate(); probeLink = nil
            if let probeOutput { item.remove(probeOutput) }
            probeOutput = nil
        }
    }

    /// One display-link tick: if a new decoded frame is available, consume its (reference-only) buffer to
    /// advance the output and tally it. The count/elapsed is the presented frame rate.
    fileprivate func probeTick() {
        guard let probeOutput else { return }
        let t = probeOutput.itemTime(forHostTime: CACurrentMediaTime())
        if probeOutput.hasNewPixelBuffer(forItemTime: t) {
            _ = probeOutput.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
            presentedFrames &+= 1
        }
    }

    // MARK: - Enhance picture (engine 3.0.0, opt-in, device-unverified)

    /// Create, update or destroy the enhancer to match `enhanceOptions`. Off = nothing exists.
    private func syncEnhancer() {
        guard enhanceOptions.isEnabled else { dropEnhancer(); return }
        if let enhancer { enhancer.options = enhanceOptions; return }
        let made = PictureEnhancer(options: enhanceOptions, logger: .remoteLog)
        made.layer.videoGravity = .resizeAspect
        enhancer = made
        enhanceActive = true
        appInBackground = UIApplication.shared.applicationState == .background
        pipOpen = pictureInPicture?.isActive ?? false
        hostView.hostEnhanceLayer(made.layer)
        made.displaySize = hostView.pixelSize
        hostView.onPixelSize = { [weak made] size in made?.displaySize = size }
        let center = NotificationCenter.default
        enhanceObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appInBackground = true; self?.updateEnhanceActive() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appInBackground = false; self?.updateEnhanceActive() }
            },
        ]
        let stream = made.updates()
        enhanceStateTask = Task { @MainActor [weak self] in
            for await state in stream { self?.enhanceStateChanged(state) }
        }
        if itemReady { made.attach(to: item) }
        updateEnhanceActive()
    }

    /// Attach once the player item is ready (and every time the setting later creates an enhancer).
    /// What AVPlayer holds at a stall, for the engine's loopback log to be read against (VideoEngine 3.0.2):
    /// none of its `loop-req` lines after the last refill means the player stopped asking.
    private func logStallSnapshot(_ why: String) {
        func whole(_ time: CMTime) -> Int {
            let seconds = time.seconds
            return seconds.isFinite && abs(seconds) < 1_000_000 ? Int(seconds) : -1
        }
        let loaded = item.loadedTimeRanges.map { value -> String in
            let range = value.timeRangeValue
            return "\(whole(range.start))-\(whole(CMTimeRangeGetEnd(range)))"
        }.joined(separator: ",")
        let access = item.accessLog()?.events.last
        let failure = item.errorLog()?.events.last
        RemoteLog.shared.event("player-stall", [
            ("why", why), ("at", whole(player.currentTime())), ("loaded", loaded),
            ("full", item.isPlaybackBufferFull ? 1 : 0), ("empty", item.isPlaybackBufferEmpty ? 1 : 0),
            ("keepUp", item.isPlaybackLikelyToKeepUp ? 1 : 0),
            ("status", player.timeControlStatus.rawValue),
            ("reason", player.reasonForWaitingToPlay?.rawValue),
            ("outputs", item.outputs.count),
            ("requests", access?.numberOfMediaRequests), ("stalls", access?.numberOfStalls),
            ("bytes", access?.numberOfBytesTransferred),
            ("err", failure.map { "\($0.errorStatusCode) \($0.errorDomain) \($0.errorComment ?? "")" }),
        ])
    }

    private func attachEnhancerIfReady(_ ready: Bool) {
        itemReady = ready
        if ready, let enhancer { enhancer.attach(to: item) }
    }

    /// Detach before release (the engine's rule), take the layer off the player layer, forget everything.
    private func dropEnhancer() {
        enhanceStateTask?.cancel(); enhanceStateTask = nil
        for observer in enhanceObservers { NotificationCenter.default.removeObserver(observer) }
        enhanceObservers = []
        hostView.onPixelSize = nil
        hostView.hostEnhanceLayer(nil)
        enhancer?.detach()
        enhancer = nil
        enhanceActive = true
    }

    /// The enhancer works only while the plain player is playing in the foreground in this app's own window and nobody
    /// else owns the picture: it stops on pause, in the background, while Picture in Picture is open (the window
    /// stays on the plain AVPlayerLayer) and while the model holds it (AI slow-mo overlay, glasses).
    private func updateEnhanceActive() {
        guard let enhancer else { return }
        let paused = player.timeControlStatus == .paused
        let run = !paused && !appInBackground && !pipOpen && !enhanceHeld
        guard run != enhanceActive else { return }
        enhanceActive = run
        enhancer.setActive(run)
        RemoteLog.shared.event("enhance-probe", [
            ("by", "app"), ("active", run ? 1 : 0), ("paused", paused ? 1 : 0), ("background", appInBackground ? 1 : 0),
            ("pip", pipOpen ? 1 : 0), ("held", enhanceHeld ? 1 : 0),
        ])
    }

    /// One line per state change (the engine already de-duplicates), never per frame. The engine's own `enhance-probe`
    /// (per scaler), `enhance-plan`, `enhance-demote/pause/resume` and `enhance-perf` (every 120 frames) arrive through
    /// the same log.
    private func enhanceStateChanged(_ state: EnhanceState) {
        RemoteLog.shared.event("enhance-probe", [("by", "app"), ("state", Self.describe(state))])
    }

    /// "Running · scaler 1280x720 → 1920x1080 · sharpen 0.30 · deband 0.20", "Paused (powerSaving)", …
    private static func describe(_ state: EnhanceState) -> String {
        switch state {
        case .idle: return "Idle"
        case .running(let plan):
            let scaler = plan.upscaler?.rawValue ?? "no scaler"
            return String(format: "Running · %@ %dx%d → %dx%d · sharpen %.2f · deband %.2f", scaler,
                          plan.sourceWidth, plan.sourceHeight, plan.outputWidth, plan.outputHeight,
                          plan.sharpen, plan.deband)
        case .paused(let reason): return "Paused (\(reason.rawValue))"
        case .unavailable(let reason): return "Unavailable (\(reason.rawValue))"
        }
    }

    /// The Stats overlay's "Enhance" row: the chain's state and plan, plus why the app has it standing aside.
    var enhanceSummary: String {
        guard let enhancer else { return "Off" }
        var text = Self.describe(enhancer.state)
        if !enhanceActive {
            var why: [String] = []
            if player.timeControlStatus == .paused { why.append("paused") }
            if appInBackground { why.append("background") }
            if pipOpen { why.append("picture in picture") }
            if enhanceHeld { why.append("slow-mo / glasses") }
            text += " · stopped: " + why.joined(separator: ", ")
        }
        return text
    }

    // MARK: - Stats

    var seekableEnd: TimeInterval {
        var maxEnd = 0.0
        for value in item.seekableTimeRanges {
            let r = value.timeRangeValue
            let end = (r.start + r.duration).seconds
            if end.isFinite, end > maxEnd { maxEnd = end }
        }
        return maxEnd
    }

    // AVPlayer plays only VideoToolbox-decodable formats (H.264/HEVC), so decode is always hardware.
    var decodeDescription: String { "Hardware (VideoToolbox)" }

    func liveStats() -> [StatLine] {
        var lines: [StatLine] = []

        // Playback state / why it's waiting (buffering, etc.).
        switch player.timeControlStatus {
        case .paused: lines.append(StatLine(label: "State", value: "Paused"))
        case .waitingToPlayAtSpecifiedRate:
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "waiting"
            lines.append(StatLine(label: "State", value: "Waiting (\(reason))"))
        case .playing: lines.append(StatLine(label: "State", value: "Playing"))
        @unknown default: lines.append(StatLine(label: "State", value: "—"))
        }

        // Buffer ahead of the playhead.
        let now = player.currentTime().seconds
        if let ahead = item.loadedTimeRanges.compactMap({ range -> Double? in
            let r = range.timeRangeValue
            let start = r.start.seconds, end = (r.start + r.duration).seconds
            return (now >= start && now <= end) ? end - now : nil
        }).max() {
            lines.append(StatLine(label: "Buffer ahead", value: String(format: "%.1f s", ahead)))
        }

        let presentation = item.presentationSize
        if presentation.width > 0 {
            lines.append(StatLine(label: "Decoded size",
                                  value: "\(Int(presentation.width))×\(Int(presentation.height))"))
        }

        // Network access log (most recent event).
        if let event = item.accessLog()?.events.last {
            if event.observedBitrate > 0 {
                lines.append(StatLine(label: "Throughput", value: Self.mbps(event.observedBitrate)))
            }
            if event.indicatedBitrate > 0 {
                lines.append(StatLine(label: "Stream bitrate", value: Self.mbps(event.indicatedBitrate)))
            }
            if event.numberOfBytesTransferred > 0 {
                lines.append(StatLine(label: "Transferred",
                                      value: ByteCountFormatter.string(fromByteCount: event.numberOfBytesTransferred, countStyle: .file)))
            }
            if event.numberOfStalls >= 0 {
                lines.append(StatLine(label: "Stalls", value: "\(event.numberOfStalls)"))
            }
            if event.numberOfDroppedVideoFrames >= 0 {
                lines.append(StatLine(label: "Dropped frames", value: "\(event.numberOfDroppedVideoFrames)"))
            }
            if !event.playbackType.isNilOrEmpty {
                lines.append(StatLine(label: "Playback type", value: event.playbackType ?? "—"))
            }
            if let server = event.serverAddress, !server.isEmpty {
                lines.append(StatLine(label: "Server", value: server))
            }
        } else {
            lines.append(StatLine(label: "Network", value: "no access log yet"))
        }

        return lines
    }

    private static func mbps(_ bitsPerSecond: Double) -> String {
        String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

/// Weak-target proxy for the frame-rate probe's `CADisplayLink` (the run loop retains the link, and the
/// link retains its target — targeting the engine directly would leak it).
private final class FrameProbeLinkProxy: NSObject {
    weak var target: AVPlaybackEngine?
    var link: CADisplayLink?
    init(target: AVPlaybackEngine) { self.target = target; super.init() }
    @objc func tick() {
        guard let target else { link?.invalidate(); link = nil; return }
        MainActor.assumeIsolated { target.probeTick() }
    }
}

/// Lets go of an engine's `AVPlayer` stack off the main thread.
///
/// Dropping the last reference to an `AVPlayer` / `AVPlayerItem` tears down its media pipeline synchronously on the
/// releasing thread — main-thread milliseconds at exactly the moment a closed player hands the screen back to a
/// scrolling grid. The engine detaches everything first (observers, layer, views), then buries the objects here; the
/// final release runs on a utility queue half a second later, by which time the engine's own release (on the main
/// thread, right after `teardown()`) has certainly happened, so ours is the last.
private enum PlayerGraveyard {
    private final class Plot: @unchecked Sendable {
        var objects: [AnyObject]
        init(_ objects: [AnyObject]) { self.objects = objects }
    }

    static func bury(_ objects: [AnyObject]) {
        let plot = Plot(objects)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            plot.objects.removeAll()
        }
    }
}
