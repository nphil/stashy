import SwiftUI
import UIKit

/// App delegate whose only job is to report the currently-allowed interface orientations. The whole
/// app is portrait by default; only fullscreen video temporarily allows landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        RemoteLog.shared.enable()   // streams on-device debug logs to ntfy.sh during testing
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
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
