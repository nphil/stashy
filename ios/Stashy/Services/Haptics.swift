import UIKit
import QuartzCore

/// Centralised Taptic Engine feedback, kept lightweight so it can fire during a fast drag without hurting
/// performance. `UISelectionFeedbackGenerator` gives the picker-style "tick" (the same crisp feedback iOS
/// uses for a spinning picker wheel) for crossing discrete steps — scrub preview frames and volume
/// increments — while impact generators cover discrete button presses. Generators are shared and kept warm
/// via `prepare()` for low latency, and the selection tick is rate-limited so an extremely fast drag can't
/// flood the engine (which would just smear into a continuous buzz and waste cycles).
@MainActor
enum Haptics {
    private static let selection = UISelectionFeedbackGenerator()
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static var lastTick: CFTimeInterval = 0

    /// Prime the engine at the start of a drag so the first tick has no warm-up latency.
    static func prepareSelection() { selection.prepare() }

    /// One light "tick" for crossing a discrete step (a new scrub preview frame, a volume increment).
    /// Rate-limited (default ~12 ms → ~80/s max) so a fast drag stays crisp instead of flooding the engine.
    static func selectionTick(minInterval: CFTimeInterval = 0.012) {
        let now = CACurrentMediaTime()
        guard now - lastTick >= minInterval else { return }
        lastTick = now
        selection.selectionChanged()
        selection.prepare()   // keep warm for the next tick
    }

    /// A discrete press: `.medium` (play/pause) by default, `.light` when `soft` (skip ±10 s).
    static func tap(soft: Bool = false) {
        let generator = soft ? impactLight : impactMedium
        generator.impactOccurred()
        generator.prepare()
    }
}
