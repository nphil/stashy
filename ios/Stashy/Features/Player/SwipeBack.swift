import SwiftUI
import UIKit

/// Re-enables the interactive edge-swipe "back" gesture even when the navigation bar / back button is
/// hidden (SwiftUI otherwise disables it). Drop into a view's `.background()`.
///
/// A navigation controller has ONE shared `interactivePopGestureRecognizer`, and each pushed screen that
/// uses this helper claims its `delegate` (a *weak* reference). So the delegate goes stale in two ways the
/// old set-once-in-`didMove` version never recovered from — the exact "can't swipe back" cases reported:
///   1. Push a deeper screen (e.g. Downloads) then pop it: the deeper screen's proxy deallocs, the weak
///      delegate becomes nil, and the revealed screen's swipe is dead until something re-claims it.
///   2. Background the app and return: UIKit resets the recogniser, dropping our delegate.
/// So re-assert on every reveal (`viewWillAppear`/`viewDidAppear`), on SwiftUI updates, and on foreground —
/// not just once at insert time.
struct EnableSwipeBack: UIViewControllerRepresentable {
    /// Globally park the edge-swipe while the fullscreen player is up. The always-armed edge-pan (the
    /// re-assert below is what keeps it reliable) CLAIMS any touch starting near the left screen edge —
    /// exactly where a thumb lands when pinch-zooming a landscape fullscreen video — cancelling the
    /// scroll view's pinch (the "zoom only works some of the time" bug; it depended on finger placement,
    /// not the video). Fullscreen has no back-swipe anyway (exit is the ✕ / swipe-down), so it's safe to
    /// suppress outright; ScenePlayerView flips this with isFullscreen.
    @MainActor static var suppressed = false

    func makeUIViewController(context: Context) -> UIViewController { Proxy() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Proxy)?.reassert()
    }

    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        private var observing = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            // Selector-based observation (not block-based): NotificationCenter auto-removes it on dealloc
            // (iOS 9+), so there's no stored token to clean up — which avoids a `deinit` that would have to
            // touch a non-Sendable member (illegal from a @MainActor class's nonisolated deinit under Swift 6).
            if parent != nil, !observing {
                observing = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(appBecameActive),
                    name: UIApplication.didBecomeActiveNotification, object: nil)
            }
            reassert()
        }

        @objc private func appBecameActive() { reassert() }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            reassert()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            reassert()
        }

        /// Make this proxy the pop-gesture delegate and (re-)enable it. Idempotent and cheap, so it's safe
        /// to call from every reveal / update / foreground.
        func reassert() {
            guard let nav = navigationController,
                  let gesture = nav.interactivePopGestureRecognizer else { return }
            if gesture.delegate !== self { gesture.delegate = self }
            gesture.isEnabled = !EnableSwipeBack.suppressed
        }

        // Only allow the swipe when there's somewhere to pop back to (not on the stack root) and the
        // fullscreen player isn't up (see `suppressed` — it would steal fullscreen pinch-zoom touches).
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            !EnableSwipeBack.suppressed && (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
