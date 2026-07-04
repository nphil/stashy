import SwiftUI
import UIKit

/// An app-wide debug screenshot affordance: a small, draggable camera button that floats over *every*
/// screen (library, performer, settings, and the video player with its controls) whenever debug logging
/// is enabled. Tapping it snapshots the current screen and uploads it to the configured ntfy topic.
///
/// The button lives in its **own** passthrough `UIWindow` above the app, for two reasons: it can hover
/// over fullscreen video regardless of the SwiftUI view tree, and — because capture targets the *app*
/// window, not this overlay window — the button never appears in the screenshot it takes. Touches outside
/// the button pass straight through to the app.
///
/// Caveat (unavoidable): a UIKit window snapshot cannot capture an AVPlayer/Metal-backed video layer, so
/// the raw video area reads black. The player's *controls/overlays* are ordinary SwiftUI and DO capture —
/// which is exactly what's wanted for checking control layout.
@MainActor
final class DebugOverlayController {
    static let shared = DebugOverlayController()
    private var window: DebugOverlayWindow?

    func setEnabled(_ on: Bool) {
        if on { install() } else { remove() }
    }

    private func install() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else { return }
        let w = DebugOverlayWindow(windowScene: scene)
        w.windowLevel = .statusBar + 1          // above app content and fullscreen video
        w.backgroundColor = .clear
        w.rootViewController = DebugOverlayViewController()
        w.isHidden = false                       // show WITHOUT makeKey, so the app window stays key
        window = w
    }

    private func remove() {
        window?.isHidden = true
        window = nil
    }

    /// Snapshot the app's main window (never this overlay window) to JPEG.
    static func captureAppWindowJPEG() -> Data? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !($0 is DebugOverlayWindow) }
        guard let target = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: target.bounds)
        let full = renderer.image { _ in
            target.drawHierarchy(in: target.bounds, afterScreenUpdates: false)
        }
        // Downscale so the JPEG comfortably clears ntfy.sh's 2 MB attachment cap (a Pro-res phone screen is
        // ~1206×2622; 1400px longest edge stays sharp enough to read UI while shrinking the file a lot).
        let maxEdge: CGFloat = 1400
        let factor = min(1, maxEdge / max(full.size.width, full.size.height))
        let image: UIImage
        if factor < 1 {
            let size = CGSize(width: full.size.width * factor, height: full.size.height * factor)
            image = UIGraphicsImageRenderer(size: size).image { _ in
                full.draw(in: CGRect(origin: .zero, size: size))
            }
        } else {
            image = full
        }
        // Step JPEG quality down until under ~1.8 MB (leaves headroom below the 2 MB cap).
        for quality in [0.6, 0.45, 0.3, 0.2] as [CGFloat] {
            if let data = image.jpegData(compressionQuality: quality), data.count <= 1_800_000 { return data }
        }
        return image.jpegData(compressionQuality: 0.15)
    }
}

/// A window that passes every touch through to the app below except those landing on its subviews (the
/// button), so the overlay never blocks the UI it's meant to photograph.
private final class DebugOverlayWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view ? nil : hit
    }
}

/// Hosts the draggable camera button.
private final class DebugOverlayViewController: UIViewController {
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "camera.fill")
        config.cornerStyle = .capsule
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(capture), for: .touchUpInside)
        view.addSubview(button)

        // Default resting position: above the tab bar, trailing side.
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -76),
        ])
        button.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
    }

    @objc private func capture() {
        guard let data = DebugOverlayController.captureAppWindowJPEG() else { return }
        RemoteLog.shared.uploadImage(data, caption: "screenshot")
        // Quick visual + haptic ack that the shot was taken.
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let original = button.alpha
        button.alpha = 0.25
        UIView.animate(withDuration: 0.35) { self.button.alpha = original }
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        button.center = CGPoint(x: button.center.x + translation.x, y: button.center.y + translation.y)
        gesture.setTranslation(.zero, in: view)
    }
}

extension View {
    /// Install the app-wide debug screenshot button whenever debug logging is on. Apply once at the root.
    func debugScreenshotOverlay() -> some View {
        modifier(DebugScreenshotOverlay())
    }
}

private struct DebugScreenshotOverlay: ViewModifier {
    @AppStorage("stashy.debugLogging") private var debugLogging = false

    func body(content: Content) -> some View {
        content
            .onAppear { DebugOverlayController.shared.setEnabled(debugLogging) }
            .onChange(of: debugLogging) { _, on in DebugOverlayController.shared.setEnabled(on) }
    }
}
