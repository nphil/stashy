import AVKit
import UIKit

/// The system Picture in Picture window for the phone's own player layer.
///
/// One instance per `AVPlaybackEngine`, built around THAT engine's `AVPlayerLayer` and torn down with the
/// rest of its playback stack — so an engine swap (a quality switch, a far-seek rebuild, the HLS fallback)
/// can never leave a controller pointing at a dead layer. This class only wraps the controller and reports
/// the window's events; every decision about what they MEAN for the app (restore returns to the page that is
/// already up, the window's ✕ pauses) is `NowPlaying`'s. The window opens only automatically, when the app goes
/// to the background while the video plays — there is no button for it.
@MainActor
final class PictureInPictureWindow: NSObject {
    private let controller: AVPictureInPictureController

    /// True from the moment the system starts opening the window until it has closed.
    private(set) var isActive = false
    /// A stop WE asked for is in flight (the page leaving, Privacy Mode turning on, teardown), so the
    /// `didStop` that follows is not mistaken for the owner tapping the window's ✕.
    private var stopRequested = false
    /// The system asked us to bring the app UI back (the window's "return to app" button): the stop that
    /// follows is a hand-back, not a close.
    private var restoring = false

    /// Open the window by itself when the app goes to the background while this video plays.
    var startsAutomatically: Bool {
        get { controller.canStartPictureInPictureAutomaticallyFromInline }
        set { controller.canStartPictureInPictureAutomaticallyFromInline = newValue }
    }

    /// nil where the device can't do Picture in Picture, or the layer can't back a window.
    ///
    /// The initializer is FAILABLE (verified against Apple's reference for
    /// `AVPictureInPictureController.init(playerLayer:)`), hence the `guard let`.
    init?(layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer) else { return nil }
        self.controller = controller
        super.init()
        controller.delegate = self
        // The starting policy is the app-wide one (privacy, app lock, glasses); `NowPlaying` refines it per
        // playback (slow-mo) and whenever one of its inputs changes.
        controller.canStartPictureInPictureAutomaticallyFromInline = NowPlaying.automaticPictureInPictureAllowed
    }

    /// Close the window from our side. A no-op unless it is up, so a stale request can never arm
    /// `stopRequested` against the owner's NEXT ✕ tap.
    func stop() {
        guard isActive else { return }
        stopRequested = true
        controller.stopPictureInPicture()
    }

    /// Stop reporting and close the window. The engine calls this BEFORE it releases the layer's player.
    func tearDown() {
        controller.delegate = nil
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        if isActive { controller.stopPictureInPicture() }
        isActive = false
        stopRequested = false
        restoring = false
    }
}

// `AVPictureInPictureControllerDelegate` is not main-actor annotated; AVKit calls it on the main thread.
// `@preconcurrency` lets the main-actor members satisfy it (checked at runtime) — the same shape the other
// delegates in this app use (ENGINEERING_NOTES §2).
extension PictureInPictureWindow: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        stopRequested = false
        restoring = false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        isActive = false
        stopRequested = false
        RemoteLog.shared.event("pip", [("start", "failed"), ("err", error.localizedDescription)])
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        restoring = true
        NowPlaying.shared.restoreFromPictureInPicture(self, completion: completionHandler)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        let requested = stopRequested
        let restored = restoring
        isActive = false
        stopRequested = false
        restoring = false
        NowPlaying.shared.pictureInPictureDidStop(self, requested: requested, restored: restored)
    }
}
