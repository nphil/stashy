import CoreHaptics
import Foundation
import QuartzCore   // CACurrentMediaTime for the send throttle

/// Continuous, parameter-modulated haptics for the remote's analog stick — the "bed" under the
/// discrete detents that `Haptics` already provides. Clicks alone read as a touchscreen; rumble alone
/// reads as a phone vibrating; together they read as a mechanism.
///
/// ## AUDIO-SESSION SAFETY — read before changing anything here
/// This app's entire indefinite-background-download strategy rests on the `audio` background mode
/// plus an ACTIVE `AVAudioSession` that `DownloadKeepAlive` re-arms every ~10 s, and ENGINEERING_NOTES
/// §9 forbids audio-session writes in glasses code because they knock that renewal over. A regression
/// here would not look like a haptics bug — it would look like a 700 MB download dying at 26 s.
///
/// Three constructions keep this safe, and all three are load-bearing:
///  1. `CHHapticEngine()` — the NIL-session initialiser. Apple: "If `audioSession` is nil, the engine
///     will create its own." NEVER pass `AVAudioSession.sharedInstance()`; that would join our session
///     and make its interruption behaviour ours.
///  2. `playsHapticsOnly = true`, set BEFORE `start()` (it is ignored on a running engine) — "causes
///     the engine to ignore all audio events" and reduces start latency.
///  3. `isAutoShutdownEnabled = true` so an idle engine frees the hardware instead of holding it.
/// This file makes ZERO `setCategory` / `setActive` calls, and must continue to.
///
/// Nothing structural depends on CoreHaptics: every discrete event in the remote already uses the
/// standard feedback generators, so if this engine is unavailable the bed degrades to a rate-modulated
/// `Haptics.selectionTick()` train (§`fallbackInterval`) and the control still works completely.
@MainActor
final class StickHaptics {
    static let shared = StickHaptics()
    private init() {}

