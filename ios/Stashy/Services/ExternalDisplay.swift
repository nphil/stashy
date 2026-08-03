import UIKit
import SwiftUI

/// XR-glasses (external display) support. The Viture Pro connects over USB-C DisplayPort alt-mode and
/// appears to iOS as a plain external display; iOS mirrors the phone until the app provides a window for
/// the external scene, at which point the app owns the glasses' full canvas.
///
/// ARCHITECTURE. One `GlassesSession` singleton tracks connection state (it is `@Observable`, so SwiftUI
/// bodies that read `isConnected` re-render on plug/unplug). The scene arrives through UIKit — SwiftUI has
/// no native external-display scene type — via `AppDelegate.application(_:configurationForConnecting:)`
/// returning a configuration whose `delegateClass` is `ExternalSceneDelegate`. Video reaches the glasses
/// as a SECOND `AVPlayerLayer` on the SAME `AVPlayer` (`PlaybackEngine.externalRenderView`): one decode
/// clock, perfect sync, and the phone's own layer is never re-parented — the repo's never-reparent rule
/// (ScenePlayerView) stays intact, and `ZoomablePlayerSurface` keeps its view. Every playback route ends
/// at an AVPlayer (direct, server HLS, FFmpeg via the loopback m3u8), so one mechanism covers them all.
///
/// iOS 27 NOTE: external accessory displays move to `UISceneAccessory` registration there; this delegate
/// class carries over, only the discovery half changes. Availability-gate when the SDK lands.
@MainActor
@Observable
final class GlassesSession {
    static let shared = GlassesSession()
    private init() {}

    /// True while an external (glasses) scene is connected — whether or not video is attached.
    private(set) var isConnected = false

    /// Fired exactly once when the cable is pulled / scene disconnects, so the active player can pause
    /// and reclaim its on-phone surface. Set by whoever attached video; cleared after firing.
    @ObservationIgnored var onDisconnect: (@MainActor () -> Void)?

    @ObservationIgnored fileprivate weak var rootController: GlassesRootController?

    /// Shared-service handles for the external hosting trees, registered from ContentView. OBSERVED
    /// (not ignored) so a glasses screen built before the phone tree registered — cold launch with the
    /// cable in — re-renders the moment the handles arrive.
    var env: GlassesEnv?

    /// Host a video view on the glasses (nil clears it). The view is the engine's dedicated external
    /// host — never the phone-side render view.
    func setVideo(_ view: UIView?) {
        rootController?.setVideo(view)
    }

    /// Host an overlay INSIDE the video container (the AI slow-mo frame stream) so it zooms and pans
    /// with the video. nil clears.
    func setOverlay(_ view: UIView?) {
        rootController?.setOverlay(view)
    }

    /// Pinch-zoom state from the remote: scale 1…4 with a pan offset, applied as a transform to the
    /// whole video container (video + slow-mo overlay together).
    func setZoom(scale: CGFloat, offset: CGPoint) {
        rootController?.setZoom(scale: scale, offset: offset)
    }

    fileprivate func attach(_ controller: GlassesRootController) {
        rootController = controller
        isConnected = true
        ScreenAwake.set(.glassesSession, true)
    }

    fileprivate func detach() {
        rootController = nil
        isConnected = false
        ScreenAwake.set(.glassesSession, false)
        let handler = onDisconnect
        onDisconnect = nil
        handler?()
    }
}

/// Delegate for the external-display scene. UIKit instantiates it (from
/// `UISceneConfiguration.delegateClass`) and does NOT retain the window — the strong `window` here is
/// load-bearing.
@MainActor
final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let controller = GlassesRootController()
        let w = UIWindow(windowScene: windowScene)
        w.rootViewController = controller
        // Visible WITHOUT `makeKey` — the phone window must stay key or hardware events (volume keys,
        // keyboard focus) route to a non-interactive screen. Same reasoning as `DebugOverlayWindow`.
        w.isHidden = false
        window = w
        GlassesSession.shared.attach(controller)

        let screen = windowScene.screen
        RemoteLog.shared.event("glasses-connect", [
            ("bounds", "\(Int(screen.bounds.width))×\(Int(screen.bounds.height))"),
            ("scale", screen.scale),
            ("maxfps", screen.maximumFramesPerSecond),
            // `.zero` here means no overscan cropping; a non-zero value is the ONLY reliable overscan
            // signal (the `.scale` compensation mode does not shrink bounds).
            ("overscan", "\(screen.overscanCompensationInsets)"),
        ])
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        RemoteLog.shared.event("glasses-disconnect", [])
        GlassesSession.shared.detach()
        window = nil
    }
}

