import SwiftUI
import UIKit

/// Mounts the fullscreen remote as a dedicated WINDOW on the phone scene while glasses are connected —
/// the DebugOverlay pattern. A window (not a fullScreenCover, not a root swap) because only a window
/// floats above every presentation style while leaving the whole tree — per-tab nav paths, sheets,
/// scroll positions — alive underneath, so unplugging restores exactly where the user was.
@MainActor
final class RemoteTakeover {
    static let shared = RemoteTakeover()
    private init() {}

    private var window: UIWindow?

    /// Re-evaluated by the ContentView driver on every relevant observable flip. Deliberately NOT
    /// called from `GlassesSession.attach()`: at a cold launch with the cable already in, the external
    /// scene can connect before the phone scene exists, and window creation would silently bail. The
    /// observation-driven driver is order-proof — it re-runs once the phone tree is up.
    func sync(shouldShow: Bool) {
        if shouldShow { install() } else { remove() }
    }

    private func install() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else { return }
        let w = UIWindow(windowScene: scene)
        // Above app content, below the debug overlay (.statusBar + 1) so the screenshot button still floats.
        w.windowLevel = .normal + 1
        w.rootViewController = RemoteHostingController(
            rootView: RemoteRootView(coordinator: GlassesCoordinator.shared))
        w.backgroundColor = .black
        w.isHidden = false            // never makeKey — hardware events stay with the app window
        window = w
        RemoteLog.shared.event("glasses-remote", [("takeover", 1)])
    }

    private func remove() {
        guard window != nil else { return }
        window?.isHidden = true
        window = nil
        RemoteLog.shared.event("glasses-remote", [("takeover", 0)])
    }
}

/// Hosting controller that defers the system edge gestures — the remote's surface owns every edge
/// (Control Center / notification pulls need the little tab pull-down first, so a scrub that drifts
/// to an edge doesn't yank the shade over the session).
final class RemoteHostingController: UIHostingController<RemoteRootView> {
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { [.top, .bottom] }
    override var prefersStatusBarHidden: Bool { true }
}

/// ContentView modifiers: registers the shared-service handles for the external scene's hosting trees
/// and drives the takeover window from observation.
struct GlassesEnvRegistrar: View {
    @Environment(AppState.self) private var appState
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryEdits.self) private var edits
    @Environment(\.imageCache) private var imageCache

    var body: some View {
        Color.clear
            .onAppear {
                GlassesSession.shared.env = GlassesEnv(
                    appState: appState, downloads: downloads, edits: edits, imageCache: imageCache)
            }
    }
}

/// Observation-driven mount: reading these observables in `body` re-evaluates on every flip, and the
/// `.onChange(initial: true)` covers the cold-launch case where the glasses scene connected first.
struct GlassesTakeoverDriver: View {
    var body: some View {
        let session = GlassesSession.shared
        let coordinator = GlassesCoordinator.shared
        let authenticated = session.env?.appState.isAuthenticated ?? false
        let should = session.isConnected && authenticated && !coordinator.takeoverSuppressed
        return Color.clear
            .onChange(of: should, initial: true) { _, now in
                RemoteTakeover.shared.sync(shouldShow: now)
            }
            .onChange(of: session.isConnected, initial: true) { was, now in
                if now, !was { coordinator.sessionBegan() }
                if !now, was { coordinator.sessionEnded() }
            }
    }
}

/// The way back into the remote after EXIT: a floating pill INSIDE the app tree (so app lock covers
/// it), visible only while connected-but-exited.
struct GlassesReturnPill: ViewModifier {
    @State private var session = GlassesSession.shared
    @State private var coordinator = GlassesCoordinator.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if session.isConnected, coordinator.takeoverSuppressed {
                Button {
                    Haptics.tap()
                    coordinator.takeoverSuppressed = false
                } label: {
                    Label("Return to glasses", systemImage: "eyeglasses")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 11)
                        .background(Color.black.opacity(0.82), in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 78)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                   value: session.isConnected && coordinator.takeoverSuppressed)
    }
}
