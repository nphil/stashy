import SwiftUI
import UIKit

/// The playback that outlives its screen — the mini player — and the bookkeeping behind Picture in Picture.
///
/// **Who owns the playback**
/// - A scene's `ScenePlayerModel` (engine, on-device remux, state) is still created by its page (`ScenePlayerView`).
/// - Minimising (the chevron, a swipe down, or starting Picture in Picture from the button) hands that SAME model to
///   `docked`. The page goes away WITHOUT stopping it; `MiniPlayerBar` re-parents the model's picture into a tile above
///   the tab bar and playback never notices.
/// - Expanding presents a cover whose fresh page ADOPTS the docked model (`adoptableModel`): same model, same engine,
///   no reload — the picture simply moves back.
/// - Every other way a playback ends (back, swipe-back, tab switch, the bar's ✕, another scene replacing it) goes
///   through `retire`.
///
/// **Teardown order** (`retire`): silence at once → close any PiP window → after the transition (and never in the middle
/// of a scroll) `model.stop()` → the engine hands its `AVPlayer` stack to `PlayerGraveyard` → released off the main
/// thread. Heavy work therefore never runs during a dismiss animation or the first flick after it.
///
/// Rule for every edit here: a model that leaves `docked` MUST be stopped (via `retire`) or handed to a page — a model
/// deallocated with an `AVPlayer` time observer still attached traps.
@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    /// A minimised playback: the model that keeps playing, plus what a page needs to be rebuilt around it.
    struct Docked: Identifiable {
        let id = UUID()
        let scene: StashScene
        let model: ScenePlayerModel
        /// The stream the model plays and the quality that picked it. A page adopts the model only when it would play
        /// the very same stream.
        let routeURL: URL
        let quality: ServerQuality
        /// False until the page has left (and again from the moment a page takes the playback back): the bar and the
        /// page can't both show the one layer view, and whichever grabs it too early blanks the other mid-animation.
        var showsPicture = false
    }

    /// What the app-root cover re-opens.
    struct Expansion: Identifiable {
        let id = UUID()
        let scene: StashScene
    }

    /// The page that is on screen right now and the stream it plays.
    private struct Presented {
        let model: ScenePlayerModel
        let scene: StashScene
        let routeURL: URL
        let quality: ServerQuality
    }

    /// A playback that has been silenced and waits for its teardown (`retire`).
    private struct Retirement {
        let model: ScenePlayerModel
        let sceneID: String
        let timer: Timer
    }

    /// The minimised playback, drawn by `MiniPlayerBar`.
    private(set) var docked: Docked?
    /// Drives the app-root cover that re-opens the docked scene's page.
    var expansion: Expansion?
    /// For the page's chrome button: Picture in Picture is possible (and allowed) for the page's playback / is open now.
    private(set) var pictureInPictureAvailable = false
    private(set) var pictureInPictureActive = false

    @ObservationIgnored private var presented: Presented?
    @ObservationIgnored private var retiring: [ObjectIdentifier: Retirement] = [:]
    /// Set by the chrome button just before it asks for a window, so `didStart` knows the user asked (and the page
    /// should dock). An AUTOMATIC start (the app backgrounding) never sets it: the page stays where it is.
    @ObservationIgnored private var userStartedPictureInPictureAt: Date?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    private static let dockAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86)
    /// How long a retired playback waits before its teardown: longer than any push/pop/cover animation.
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
    /// and App Lock — and while glasses are connected (they own the picture). A window the user opens deliberately
    /// with the button is still allowed under App Lock (never under Privacy Mode).
    static var automaticPictureInPictureAllowed: Bool {
        !Privacy.isOn
            && !UserDefaults.standard.bool(forKey: "appLockEnabled")   // the key `AppLock` and Settings use
            && !GlassesSession.shared.isConnected
    }

    // MARK: - Page ↔ bar

    /// The docked model a page for this scene and stream should take over, or nil for a fresh one. A pure lookup — a
    /// page's `init` runs on every parent update, so it must not change anything. A docked playback that has failed is
    /// never adopted: re-opening it builds a fresh model, which is the retry.
    func adoptableModel(sceneID: String, routeURL: URL) -> ScenePlayerModel? {
        guard let current = docked, current.scene.id == sceneID, current.routeURL == routeURL, !current.model.didFail else { return nil }
        return current.model
    }

    /// The quality the docked playback for this scene is on, so a re-opened page resolves the same stream.
    func dockedQuality(sceneID: String) -> ServerQuality? {
        guard let current = docked, current.scene.id == sceneID else { return nil }
        return current.quality
    }

    /// A page for `scene` appeared with `model` (which may be the docked model, adopted). Runs BEFORE `model.start`.
    func present(_ model: ScenePlayerModel, scene: StashScene, routeURL: URL, quality: ServerQuality) {
        presented = Presented(model: model, scene: scene, routeURL: routeURL, quality: quality)
        userStartedPictureInPictureAt = nil

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

        if let current = docked {
            if current.model === model {
                // Adopted: the page now owns the playback as it is.
                withAnimation(Self.dockAnimation) { docked = nil }
            } else {
                close()   // another scene (or another stream of this one) replaces the docked playback
            }
        }
        syncPictureInPicture()
    }

    /// The page left the screen (popped, covered by a push, a tab switch, a dismissed cover, or rebuilt).
    func pageDisappeared(_ model: ScenePlayerModel, scene: StashScene) {
        if docked?.model === model {
            docked?.showsPicture = true   // the page has left: the bar takes the picture and playback carries on
            return
        }
        if presented?.model === model { presented = nil }
        retire(model, sceneID: scene.id)
        syncPictureInPicture()
    }

    /// Minimise: the page's playback moves into the bar. The page pops itself (`ScenePlayerView` watches `docked`).
    func minimise(_ model: ScenePlayerModel, scene: StashScene, routeURL: URL, quality: ServerQuality) {
        // `docked?.model !== model`: a second tap (or a swipe landing as the first takes effect) must not pop the page twice.
        guard presented?.model === model, docked?.model !== model, !model.didFail, !GlassesSession.shared.isConnected else { return }
        withAnimation(Self.dockAnimation) {
            docked = Docked(scene: scene, model: model, routeURL: routeURL, quality: quality)
        }
    }

    /// The bar was tapped (or swiped up): bring the full player back.
    func expand() {
        openCover(stoppingPictureInPicture: true)
    }

    /// The bar's ✕ (or a replaced / closed-from-the-window playback): playback ends, the bar leaves.
    func close() {
        guard let gone = docked else { return }
        withAnimation(Self.dockAnimation) { docked = nil }
        retire(gone.model, sceneID: gone.scene.id)
        syncPictureInPicture()
    }

    /// Glasses own the picture while connected: pause what is docked (the bar hides meanwhile) and keep windows off.
    func glassesChanged(connected: Bool) {
        if connected, let current = docked { current.model.pause() }
        syncPictureInPicture()
    }

    @discardableResult
    private func openCover(stoppingPictureInPicture: Bool) -> Bool {
        if expansion != nil { return true }
        guard let current = docked, !GlassesSession.shared.isConnected else { return false }
        docked?.showsPicture = false
        if stoppingPictureInPicture { current.model.pictureInPicture?.stop() }
        expansion = Expansion(scene: current.scene)
        return true
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
        if let page = presented, page.scene.id == sceneID, page.model !== model {
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

    // MARK: - Picture in Picture

    /// The chrome button: close the window if it is open, otherwise open it (and dock the page once it is up).
    func togglePictureInPicture(_ model: ScenePlayerModel) {
        guard presented?.model === model, let window = model.pictureInPicture else { return }
        if window.isActive {
            window.stop()
        } else if window.isPossible, !Privacy.isOn {
            userStartedPictureInPictureAt = Date()
            window.start()
        }
    }

    /// Re-applies the window policy to the playbacks we own and refreshes the page button's mirrors. Cheap, and safe to
    /// call from anywhere: every write is guarded, so it never causes redundant updates.
    func syncPictureInPicture() {
        let privacy = Privacy.isOn
        let automatic = Self.automaticPictureInPictureAllowed
        for model in [docked?.model, presented?.model].compactMap({ $0 }) {
            guard let window = model.pictureInPicture else { continue }
            // Slow-mo draws its smoothed frames in an overlay the system window can't show: no automatic window then.
            let allowed = automatic && !model.overlayActive
            if window.startsAutomatically != allowed { window.startsAutomatically = allowed }
            if privacy, window.isActive { window.stop() }
        }
        let window = presented?.model.pictureInPicture
        let available = (window?.isPossible ?? false) && !privacy
        let active = window?.isActive ?? false
        if pictureInPictureAvailable != available { pictureInPictureAvailable = available }
        if pictureInPictureActive != active { pictureInPictureActive = active }
    }

    /// The model a window belongs to, if we still own it. Events from anything else (a torn-down engine's late callback)
    /// are ignored.
    private func owner(of window: PictureInPictureWindow) -> ScenePlayerModel? {
        [docked?.model, presented?.model].compactMap { $0 }.first { $0.pictureInPicture === window }
    }

    /// Whether the user asked for the window that just opened (see `userStartedPictureInPictureAt`).
    private func consumeUserStart() -> Bool {
        defer { userStartedPictureInPictureAt = nil }
        guard let at = userStartedPictureInPictureAt else { return false }
        return Date().timeIntervalSince(at) < 5
    }

    func pictureInPicturePossibleChanged(_ window: PictureInPictureWindow) {
        guard owner(of: window) != nil else { return }
        syncPictureInPicture()
    }

    func pictureInPictureDidStart(_ window: PictureInPictureWindow) {
        syncPictureInPicture()
        guard consumeUserStart(), let page = presented, page.model.pictureInPicture === window else { return }
        // The user asked for the window from the page: the video now lives in it, so the page steps aside (the bar
        // takes over once the window closes or is restored).
        minimise(page.model, scene: page.scene, routeURL: page.routeURL, quality: page.quality)
    }

    func pictureInPictureFailedToStart(_ window: PictureInPictureWindow) {
        userStartedPictureInPictureAt = nil
        syncPictureInPicture()
    }

    /// The window's "restore" button: bring the full player back, then tell the system the UI is ready.
    func restoreFromPictureInPicture(_ window: PictureInPictureWindow, completion: @escaping @Sendable (Bool) -> Void) {
        guard let model = owner(of: window) else {
            completion(false)
            return
        }
        if presented?.model === model {
            completion(true)   // the page is already up: nothing to reopen
            return
        }
        guard docked?.model === model, openCover(stoppingPictureInPicture: false) else {
            completion(false)
            return
        }
        // The system animates the window into the player's layer once told the UI is ready: give the cover a moment to
        // put its picture on screen first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            completion(true)
        }
    }

    func pictureInPictureDidStop(_ window: PictureInPictureWindow, requested: Bool, restored: Bool) {
        syncPictureInPicture()
        guard !requested, !restored, let model = owner(of: window) else { return }
        // The window's own ✕, pressed while the app is away, ends the playback. With the app in front a window that
        // closes just hands the picture back to the player — nothing to end.
        guard UIApplication.shared.applicationState == .background else { return }
        if docked?.model === model { close() } else { model.pause() }
    }
}
