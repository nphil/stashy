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

/// Auto-MINIMIZES the bottom tab bar when the screen appears (owner: entering the player or the
/// scene-pushed Downloads screen must collapse the bar even when it was fully expanded on the grid).
///
/// There is no public "set minimized" API — `tabBarMinimizeBehavior(.onScrollDown)` only reacts to
/// scrolling. The public escape hatch is `UIViewController.setContentScrollView(_:for:)` (iOS 15+):
/// bars observe the registered bottom-edge scroll view, so registering a hidden, non-interactive
/// scroll view we own and nudging it downward minimizes the bar exactly as a user scroll would —
/// with the system's own animation. One-shot per appearance; the association dies with the screen's
/// controller on pop, so grids behind are untouched.
struct TabBarMinimizer: UIViewRepresentable {
    // MainActor: the stored UIScrollView's default-value initializer is main-actor-isolated, and every
    // Coordinator touchpoint (makeCoordinator/updateUIView) already runs on the main actor.
    @MainActor final class Coordinator {
        let scrollView = UIScrollView()
        var applied = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TabBarProbeView {
        let probe = TabBarProbeView()
        let scroll = context.coordinator.scrollView
        scroll.isUserInteractionEnabled = false
        scroll.isHidden = true
        scroll.frame = .zero
        scroll.contentSize = CGSize(width: 1, height: 4000)
        probe.addSubview(scroll)
        return probe
    }

    func updateUIView(_ uiView: TabBarProbeView, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.applied else { return }
        coordinator.applied = true
        // Defer past the SwiftUI update AND the push transition: registering mid-transition can be
        // clobbered when the system re-resolves the tracked scroll view as the new screen settles
        // (screens with their own List/ScrollView — compact Downloads — register theirs on appear).
        Task { @MainActor in
            for _ in 0..<10 {   // wait until the probe is installed in a window (~max 1 s)
                if uiView.window != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard uiView.window != nil, let host = uiView.findViewController() else { return }
            try? await Task.sleep(for: .milliseconds(400))   // outlast the ~0.35 s push animation
            let scroll = coordinator.scrollView
            host.setContentScrollView(scroll, for: .bottom)
            scroll.setContentOffset(.zero, animated: false)
            try? await Task.sleep(for: .milliseconds(80))
            // A continuous animated downward scroll — the gesture the minimize behavior listens for.
            scroll.setContentOffset(CGPoint(x: 0, y: 600), animated: true)
        }
    }
}

/// Zero-impact probe: walks the responder chain (view → hosting controller → container controllers)
/// to the nearest tab bar controller / owning view controller.
final class TabBarProbeView: UIView {
    func findTabBarController() -> UITabBarController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let tab = current as? UITabBarController { return tab }
            responder = current.next
        }
        return nil
    }

    func findViewController() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}
