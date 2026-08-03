import SwiftUI

/// Handles to the phone tree's shared services, registered from ContentView so the external-scene
/// hosting trees use the SAME instances. This is mandatory, not hygiene: the `\.imageCache` environment
/// default is a DIFFERENT ImageCache instance from the one StashyApp injects — an unregistered glasses
/// tree would silently double-decode and double-fetch every poster.
struct GlassesEnv {
    let appState: AppState
    let downloads: DownloadManager
    let edits: LibraryEdits
    let imageCache: ImageCache
}

/// The glasses-first brain: what the glasses show (browse rails / playback) and what the phone remote
/// drives. One instance owns the focus cursor, the rail data, and — while in glasses-first playback —
/// the `ScenePlayerModel` itself (no phone view involved; the engine renders to the external layer).
@MainActor
@Observable
final class GlassesCoordinator {
    static let shared = GlassesCoordinator()
    private init() {}

    enum Mode { case browse, playing }

    struct Rail: Identifiable {
        let id: String
        let title: String
        var scenes: [StashScene]
    }

    // MARK: - State

    private(set) var mode: Mode = .browse
    private(set) var rails: [Rail] = []
    private(set) var railIndex = 0
    private(set) var itemIndex = 0
    /// Per-rail focus memory (tvOS behaviour): moving between rails returns to where you were.
    /// Keyed rail-id → SCENE id, never an ordinal: a rail's contents are replaced mid-session (the
    /// offline subset is swapped for the full server resolution), so a remembered index addresses a
    /// different video afterwards. Observable because the wall reads it to park unfocused rails.
    private var focusMemory: [String: String] = [:]
    /// Which rail playback was launched from, so BROWSE returns to that shelf and not merely to the
    /// first one that happens to contain the scene.
    @ObservationIgnored private var playedFromRailID: String?

    /// The glasses-first player. Owned HERE — there is no phone player view in this mode.
    private(set) var player: ScenePlayerModel?
    private(set) var playingScene: StashScene?

    /// True after EXIT: the phone app is usable, the takeover window is down, the return pill shows.
    var takeoverSuppressed = false

    /// Live scrub feedback for the glasses OSD (nil when not scrubbing).
    var scrubTarget: TimeInterval?
    var scrubTier = 0
    /// Transient ±10 s skip accumulator for the OSD badge (seconds, signed; nil = no badge).
    var skipBadge: Int?
    /// Remote hold-to-exit progress (0…1) echoed on the glasses, nil when idle.
    var exitProgress: Double?
    /// Volume pill visibility pulse: bumped on every volume change so the OSD can show-then-fade.
    var volumePulse = 0

    /// Server-rail fetch, kept so disconnect can cancel it.
    @ObservationIgnored private var railTask: Task<Void, Never>?

    /// Scrub-preview sprites for the playing scene (10-foot Netflix-style peek). Local-first.
    @ObservationIgnored private(set) var sprites = SpriteThumbnails()
    /// Playback speed ladder driven by the remote's vertical drag. Index into `Self.speedRungs`.
    private(set) var speedIndex = 2
    static let speedRungs: [Double] = [0.25, 0.5, 1.0, 1.5, 2.0]
    /// Transient speed pill pulse for the OSD.
    var speedPulse = 0
    /// Pinch zoom: 1…4 scale + pan, applied to the glasses video container.
    private(set) var zoomScale: CGFloat = 1
    private(set) var zoomOffset: CGPoint = .zero
    var isZoomed: Bool { zoomScale > 1.02 }

    var focusedScene: StashScene? {
        guard rails.indices.contains(railIndex) else { return nil }
        let rail = rails[railIndex]
        guard rail.scenes.indices.contains(itemIndex) else { return nil }
        return rail.scenes[itemIndex]
    }

    // MARK: - Volume (owner decision 2026-08-03: restore last glasses volume, persistently)

