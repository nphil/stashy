import SwiftUI
import UIKit
import AVFoundation

/// App delegate whose only job is to report the currently-allowed interface orientations. The whole
/// app is portrait by default; only fullscreen video temporarily allows landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if RemoteLog.isLoggingEnabled { RemoteLog.shared.enable() }   // off by default; toggle in Stats
        LocalRemuxStream.sweepStaleTempFiles()   // clear remux temps left by a prior crash/force-quit
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
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
