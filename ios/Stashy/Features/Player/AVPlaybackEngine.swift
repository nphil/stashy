import UIKit
import AVFoundation
import CoreVideo

/// A UIView whose backing layer is an `AVPlayerLayer`, so the sharp video renders with no extra
/// compositing. Sized by the zoom surface (already aspect-fitted), so `.resizeAspect` fills it.
final class AVPlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
        }
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

    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onReady: ((Bool) -> Void)?
    var onState: ((PlaybackPhase) -> Void)?
    var onLoadProgress: ((Double) -> Void)?
    var onPresentationSize: ((CGSize) -> Void)?
    var onFailed: ((String?) -> Void)?
    var onEnded: (() -> Void)?
    private var didFail = false
    private var lastPresentation: CGSize = .zero

    var renderView: UIView? { hostView }
    var liveBlurView: UIView? { blurBackdrop }

    init(url: URL) {
        // The playback category is set once at launch (AppDelegate); just claim the session so sound
        // plays through the ringer switch. Activating an already-active session is a cheap no-op, so a
        // reinit creating a new engine no longer re-configures the whole category each time.
        try? AVAudioSession.sharedInstance().setActive(true)

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
        // Cap how far ahead AVPlayer buffers. The on-device HLS loopback answers instantly, so AVPlayer
        // otherwise treats bandwidth as infinite and prefetches the *entire* VOD — driving the segment
        // producer to remux hundreds of segments back-to-back, which pegs the CPU and starves 4K decode
        // (the stutter/lag). 30s keeps a healthy buffer while leaving the producer near the playhead.
        item.preferredForwardBufferDuration = 15
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        // Start muted unless the user is on a private route (headphones/AirPods/Bluetooth), so sound
        // never unexpectedly plays through the phone speaker. The mute button can override this.
        player.isMuted = !Self.privateAudioRouteActive
        hostView.player = player
        blurBackdrop.configure(output: videoOutput)

        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { _ in
            RemoteLog.shared.log("⏸ AVPlayer playback STALLED")
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
                    RemoteLog.shared.log(String(format: "av t=%.0f rate=%.0f keepUp=%@ empty=%@ buf=%.1fs dropped=%d stalls=%d %dx%d",
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
            Task { @MainActor in self?.onState?(phase) }
        }

        // Buffer fill drives the loading donut. loadedTimeRanges changes as data arrives (including while
        // waiting to play, when the periodic time observer doesn't tick), so observe it directly.
        bufferObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.pushLoadProgress() }
        }

        player.play()
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
        player.pause()
        // Detach the render layer + backdrop so an engine swap (far-seek reinit / HLS fallback) doesn't
        // strand the whole previous AVPlayer stack: `AVPlayerLayer.player` is a strong ref (tens of MB with
        // the 15s forward buffer on 4K), and the backdrop's CADisplayLink would keep ticking at 20 Hz. Both
        // removeFromSuperview calls are idempotent no-ops if the view was already swapped out.
        hostView.player = nil
        hostView.removeFromSuperview()
        blurBackdrop.invalidate()
        blurBackdrop.removeFromSuperview()
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

    /// True when audio is routed somewhere private (wired headphones, AirPods / other Bluetooth, USB or
    /// AirPlay) rather than the built-in phone speaker.
    static var privateAudioRouteActive: Bool {
        let privatePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .usbAudio, .airPlay, .carAudio
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { privatePorts.contains($0.portType) }
    }

    func play() { player.play() }
    func pause() { player.pause() }

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
