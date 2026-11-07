import SwiftUI
import UIKit
import AVFoundation
import BackgroundTasks

/// App delegate whose only job is to report the currently-allowed interface orientations. The whole
/// app is portrait by default; only fullscreen video temporarily allows landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if RemoteLog.isLoggingEnabled { RemoteLog.shared.enable() }   // off by default; toggle in Stats
        // Every BGTaskScheduler launch handler MUST be registered before this method returns, and each
        // identifier exactly once — a second registration of the same id kills the app. This method runs
        // once per process, so it is the only legal site.
        DownloadManager.registerScheduledResume()
        // A pending BGContinuedProcessingTask request may still exist from a build that had the feature.
        // Its handler no longer exists, so cancel it rather than leave iOS holding a request nothing can
        // service. Harmless when there is nothing pending.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: "com.nphil.stashy.downloads.continued")
        // Measure the AI slow-mo model's real dimension ceiling once per device + OS. Runs entirely on
        // VideoToolbox's serial queue and returns immediately; nothing waits on it, and until it lands the
        // shipped 1280×720 floor applies unchanged.
        SlowMoInterpolator.probeMaxSizeIfNeeded()
        // DIAGNOSTIC for the glasses-mirroring investigation: does UIKit report a second screen to
        // this PROCESS at all when the cable goes in? Deprecated API used deliberately, log-only —
        // if `screen-notify` fires but the external scene role never arrives, the block is in scene
        // delivery (manifest/role policy); if it never fires, iPhone 26.6 is handling DP-out entirely
        // at the system level and no app-side change can claim the display. Remove once answered.
        NotificationCenter.default.addObserver(forName: UIScreen.didConnectNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                RemoteLog.shared.event("screen-notify", [("connect", 1), ("screens", UIScreen.screens.count)])
            }
        }
        NotificationCenter.default.addObserver(forName: UIScreen.didDisconnectNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                RemoteLog.shared.event("screen-notify", [("connect", 0), ("screens", UIScreen.screens.count)])
            }
        }
        // Clear remux temps left by a prior crash/force-quit. Nothing is in use at launch, so run it off
        // the main thread — it enumerates + unlinks tmp files and needn't block the first frame.
        Task.detached(priority: .utility) { LocalRemuxStream.sweepStaleTempFiles() }
        // Configure the audio category once (constant for the app) — the player just activates it on play.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    /// The UIKit bridge that lets a SwiftUI-lifecycle app own an external display: for the glasses scene,
    /// return a configuration with our delegate; for every other role, return a bare configuration with
    /// no delegate class, which hands the scene straight back to SwiftUI (the documented pass-through —
    /// the phone window keeps working exactly as before).
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Role visibility for the trace: with `UIApplicationSupportsMultipleScenes` absent this method
        // was never called for the external role at all (the v1.0.346 mirroring bug) — so a missing
        // `scene-config` line IS the diagnosis, not an instrumentation gap.
        RemoteLog.shared.event("scene-config", [("role", connectingSceneSession.role.rawValue)])
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "Glasses", sessionRole: connectingSceneSession.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }

    /// iOS relaunched the app (often straight into the background) to finish queued background downloads.
    /// Stash the completion handler; `DownloadManager`'s session delegate calls it once every event has
    /// been delivered (`urlSessionDidFinishEvents`), letting the system suspend us again.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundDownloadSession.identifier {
            BackgroundDownloadSession.completionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}

enum OrientationController {
    /// Lock to a mask and actively rotate the window to satisfy it. Used to force fullscreen video
    /// into landscape, and to force back to portrait on exit even if the device is held in landscape.
    @MainActor
    static func lock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = mask
        // The PHONE scene only — an unfiltered `.first` can be the glasses scene once one is
        // connected, aiming the geometry request at a screen that doesn't rotate and silently
        // breaking fullscreen.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.role == .windowApplication }) else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
