import SwiftUI
import UIKit

/// Re-enables the interactive edge-swipe "back" gesture even when the navigation bar / back button
/// is hidden (SwiftUI otherwise disables it). Drop into a view's `.background()`.
struct EnableSwipeBack: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Proxy() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Proxy: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            guard let nav = navigationController else { return }
            nav.interactivePopGestureRecognizer?.delegate = self
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }
    }
}
