import AVKit
import UIKit

/// The system Picture in Picture window for the phone's own player layer.
///
/// One instance per `AVPlaybackEngine`, built around THAT engine's `AVPlayerLayer` and torn down with the
/// rest of its playback stack — so an engine swap (a quality switch, a far-seek rebuild, the HLS fallback)
/// can never leave a controller pointing at a dead layer. This class only wraps the controller and reports
/// the window's events; every decision about what they MEAN for the app (dock the page when the owner opens
/// the window, reopen the player when its restore button is tapped, end playback when its ✕ is tapped) is
/// `NowPlaying`'s.
@MainActor
final class PictureInPictureWindow: NSObject {
    private let controller: AVPictureInPictureController
    private var possibleObservation: NSKeyValueObservation?

    /// True from the moment the system starts opening the window until it has closed.
    private(set) var isActive = false
    /// A stop WE asked for is in flight (the chrome button, expanding the bar, closing it, teardown), so the
    /// `didStop` that follows is not mistaken for the owner tapping the window's ✕.
    private var stopRequested = false
    /// The system asked us to bring the app UI back (the window's "return to app" button): the stop that
    /// follows is a hand-back, not a close.
    private var restoring = false

    /// KVO-backed; every change is reported to `NowPlaying.pictureInPicturePossibleChanged`.
    var isPossible: Bool { controller.isPictureInPicturePossible }

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
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.possibleChanged() }
        }
    }

    func start() {
        stopRequested = false
        controller.startPictureInPicture()
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
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller.delegate = nil
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        if isActive { controller.stopPictureInPicture() }
        isActive = false
        stopRequested = false
        restoring = false
    }

    private func possibleChanged() {
        NowPlaying.shared.pictureInPicturePossibleChanged(self)
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

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        NowPlaying.shared.pictureInPictureDidStart(self)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: any Error) {
        isActive = false
        stopRequested = false
        RemoteLog.shared.event("pip", [("start", "failed"), ("err", error.localizedDescription)])
        NowPlaying.shared.pictureInPictureFailedToStart(self)
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
