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
    func makeUIViewController(context: Context) -> UIViewController { Proxy() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        (uiViewController as? Proxy)?.reassert()
    }

    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        private var foregroundObserver: NSObjectProtocol?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent != nil, foregroundObserver == nil {
                foregroundObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reassert() }
                }
            }
            reassert()
        }

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
            gesture.isEnabled = true
        }

        // Only allow the swipe when there's somewhere to pop back to (not on the stack root).
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        deinit {
            if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        }
    }
}
