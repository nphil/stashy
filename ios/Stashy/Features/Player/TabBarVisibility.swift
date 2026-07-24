import SwiftUI
import UIKit

/// Imperatively hides/shows the enclosing `UITabBarController`'s bar (owner: the bottom tab bar shows
/// on EVERY screen, including the scene player — fullscreen video is the one place it must vanish).
///
/// Why not `.toolbar(isFullscreen ? .hidden : .visible, for: .tabBar)`: SwiftUI only re-applies that
/// preference on a push/pop or an orientation change — toggling it IN PLACE is the documented landmine
/// that used to leave the bar showing in portrait (button-triggered, no-rotation) fullscreen. UIKit's
/// `setTabBarHidden(_:animated:)` (iOS 18+) applies deterministically the moment it's called.
///
/// The probe finds the controller through the responder chain (no private API) and restores the bar on
/// removal, so popping the screen mid-fullscreen can never strand a hidden bar on the grid.
struct TabBarHiddenSetter: UIViewRepresentable {
    var hidden: Bool

    final class Coordinator {
        weak var tabController: UITabBarController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TabBarProbeView { TabBarProbeView() }

    func updateUIView(_ uiView: TabBarProbeView, context: Context) {
        let hidden = hidden
        let coordinator = context.coordinator
        // Defer out of the SwiftUI update pass (and until the probe is in a window, so the responder
        // chain reaches the tab controller).
        Task { @MainActor in
            guard let controller = coordinator.tabController ?? uiView.findTabBarController() else { return }
            coordinator.tabController = controller
            if controller.isTabBarHidden != hidden {
                controller.setTabBarHidden(hidden, animated: true)
            }
        }
    }

    static func dismantleUIView(_ uiView: TabBarProbeView, coordinator: Coordinator) {
        // Leaving the screen (pop / swipe-back, even mid-fullscreen) must never strand a hidden bar.
        let controller = coordinator.tabController
        Task { @MainActor in
            if let controller, controller.isTabBarHidden {
                controller.setTabBarHidden(false, animated: false)
            }
        }
    }
}

/// Zero-impact probe: walks the responder chain (view → hosting controller → container controllers)
/// to the nearest tab bar controller.
final class TabBarProbeView: UIView {
    func findTabBarController() -> UITabBarController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let tab = current as? UITabBarController { return tab }
            responder = current.next
        }
        return nil
    }
}