    private static let volumeKey = "glassesVolume"
    /// Last volume used on the glasses. First-ever glasses playback lands at a modest 40% — silence
    /// looks broken on a cinema screen and full volume into the Harman speakers is the wrong surprise.
    static var storedVolume: Double {
        get {
            let v = UserDefaults.standard.double(forKey: volumeKey)
            return v > 0 ? min(1, v) : 0.4
        }
        set { if newValue > 0 { UserDefaults.standard.set(min(1, newValue), forKey: volumeKey) } }
    }

    // MARK: - Recently Played (persisted, most-recent-first, capped)

    private static let historyKey = "glassesPlayHistory"
    static func recordPlay(_ sceneID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        ids.removeAll { $0 == sceneID }
        ids.insert(sceneID, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(20)), forKey: historyKey)
    }
    static var playHistory: [String] { UserDefaults.standard.stringArray(forKey: historyKey) ?? [] }

    // MARK: - Session lifecycle

    /// Called when the glasses connect (from the takeover driver) — load rails and reset to browse.
    func sessionBegan() {
        takeoverSuppressed = false
        mode = .browse
        refreshRails()
    }

    /// Cable pulled or session torn down: stop playback, cancel loads. The phone app is untouched —
    /// its tree was alive beneath the takeover window the whole time.
    func sessionEnded() {
        railTask?.cancel()
        railTask = nil
        stopPlayback()
        takeoverSuppressed = false
        rails = []
        focusMemory.removeAll()
        railIndex = 0
        itemIndex = 0
    }

    // MARK: - Rails

    /// Netflix-shaped wall (owner spec): Recently Played on top, Recently Added underneath, Downloaded
    /// last (the offline safety shelf). Downloaded + any cached history paint instantly; server rails
    /// fill in. Rail ORDER is fixed regardless of arrival order.
    func refreshRails() {
        guard let env = GlassesSession.shared.env else { return }
        let downloaded = env.edits.visible(
            env.downloads.items.filter { $0.state == .completed }.compactMap(\.scene))
        // Instant first paint: history resolved against what's on disk, full resolution follows.
        let history = Self.playHistory
        let offlineHistory = history.compactMap { id in downloaded.first { $0.id == id } }
        upsertRail(id: "played", title: "Recently Played", scenes: offlineHistory)
        upsertRail(id: "downloads", title: "Downloaded", scenes: downloaded)
        prefetchPosters(for: Array((offlineHistory + downloaded).prefix(10)))

        // Server rails: Recently ADDED (created_at desc — a stable shelf, not the phone's browse sort)
        // and the full history resolution by ids. Never self-terminates (the jobs-panel rule).
        railTask?.cancel()
        railTask = Task { @MainActor [weak self] in
            var delay: Double = 2
            while !Task.isCancelled {
                guard let self, GlassesSession.shared.isConnected else { return }
                guard let client = GlassesSession.shared.env?.appState.client else {
                    try? await Task.sleep(for: .seconds(delay)); continue
                }
                do {
                    let added = try await client.findScenes(
                        SceneQuery(sort: .createdAt, direction: .desc), page: 1, perPage: 25)
                    let visibleAdded = (GlassesSession.shared.env?.edits.visible(added.scenes)) ?? added.scenes
                    let ids = Self.playHistory
                    let playedFull = ids.isEmpty ? [] : (try await client.findScenesByIDs(ids))
                    let visiblePlayed = (GlassesSession.shared.env?.edits.visible(playedFull)) ?? playedFull
                    // ONE StashScene per id across the whole wall. The Downloaded rail is built from
                    // frozen sidecar snapshots whose `paths.screenshot` carries a stale `?t=<updated_at>`
                    // cache-buster; ImageCache keys on the full URL, so the same scene appearing in two
                    // rails would fetch twice, pop in at different times, and can genuinely wear two
                    // different covers. Server copies win.
                    var fresh: [String: StashScene] = [:]
                    for s in visibleAdded + visiblePlayed { fresh[s.id] = s }
                    let currentDownloads = self.rails.first { $0.id == "downloads" }?.scenes ?? []
                    self.upsertRail(id: "played", title: "Recently Played", scenes: visiblePlayed)
                    self.upsertRail(id: "added", title: "Recently Added", scenes: visibleAdded)
                    self.upsertRail(id: "downloads", title: "Downloaded",
                                    scenes: currentDownloads.map { fresh[$0.id] ?? $0 })
                    self.prefetchPosters(for: Array((visiblePlayed + visibleAdded).prefix(12)))
                    return
                } catch {
                    RemoteLog.shared.event("glasses-rail", [("fetch", "retry"),
                                                            ("err", String("\(error)".prefix(60)))])
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(30, delay * 1.6)
                }
            }
        }
    }

    /// Insert/update a rail while preserving the FIXED order played → added → downloads. Empty rails
    /// are removed entirely (no dead shelf headers).
    private func upsertRail(id: String, title: String, scenes: [StashScene]) {
        // Focus follows the rail's IDENTITY, not its position: a server rail landing ABOVE the one
        // being browsed must not silently shift the wearer onto a different shelf.
        let focusedID = rails.indices.contains(railIndex) ? rails[railIndex].id : nil
        // …and the CURSOR follows the SCENE, not the ordinal. The "played" rail is guaranteed to be
        // replaced mid-session (offline subset → full server resolution), so a preserved index lands
        // the ring, the title block and playFocused() on a different video with no input from the
        // wearer. That is the "carousel doesn't match" complaint in its second form.
        let focusedSceneID = focusedScene?.id
        let order = ["played", "added", "downloads"]
        rails.removeAll { $0.id == id }
        if !scenes.isEmpty {
            let rail = Rail(id: id, title: title, scenes: scenes)
            let pos = rails.firstIndex { (order.firstIndex(of: $0.id) ?? 99) > (order.firstIndex(of: id) ?? 99) }
            rails.insert(rail, at: pos ?? rails.count)
        }
        if let focusedID, let idx = rails.firstIndex(where: { $0.id == focusedID }) {
            railIndex = idx
        }
        if let focusedSceneID, rails.indices.contains(railIndex),
           let i = rails[railIndex].scenes.firstIndex(where: { $0.id == focusedSceneID }) {
            itemIndex = i
        }
        clampFocus()
    }

    /// Where an UNFOCUSED rail should be parked. Without this a rail sits at index 0, which — with a
    /// centred focus slot — renders one lone card mid-screen with 768 pt of black beside it.
    func displayIndex(for rail: Rail) -> Int {
        if rails.indices.contains(railIndex), rails[railIndex].id == rail.id { return itemIndex }
        return rememberedIndex(in: rail)
    }

    /// Memory-only lookup — must NOT consult `railIndex`, because `moveFocus` calls it immediately
    /// after moving the cursor onto the target rail (at which point the "is focused" test is true
    /// and would just hand back the outgoing rail's index).
    private func rememberedIndex(in rail: Rail) -> Int {
        guard let sceneID = focusMemory[rail.id],
              let i = rail.scenes.firstIndex(where: { $0.id == sceneID }) else { return 0 }
        return i
    }

    private func prefetchPosters(for scenes: [StashScene]) {
        guard let env = GlassesSession.shared.env else { return }
        let apiKey = env.appState.client?.apiKey ?? ""
        let urls = scenes.prefix(8).compactMap { $0.thumbnailURL(apiKey: apiKey) }
        // Same maxPixel as the phone grid so cache entries are shared, not duplicated. ImageCache is
        // an ACTOR — the hop must be explicit from this @MainActor context.
        if !urls.isEmpty { Task { await env.imageCache.prefetch(urls: urls, maxPixel: 600) } }
    }

    private func clampFocus() {
        railIndex = min(railIndex, max(0, rails.count - 1))
        let count = rails.indices.contains(railIndex) ? rails[railIndex].scenes.count : 0
        itemIndex = min(itemIndex, max(0, count - 1))
    }

    // MARK: - Focus (driven by the remote)

    /// One focus step. Returns false when the move hit an end (the remote double-ticks a hard stop).
    @discardableResult
    func moveFocus(dx: Int, dy: Int) -> Bool {
        guard mode == .browse, !rails.isEmpty else { return false }
        if dy != 0 {
            let target = railIndex + dy
            guard rails.indices.contains(target) else { return false }
            if rails[railIndex].scenes.indices.contains(itemIndex) {
                focusMemory[rails[railIndex].id] = rails[railIndex].scenes[itemIndex].id
            }
            railIndex = target
            itemIndex = rememberedIndex(in: rails[target])
            return true
        }
        if dx != 0 {
            let target = itemIndex + dx
            guard rails[railIndex].scenes.indices.contains(target) else { return false }
            itemIndex = target
            return true
        }
        return false
    }

    // MARK: - Playback (glasses-first: the coordinator owns the model)

    func playFocused() {
        guard let scene = focusedScene else { return }
        play(scene)
    }

    func play(_ scene: StashScene) {
        guard let env = GlassesSession.shared.env else { return }
        guard let route = PlaybackRouteResolver.resolve(scene: scene, quality: .auto,
                                                        client: env.appState.client,
                                                        downloads: env.downloads) else {
            RemoteLog.shared.event("glasses-play", [("item", scene.id), ("route", "nil")])
            return
        }
        playedFromRailID = rails.indices.contains(railIndex) ? rails[railIndex].id : nil
        stopPlayback()
        let model = ScenePlayerModel(route: route, sceneID: scene.id)
        model.glassesActive = true          // AI slow-mo hosts on the glasses overlay (see ScenePlayerModel.glassesActive)
        player = model
        playingScene = scene
        mode = .playing
        model.start(autoplay: true)
        Self.recordPlay(scene.id)
        promotePlayed(scene)
        resetZoom()
        speedIndex = 2
        // Scrub-preview sprites, local-first (downloaded scenes have them on disk).
        sprites = SpriteThumbnails()
        if let vtt = env.downloads.localVTT(sceneID: scene.id) ?? scene.vttURL(apiKey: env.appState.client?.apiKey ?? ""),
           let sheet = env.downloads.localSprite(sceneID: scene.id) ?? scene.spriteURL(apiKey: env.appState.client?.apiKey ?? "") {
            let cache = env.imageCache
            let sprites = self.sprites
            Task { await sprites.load(vttURL: vtt, spriteURL: sheet, imageCache: cache) }
        }
        // Owner decision: glasses playback restores the last glasses volume (models start muted by
        // design — that rule is the PHONE's; the wearer expects sound in their ears).
        model.setVolume(Self.storedVolume)
        rehost()
        armRehost()
        // Cable pull while we own playback: pause explicitly and unconditionally — the OS route-loss
        // auto-pause does NOT fire when audio is on AirPods or the volume is 0. The takeover window
        // unmounts off the isConnected flip; the model is kept, paused, for the return pill.
        GlassesSession.shared.onDisconnect = { [weak self] in
            self?.player?.pause()
        }
        RemoteLog.shared.event("glasses-play", [("item", scene.id), ("engine", "\(route.engine)")])
    }

    /// (Re-)attach the player's external layer to the glasses. Called after start and again on every
    /// readiness flip — an engine rebuild (HLS fallback, far-seek reinit) kills the external view.
    func rehost() {
        guard let player else { return }
        GlassesSession.shared.setVideo(player.externalRenderView)
    }

    /// Re-arm `rehost()` on every readiness flip, owned HERE rather than in the phone remote's body.
    /// `externalRenderView` is vended by the engine and replaced on every rebuild (HLS fallback,
    /// far-seek reinit); the remote's `.onChange` dies with the takeover window, so after EXIT a
    /// mid-playback fallback left the glasses black with nothing able to recover them.
    /// Same self-re-arming pattern as `GlassesRootController.armLockObservation`.
    private func armRehost() {
        withObservationTracking { _ = player?.isReady } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.player != nil else { return }
                self.rehost()
                self.armRehost()
            }
        }
    }

    /// Back to the rails (BROWSE chip, or end-of-video). Focus lands on the scene that was playing —
    /// on the rail it was LAUNCHED from. Searching top-down instead dropped a wearer who started from
    /// Downloaded two shelves up, because the same scene also sits in Recently Played.
    func returnToBrowse() {
        if let played = playingScene {
            let preferred = playedFromRailID.flatMap { id in rails.firstIndex { $0.id == id } }
            let searchOrder = (preferred.map { [$0] } ?? []) + rails.indices.filter { $0 != preferred }
            for r in searchOrder {
                if let i = rails[r].scenes.firstIndex(where: { $0.id == played.id }) {
                    railIndex = r; itemIndex = i; break
                }
            }
        }
        playedFromRailID = nil
        stopPlayback()
    }

    /// Move `scene` to the head of Recently Played immediately. `refreshRails()` runs ONLY on the
    /// cable-connect edge, so without this the shelf stays byte-identical for the whole session —
    /// you watch something, press Browse, and the wall disagrees with what you just did.
    private func promotePlayed(_ scene: StashScene) {
        var played = rails.first { $0.id == "played" }?.scenes ?? []
        played.removeAll { $0.id == scene.id }
        played.insert(scene, at: 0)
        upsertRail(id: "played", title: "Recently Played", scenes: played)
    }

    private func stopPlayback() {
        resetZoom()
        player?.stop()
        player = nil
        playingScene = nil
        scrubTarget = nil
        skipBadge = nil
        GlassesSession.shared.setVideo(nil)
        GlassesSession.shared.onDisconnect = nil
        mode = .browse
    }

    // MARK: - Remote transport (playback mode)

    func togglePlayPause() { player?.togglePlayPause() }

    func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, min(player.duration > 0 ? player.duration - 0.3 : player.currentTime + seconds,
                                player.currentTime + seconds))
        skipBadge = (skipBadge ?? 0) + Int(seconds)
        player.seek(to: target)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            self?.skipBadge = nil
        }
    }

    func toggleMute() {
        player?.toggleMute()
        volumePulse += 1
    }

    /// One rung up/down the speed ladder [0.25, 0.5, 1, 1.5, 2]. Slow rungs get AI interpolation
    /// automatically when the AI slow-mo toggle is on — the runner hosts its frames on the glasses.
    /// Returns false at ladder ends (remote double-ticks).
    @discardableResult
    func stepSpeed(_ delta: Int) -> Bool {
        guard let player else { return false }
        let target = speedIndex + delta
        guard Self.speedRungs.indices.contains(target) else { return false }
        speedIndex = target
        player.setPlaybackRate(Self.speedRungs[target])
        speedPulse += 1
        return true
    }

    /// Temporary 2× while held (long-press); restores the ladder rung on release.
    func holdSpeed(_ holding: Bool) {
        guard let player else { return }
        player.setPlaybackRate(holding ? 2.0 : Self.speedRungs[speedIndex])
        speedPulse += 1
    }

    // MARK: - Zoom (pinch on the remote, rendered on the glasses)

    func setZoom(scale: CGFloat, offset: CGPoint) {
        zoomScale = max(1, min(4, scale))
        // Clamp the pan so the video can't be pushed fully off-screen: at scale s the content half-
        // overhang is (s-1)/2 of the 1920×1080 canvas.
        let maxX = (zoomScale - 1) * 960, maxY = (zoomScale - 1) * 540
        zoomOffset = CGPoint(x: max(-maxX, min(maxX, offset.x)),
                             y: max(-maxY, min(maxY, offset.y)))
        if zoomScale <= 1.02 { zoomOffset = .zero }
        GlassesSession.shared.setZoom(scale: zoomScale, offset: zoomOffset)
    }

    func resetZoom() { setZoom(scale: 1, offset: .zero) }

    /// Double-tap parity with Apple Photos: toggle fit ↔ 2.4× centred.
    func toggleZoom() {
        setZoom(scale: isZoomed ? 1 : 2.4, offset: .zero)
    }
}
