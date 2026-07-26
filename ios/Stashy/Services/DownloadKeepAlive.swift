import AVFoundation
import UIKit

/// Keeps the process scheduled while a download is in flight, so an in-process transfer can keep
/// writing long after the app is backgrounded.
///
/// WHY THIS EXISTS — and what it corrects. Stashy measured iOS's plain background grace at 25.57 s and
/// 26.32 s and concluded that no API lifts it. That conclusion was wrong in one specific way: a
/// `beginBackgroundTask` assertion cannot be *extended*, but an app that declares the `audio`
/// background mode and holds an ACTIVE audio session can end its assertion and be granted a fresh one,
/// over and over. XITRIX/iTorrent — sideloaded, and whose entitlements file contains not a single
/// `com.apple.developer.*` key — ships exactly this and downloads for hours. `UIBackgroundModes` is a
/// plist declaration policed at App Store review, NOT a signed capability, which is the structural
/// reason it is worth trying where the -3000 daemon hand-over and `BGContinuedProcessingTask` were
/// not: both of those are OS-service handshakes that can decline an app they cannot vouch for.
///
/// THE SHAPE MATTERS. iTorrent shipped the naive version first — one infinite silent loop, no
/// assertion at all — then spent three rounds of commits literally titled "Background fixes"
/// converging on this pump: play → END the old assertion → take a FRESH one → stop the audio →
/// sleep 10 s → repeat, with the expiration handler re-entering the loop rather than surrendering.
/// Copy the hybrid, not the ancestor. Ending before re-taking is the whole trick: iOS's window is
/// per-APP, not per-assertion, so the clock only resets when nothing is outstanding — which is also
/// why `DownloadManager.holdTransferAssertion` stands down while this runs.
///
/// NOT PROVEN ON THIS DEVICE. Nobody has run the technique on an iPhone 17 Pro / iOS 26; the evidence
/// is source-only, and Apple has never documented that an active session grants runtime, so a point
/// release can regress it silently. It therefore ships OFF, behind Settings → Diagnostics, and with
/// the toggle off the app behaves byte-identically to before. The proof is in the trace: `dl-keepalive
/// tick=` lines continuing past ~30 s with `dl-parts` still growing.
@MainActor
final class DownloadKeepAlive {
    static let shared = DownloadKeepAlive()
    private init() {}

    /// Shared with the `@AppStorage` toggle in Settings → Diagnostics. `nonisolated` because a SwiftUI
    /// `View`'s stored-property initialisers are not main-actor isolated, and everything inside a
    /// `@MainActor` type otherwise inherits that isolation.
    nonisolated static let settingKey = "audioKeepAliveEnabled"

    /// Opt-in. Off is byte-identical to the pre-keep-alive app: nothing below ever runs.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// True while the pump owns the app's background window. `DownloadManager` reads this so it never
    /// holds a second assertion — one outstanding elsewhere pins the window open and defeats renewal.
    private(set) var isRunning = false

    private var player: AVAudioPlayer?
    private var pump: Task<Void, Never>?
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    /// Guards against an expired handler for an OLD assertion clearing a newer, still-valid one.
    private var assertionGeneration = 0
    private var interruption: NSObjectProtocol?
    private var stillNeeded: (@MainActor () -> Bool)?
    private var ticks = 0
    private var refusals = 0
    private var startedAt = Date()

    // MARK: - Lifecycle

