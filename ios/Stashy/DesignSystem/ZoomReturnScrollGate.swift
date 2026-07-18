import SwiftUI

/// Works around a confirmed iOS 26 SwiftUI bug (FB21961572): after a `.navigationTransition(.zoom)` pops,
/// the `matchedTransitionSource` card is held out of the scroll layout through the transition's settle, so
/// scrolling *immediately* after a zoom-back freezes that one card for ~a second (worse with richer cells).
/// Nothing makes the transition release the card sooner, so instead we briefly disable scrolling after a
/// pop — the freeze window is simply never entered. Apply on the `NavigationStack`'s root content (an
/// ancestor of the grid); `scrollDisabled` propagates to the descendant scroll views via the environment.
/// The 600 ms hold is the tuning knob: raise it if the freeze still peeks through, lower it if the brief
/// scroll-lock feels long.
private struct ZoomReturnScrollGate: ViewModifier {
    /// The navigation path depth. A DECREASE means a pop (zoom-back) just happened.
    let depth: Int
    @State private var settling = false
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollDisabled(settling)
            .onChange(of: depth) { oldDepth, newDepth in
                guard newDepth < oldDepth else { return }   // only a pop, never a push
                settling = true
                // Cancel any in-flight reset so a rapid pop→push→pop can't release the lock early (which
                // would let the freeze peek through on the second back). Same pattern as ScenesView's
                // reloadDebounce: the cancelled Task's isCancelled guard skips the early re-enable.
                resetTask?.cancel()
                resetTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    settling = false
                }
            }
    }
}

extension View {
    /// Briefly disables scrolling after a `NavigationStack` pop to hide the iOS 26 zoom-transition
    /// source-card freeze (see `ZoomReturnScrollGate`). Pass the current path depth (`path.count`).
    func zoomReturnScrollGate(depth: Int) -> some View { modifier(ZoomReturnScrollGate(depth: depth)) }
}
