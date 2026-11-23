import SwiftUI
import UIKit

/// App-level bookkeeping for the playback on screen: when the system Picture in Picture window may open by itself, and
/// how a playback that leaves the screen is torn down.
///
/// **Picture in Picture** is automatic only — the window opens when the app goes to the background while a video plays
/// (`canStartPictureInPictureAutomaticallyFromInline`), and tapping its restore button just returns to the page that is
/// already there. There is no button for it. The policy is off wherever the app promises the picture is hidden (Privacy
/// Mode, App Lock), while glasses are connected, and during slow-mo.
///
/// **Teardown order** (`retire`): silence at once → close any PiP window → after the transition (and never in the middle
/// of a scroll) `model.stop()` → the engine hands its `AVPlayer` stack to `PlayerGraveyard` → released off the main
/// thread. Heavy work therefore never runs during a dismiss animation or the first flick after it.
///
/// Rule for every edit here: a model that leaves the screen MUST be stopped (via `retire`) — a model deallocated with an
/// `AVPlayer` time observer still attached traps.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    /// The page that is on screen right now.
    private struct Presented {
        let model: ScenePlayerModel
        let sceneID: String
    }

    /// A playback that has been silenced and waits for its teardown (`retire`).
    private struct Retirement {
        let model: ScenePlayerModel
        let sceneID: String
        let timer: Timer
    }

    private var presented: Presented?
    private var retiring: [ObjectIdentifier: Retirement] = [:]
    private var defaultsObserver: NSObjectProtocol?

    /// How long a retired playback waits before its teardown: longer than any push/pop animation.
    private static let teardownDelay: TimeInterval = 0.6

    private init() {
        // Privacy Mode and App Lock are plain defaults flipped from Settings: re-apply the window policy when they change.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPictureInPicture() }
        }
    }

    // MARK: - Picture in Picture policy

    /// Whether a window may open BY ITSELF when the app goes to the background. The system window can't be blurred or
    /// covered by our own privacy cover, so it stays off wherever the app promises the picture is hidden: Privacy Mode
    /// and App Lock — and while glasses are connected (they own the picture).
    static var automaticPictureInPictureAllowed: Bool {
        !Privacy.isOn
            && !UserDefaults.standard.bool(forKey: "appLockEnabled")   // the key `AppLock` and Settings use
            && !GlassesSession.shared.isConnected
    }

    /// Re-applies the window policy to the playback on screen. Cheap, and safe to call from anywhere: every write is
    /// guarded, so it never causes redundant updates.
    func syncPictureInPicture() {
        guard let model = presented?.model, let window = model.pictureInPicture else { return }
        // Slow-mo draws its smoothed frames in an overlay the system window can't show: no automatic window then.
        let allowed = Self.automaticPictureInPictureAllowed && !model.overlayActive
        if window.startsAutomatically != allowed { window.startsAutomatically = allowed }
        if Privacy.isOn, window.isActive { window.stop() }
    }

    // MARK: - Page lifecycle

    /// A page for `scene` appeared with `model`. Runs BEFORE `model.start`.
    func present(_ model: ScenePlayerModel, scene: StashScene) {
        presented = Presented(model: model, sceneID: scene.id)

        // This very page is back before its teardown fired (popped back from a pushed page): finish the stop now so the
        // page rebuilds the engine paused at the remembered spot, exactly as it always has.
        if let back = retiring.removeValue(forKey: ObjectIdentifier(model)) {
            back.timer.invalidate()
            back.model.stop()
        }
        // A rebuilt page (quality switch, download finished) replaces a retiring one for the same scene: nothing is
        // animating, and its stream would compete with the new one for the link — stop it now.
        for (key, old) in retiring where old.sceneID == scene.id {
            old.timer.invalidate()
            retiring[key] = nil
            old.model.stop()
        }
        syncPictureInPicture()
    }

    /// The page left the screen (popped, covered by a push, a tab switch, or rebuilt).
    func pageDisappeared(_ model: ScenePlayerModel, scene: StashScene) {
        if presented?.model === model { presented = nil }
        retire(model, sceneID: scene.id)
    }

    // MARK: - Teardown

    /// Ends a playback the screen has finished with — WITHOUT doing the heavy work while the user is looking.
    ///
    /// Playback goes silent at once (`quiesce`: audio can't linger and nothing can start behind the user's back), and a
    /// window left open is closed. The teardown proper — engine, on-device remux, scrub connections, the AVPlayer stack
    /// — waits `teardownDelay`, past the dismiss animation, on a DEFAULT-mode timer: the main run loop is in tracking
    /// mode while a scroll view is being dragged or is decelerating, so the timer cannot fire in the middle of a flick.
    /// Returning to the grid and flicking right away therefore stays at full frame rate. The last release of the
    /// `AVPlayer` itself happens off the main thread (`PlayerGraveyard`).
    private func retire(_ model: ScenePlayerModel, sceneID: String) {
        let key = ObjectIdentifier(model)
        guard retiring[key] == nil else { return }
        model.pictureInPicture?.stop()
        if let page = presented, page.sceneID == sceneID, page.model !== model {
            // Replaced by a rebuilt page for the same scene (nothing animating): no reason to wait.
            model.stop()
            return
        }
        model.quiesce()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.teardownDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishRetirement(key) }
        }
        retiring[key] = Retirement(model: model, sceneID: sceneID, timer: timer)
    }

    private func finishRetirement(_ key: ObjectIdentifier) {
        guard let retirement = retiring.removeValue(forKey: key) else { return }
        let began = ProcessInfo.processInfo.systemUptime
        retirement.model.stop()
        // Diagnostics (opt-in): how long the deferred teardown holds the main thread, so a surviving hitch can be pinned.
        let ms = Int(((ProcessInfo.processInfo.systemUptime - began) * 1000).rounded())
        RemoteLog.shared.event("player-teardown", [("scene", retirement.sceneID), ("mainMs", ms)])
    }

    // MARK: - Picture in Picture window events

    /// Events from a window that isn't the on-screen playback's (a torn-down engine's late callback) are ignored.
    private func isCurrent(_ window: PictureInPictureWindow) -> Bool {
        presented?.model.pictureInPicture === window
    }

    func pictureInPicturePossibleChanged(_ window: PictureInPictureWindow) {
        syncPictureInPicture()
    }

    /// The window's "restore" button: the page it came from is still up, so there is nothing to reopen.
    func restoreFromPictureInPicture(_ window: PictureInPictureWindow, completion: @escaping @Sendable (Bool) -> Void) {
        completion(isCurrent(window))
    }

    func pictureInPictureDidStop(_ window: PictureInPictureWindow, requested: Bool, restored: Bool) {
        guard !requested, !restored, isCurrent(window) else { return }
        // The window's own ✕, pressed while the app is away, pauses the video. With the app in front a window that
        // closes just hands the picture back to the player — nothing to pause.
        guard UIApplication.shared.applicationState == .background else { return }
        presented?.model.pause()
    }
}