    /// Bool is Sendable, so a file-scope static let is legal under strict concurrency (lazily
    /// initialised via swift_once).
    static let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    /// Owner escape hatch (Settings → Diagnostics) in case the engine ever misbehaves on device.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "stickHapticsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "stickHapticsEnabled") }
    }

    /// Bed textures. The texture IS the mode tell: a 60 ms nudge on the stick tells the hand whether
    /// it is in transport, slow-motion or frame mode without a single pixel being read.
    enum Texture: Equatable {
        /// Browse/grid: silent between detents. Absence is itself a signal.
        case off
        /// Transport shuttle: bright and gritty, crisper the faster you go.
        case transport
        /// Jog / AI slow motion: syrupy and rubbery. Slow motion feels slow in the hand — nothing else
        /// in the vocabulary is smooth.
        case viscous
        /// Frame/pan: light, constant, no detents. A camera is lighter than a transport.
        case frame
        /// Pushing against a limit (0:00, the ceiling, the edge of a zoomed picture).
        case grind

        /// Sharpness is ADDITIVE against the pattern's 0.5 base, so these are deltas.
        func sharpnessDelta(_ u: Float) -> Float {
            switch self {
            case .off:       return 0
            case .transport: return (0.20 + 0.55 * u) - 0.5
            case .viscous:   return (0.10 + 0.12 * u) - 0.5
            case .frame:     return 0.55 - 0.5
            case .grind:     return 0.85 - 0.5
            }
        }

        /// Intensity is MULTIPLICATIVE against the pattern's 1.0 base. Quadratic because perceived
        /// effort should rise faster than brightness — the rim must feel like straining against a
        /// spring.
        func intensity(_ u: Float) -> Float {
            switch self {
            case .off:       return 0
            case .transport: return 0.06 + 0.62 * u * u
            case .viscous:   return (0.06 + 0.62 * u * u) * 0.85
            case .frame:     return (0.06 + 0.62 * u * u) * 0.5
            case .grind:     return 0.50
            }
        }
    }

    private var engine: CHHapticEngine?
    private var player: (any CHHapticAdvancedPatternPlayer)?
    private var bedRunning = false
    private var texture: Texture = .off
    private var lastIntensity: Float = -1
    private var lastSharpness: Float = -1
    private var lastSend: CFTimeInterval = 0
    private var starting = false

    /// True when the engine is unavailable and callers should fall back to a `selectionTick` train.
    var usingFallback: Bool { engine == nil }

    // MARK: - Lifecycle

    /// Warm the engine when the remote appears, so the ~30 ms start is not paid on first touch.
    /// Apple: "starting the haptic engine is expensive, as is stopping it — start and stop sparingly."
    func prepare() async {
        guard Self.supportsHaptics, Self.isEnabled, engine == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let e = try CHHapticEngine()          // NIL SESSION — see the file header.
            e.playsHapticsOnly = true             // MUST precede start(); ignored on a running engine.
            e.isAutoShutdownEnabled = true
            // Handlers are set BEFORE start, and fire on CoreHaptics' own queue — NOT the main thread.
            // `MainActor.assumeIsolated` (this repo's habitual hop) would TRAP here, so we capture only
            // Sendable scalars and hop with an explicit Task.
            e.stoppedHandler = { reason in
                let code = reason.rawValue
                RemoteLog.shared.log("glasses-haptic stopped=\(code)")
                Task { @MainActor in StickHaptics.shared.engineStopped() }
            }
            e.resetHandler = {
                RemoteLog.shared.log("glasses-haptic reset")
                Task { @MainActor in await StickHaptics.shared.rebuildAfterReset() }
            }
            try await e.start()
            engine = e
        } catch {
            RemoteLog.shared.log("glasses-haptic start-failed \(String("\(error)".prefix(60)))")
            engine = nil
        }
    }

    private func engineStopped() {
        bedRunning = false
        player = nil
        engine = nil
    }

    /// A reset invalidates every existing pattern player, so the engine must be restarted AND the
    /// player recreated — and the bed resumed if one was live.
    private func rebuildAfterReset() async {
        let wasRunning = bedRunning
        let t = texture
        bedRunning = false
        player = nil
        engine = nil
        await prepare()
        if wasRunning { beginBed(t) }
    }

    // MARK: - The bed

    func beginBed(_ t: Texture) {
        texture = t
        guard t != .off else { endBed(); return }
        guard Self.isEnabled, let engine else { return }
        if player == nil {
            do {
                // A continuous event is capped at 30 SECONDS — Apple's own sample code illegally passes
                // 100, and copying it ships a stick that goes numb after half a minute of holding. Use
                // a short event on a LOOPING advanced player instead.
                //
                // Base intensity 1.0 and sharpness 0.5 are deliberate: the dynamic intensity parameter
                // MULTIPLIES (so 1.0 gives the control the full 0…1 span) while the dynamic sharpness
                // parameter ADDS (so 0.5 lets it go both softer and crisper).
                let event = CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                 CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)],
                    relativeTime: 0,
                    duration: 2.0)
                let pattern = try CHHapticPattern(events: [event], parameters: [])
                let p = try engine.makeAdvancedPlayer(with: pattern)
                p.loopEnabled = true
                p.loopEnd = 2.0                   // set EXPLICITLY; do not rely on 0 meaning "all"
                player = p
            } catch {
                RemoteLog.shared.log("glasses-haptic player-failed \(String("\(error)".prefix(40)))")
                player = nil
                return
            }
        }
        guard !bedRunning, let player else { return }
        // CHHapticTimeImmediate is a free global, NOT a CHHapticEngine member.
        try? player.start(atTime: CHHapticTimeImmediate)
        bedRunning = true
        lastIntensity = -1
        lastSharpness = -1
    }

    /// Feed the bed from the stick's 30 Hz tick. `u` is normalised deflection 0…1.
    func setBed(_ t: Texture, u: Float) {
        guard Self.isEnabled else { return }
        if t != texture {
            texture = t
            if t == .off { endBed(); return }
            if !bedRunning { beginBed(t) }
        }
        guard bedRunning, let player else { return }
        let clamped = min(1, max(0, u))
        let i = t.intensity(clamped)
        let s = t.sharpnessDelta(clamped)
        // Throttle to 30 Hz AND to meaningful deltas — every send is a syscall into the haptic server.
        let now = CACurrentMediaTime()
        guard now - lastSend >= 0.033 || lastIntensity < 0 else { return }
        guard abs(i - lastIntensity) > 0.02 || abs(s - lastSharpness) > 0.03 || lastIntensity < 0 else { return }
        lastSend = now
        lastIntensity = i
        lastSharpness = s
        // All of start/stop/sendParameters throw; `try?` on the hot path so a mid-drag failure can
        // never propagate out of a touch handler.
        try? player.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: i, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: s, relativeTime: 0)
        ], atTime: 0)
    }

    /// A real detent UNLOADS the spring an instant before the ball drops. Without this dip, a "wall"
    /// is just a louder buzz on top of a buzz and reads as noise; with it, the hand reports a
    /// mechanism. This is the highest-leverage 10 lines in the whole haptic score.
    func dip() {
        guard Self.isEnabled, bedRunning, let player else { return }
        try? player.sendParameters(
            [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.02, relativeTime: 0)],
            atTime: 0)
        lastIntensity = 0.02
        lastSend = 0        // let the next tick restore the bed immediately
    }

    func endBed() {
        texture = .off
        guard bedRunning, let player else { bedRunning = false; return }
        try? player.stop(atTime: CHHapticTimeImmediate)
        bedRunning = false
        lastIntensity = -1
        lastSharpness = -1
    }

    /// Unconditional silence — lock, app-lock, background, glasses disconnect, a second finger landing.
    /// A locked remote that still hums is a lie.
    func abort() {
        endBed()
    }

    /// Fallback cadence when CoreHaptics is unavailable: a `Haptics.selectionTick()` train from 3 Hz
    /// at the gate to 15 Hz at the rim. Coarse, but a genuine rate readout.
    static func fallbackInterval(u: Float) -> TimeInterval {
        1.0 / Double(3 + 12 * min(1, max(0, u)))
    }
}