/// Root of the glasses window: pure black (micro-OLED black = pixels off — the themed mesh would glow
/// behind letterbox bars in a dark room) with a full-bleed video container.
@MainActor
final class GlassesRootController: UIViewController {
    private let videoContainer = UIView()
    /// Opaque cover shown whenever the app isn't active (app switcher, Face ID sheet, phone lock while
    /// output persists). The external window sits OUTSIDE the phone tree's `.appLock()` /
    /// `.snapshotPrivacy()` modifiers, so it needs its own blackout — applied UN-animated, same frame,
    /// for the same reason the snapshot-privacy cover is.
    private let blackout = UIView()
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    /// Tracked explicitly rather than read from `applicationState`: during `willResignActive` the
    /// state still reads `.active`, which would defeat the whole point of covering on resign.
    private var appActive = true

    /// SwiftUI layers: the screen root (idle card / 10-foot home) sits BELOW the video container so
    /// attached video naturally covers it and `setVideo(nil)` reveals it — zero mode plumbing. The
    /// playback OSD sits ABOVE the video, below the blackout.
    private var screenHost: UIHostingController<GlassesScreenRoot>?
    private var osdHost: UIHostingController<GlassesOSDRoot>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let screen = UIHostingController(rootView: GlassesScreenRoot())
        screen.view.backgroundColor = .black
        addChild(screen)
        screen.view.frame = view.bounds
        screen.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen.view)
        screen.didMove(toParent: self)
        screenHost = screen

        videoContainer.frame = view.bounds
        videoContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoContainer)

        let osd = UIHostingController(rootView: GlassesOSDRoot())
        osd.view.backgroundColor = .clear
        addChild(osd)
        osd.view.frame = view.bounds
        osd.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(osd.view)
        osd.didMove(toParent: self)
        osdHost = osd

        RemoteLog.shared.event("glasses-ui", [("host", "ok")])

        blackout.backgroundColor = .black
        blackout.frame = view.bounds
        blackout.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blackout.isHidden = true
        view.addSubview(blackout)

        let nc = NotificationCenter.default
        resignObserver = nc.addObserver(forName: UIApplication.willResignActiveNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActive = false; self?.syncBlackout() }
        }
        activeObserver = nc.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appActive = true; self?.syncBlackout() }
        }
        armLockObservation()
        syncBlackout()
    }

    /// The blackout covers whenever the app isn't active OR the app lock is up. The lock half is what
    /// stops the Face ID return-transition lifting the glasses cover before authentication passes —
    /// `didBecomeActive` fires the moment the prompt appears, not when it succeeds.
    private func syncBlackout() {
        blackout.isHidden = appActive && !AppLockState.shared.isLocked
    }

    /// Re-evaluate on every lock flip. `withObservationTracking`'s onChange fires on the mutating
    /// thread — AppLockState is @MainActor, so `assumeIsolated` is correct, and it must act before any
    /// suspension (the same reasoning as the snapshot-privacy cover).
    private func armLockObservation() {
        withObservationTracking {
            _ = AppLockState.shared.isLocked
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncBlackout()
                self.armLockObservation()
            }
        }
    }

    private var overlayView: UIView?

    func setVideo(_ videoView: UIView?) {
        for sub in videoContainer.subviews where sub !== overlayView { sub.removeFromSuperview() }
        guard let videoView else { return }
        videoView.frame = videoContainer.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoContainer.insertSubview(videoView, at: 0)
    }

    func setOverlay(_ view: UIView?) {
        overlayView?.removeFromSuperview()
        overlayView = view
        guard let view else { return }
        view.frame = videoContainer.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoContainer.addSubview(view)   // above the player layer, inside the zoom transform
    }

    func setZoom(scale: CGFloat, offset: CGPoint) {
        let s = max(1, min(4, scale))
        videoContainer.transform = CGAffineTransform(translationX: offset.x, y: offset.y)
            .scaledBy(x: s, y: s)
    }
}