    /// Start pumping, for as long as `needed()` keeps returning true. The predicate is re-evaluated at
    /// the top of every 10 s cycle, so a transfer that finishes while we're backgrounded tears the
    /// whole thing down on its own — no caller has to watch for it.
    func start(while needed: @escaping @MainActor () -> Bool) {
        guard Self.isEnabled, !isRunning, needed() else { return }
        guard let url = Self.toneURL() else {
            RemoteLog.shared.event("dl-keepalive", [("start", "no-asset")])
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers` so a background download never silences the owner's music. Restoring it
            // is conditional and deliberate — see `stop(restoringCategory:)`.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = 0.01
            p.numberOfLoops = -1
            p.prepareToPlay()
            player = p
        } catch {
            RemoteLog.shared.event("dl-keepalive", [("start", "session-fail"),
                                                    ("err", error.localizedDescription)])
            player = nil
            return
        }
        stillNeeded = needed
        isRunning = true
        ticks = 0
        refusals = 0
        startedAt = Date()
        observeInterruptions()
        RemoteLog.shared.event("dl-keepalive", [("start", 1)])
        pump = Task { await self.run() }
    }

    /// - Parameter restoringCategory: put the shared session back to the app's launch configuration
    ///   (`.playback` / `.moviePlayback`, non-mixing). Only the foreground return passes true.
    ///
    ///   Both answers here are wrong in some case, so the choice is which harm is narrower. Always
    ///   restoring interrupts whatever the owner is listening to every time they open Stashy after a
    ///   background download — dropping `.mixWithOthers` on an ALREADY-ACTIVE session takes the session
    ///   outright. Never restoring leaves a player that outlived the background trip mixing for the rest
    ///   of the scene, because `ScenePlayerModel.start()` early-returns on `guard engine == nil` and so
    ///   `AVPlaybackEngine.init`'s assertion never runs again for it.
    ///
    ///   So: restore unless someone else is actually playing. When nothing else holds the session the
    ///   restore is inaudible and fixes the stale-player case; when another app IS playing we leave it
    ///   mixing, and the worst outcome is hearing both until the next scene rebuilds the engine — which
    ///   is strictly better than silencing their music.
    func stop(restoringCategory: Bool = false) {
        guard isRunning || pump != nil else { return }
        let ran = Int(Date().timeIntervalSince(startedAt))
        isRunning = false
        pump?.cancel()
        pump = nil
        stillNeeded = nil
        player?.stop()
        player = nil
        endAssertion()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        let session = AVAudioSession.sharedInstance()
        var restored = false
        if restoringCategory, !session.isOtherAudioPlaying {
            try? session.setCategory(.playback, mode: .moviePlayback)
            restored = true
        }
        RemoteLog.shared.event("dl-keepalive", [("stop", 1), ("ticks", ticks), ("up", ran),
                                                ("restored", restored ? 1 : 0)])
        RemoteLog.shared.flushNow()
    }

    // MARK: - The pump

    private func run() async {
        while !Task.isCancelled {
            guard isRunning, stillNeeded?() == true else { stop(); return }
            // Give the audio unit a real (if inaudible) render window before swapping assertions —
            // iTorrent pulses play/stop back-to-back, and a few frames of actual output can only help
            // whatever iOS is checking.
            player?.play()
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, isRunning else { return }
            endAssertion()
            beginAssertion()
            player?.pause()
            if assertion == .invalid {
                // iOS refused a fresh window. Retry rather than sleeping straight into suspension, but
                // don't spin: three refusals in a row means the technique isn't working here.
                refusals += 1
                RemoteLog.shared.event("dl-keepalive", [("refused", refusals)])
                guard refusals < 3 else { RemoteLog.shared.flushNow(); stop(); return }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            refusals = 0
            ticks += 1
            if RemoteLog.isDownloadTracingEnabled {
                RemoteLog.shared.event("dl-keepalive", [
                    ("tick", ticks), ("up", Int(Date().timeIntervalSince(startedAt)))])
                // Push the buffer off-device every ~30 s: if iOS jetsams us mid-run the trace is the
                // only record of how far the pump got.
                if ticks % 3 == 0 { RemoteLog.shared.flushNow() }
            }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
        }
    }

    private func beginAssertion() {
        assertionGeneration += 1
        let gen = assertionGeneration
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "stashy-keepalive") { [weak self] in
            // Must end SYNCHRONOUSLY or iOS kills the app. Clearing our record happens on a hop, and
            // only if this is still the CURRENT assertion — otherwise a late handler for a retired one
            // would blank a perfectly good identifier and make the next `endAssertion` a no-op.
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
            RemoteLog.shared.event("dl-keepalive", [("expired", gen)])
            Task { @MainActor in
                guard let self, self.assertionGeneration == gen else { return }
                self.assertion = .invalid
            }
        }
        assertion = bg
    }

    private func endAssertion() {
        guard assertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(assertion)
        assertion = .invalid
    }

    // MARK: - Interruptions

    private func observeInterruptions() {
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recoverFromInterruption() }
        }
    }

    /// A phone call or another app taking the session deactivates ours and stops the player; iOS does
    /// not hand it back on its own, and the pump would keep renewing an assertion with no audio behind
    /// it until the window closed for good. Rather than decode the notification payload (reading
    /// `Notification.userInfo` from a `@Sendable` handler is awkward under strict concurrency), just
    /// try to re-claim on ANY interruption event: the attempt throws harmlessly during the `.began`
    /// half and succeeds on `.ended`. iTorrent needed this too ("Fix background service
    /// interruptions", 2026-07-18) — it is not a hypothetical.
    private func recoverFromInterruption() {
        guard isRunning else { return }
        let ok = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
        if ok, player?.isPlaying == false { player?.play() }
        RemoteLog.shared.event("dl-keepalive", [("interrupt", ok ? "reclaimed" : "held")])
    }

    // MARK: - The tone

    /// Path to the looping tone, generated on first use. Nothing is bundled: a generated file removes
    /// the one silent failure mode a resource would add (XcodeGen not copying it, `path(forResource:)`
    /// returning nil, and the keep-alive quietly doing nothing).
    private static func toneURL() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stashy-keepalive.wav")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        if let size, size > 1024 { return url }
        guard let data = makeTone() else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }

    /// 0.5 s of 16-bit mono 44.1 kHz PCM at roughly −60 dBFS, played at `volume = 0.01` for about
    /// −100 dBFS at the speaker: far below any DAC's noise floor, but genuinely non-zero samples.
    /// Digital silence and one-sample files are both avoided on purpose — iTorrent shipped a 46-byte
    /// single-sample WAV first and moved to a real 0.488 s clip. The reason was never written down, so
    /// treat it as a respected hypothesis rather than proven; there is simply no upside to retesting
    /// the option its author abandoned. 400 Hz fits exactly 200 whole cycles into 0.5 s, so the
    /// infinite loop has no seam to click on.
    private static func makeTone() -> Data? {
        let rate = 44_100
        let frames = rate / 2
        var samples = Data(capacity: frames * 2)
        for i in 0..<frames {
            let value = sin(2 * Double.pi * 400 * Double(i) / Double(rate)) * 32
            let sample = Int16(clamping: Int(value.rounded()))
            withUnsafeBytes(of: sample.littleEndian) { samples.append(contentsOf: $0) }
        }
        var wav = Data(capacity: samples.count + 44)
        func ascii(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + samples.count)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)              // PCM, mono
        u32(UInt32(rate)); u32(UInt32(rate * 2))            // sample rate, byte rate
        u16(2); u16(16)                                     // block align, bits per sample
        ascii("data"); u32(UInt32(samples.count))
        wav.append(samples)
        return wav
    }
}
