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
    @ObservationIgnored private var focusMemory: [String: Int] = [:]

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

    func refreshRails() {
        guard let env = GlassesSession.shared.env else { return }
        // Downloaded first: paints instantly from disk, works with no server. Through `edits.visible`
        // so locally-deleted scenes don't come back from the dead on the big screen.
        let downloaded = env.edits.visible(
            env.downloads.items.filter { $0.state == .completed }.compactMap(\.scene))
        var next: [Rail] = []
        if !downloaded.isEmpty { next.append(Rail(id: "downloads", title: "Downloaded", scenes: downloaded)) }
        rails = next
        clampFocus()
        prefetchPosters(for: downloaded)

        // Recent: a FIXED default query (date desc), deliberately not the phone's persisted browse sort —
        // a 10-foot shelf must be deterministic. Retry loop never self-terminates (the jobs-panel rule):
        // gate on the full condition set, back off, keep trying until disconnect.
        railTask?.cancel()
        railTask = Task { @MainActor [weak self] in
            var delay: Double = 2
            while !Task.isCancelled {
                guard let self, GlassesSession.shared.isConnected else { return }
                guard let client = GlassesSession.shared.env?.appState.client else {
                    try? await Task.sleep(for: .seconds(delay)); continue
                }
                do {
                    let result = try await client.findScenes(SceneQuery(), page: 1, perPage: 25)
                    let scenes = (GlassesSession.shared.env?.edits.visible(result.scenes)) ?? result.scenes
                    self.setRecentRail(scenes)
                    self.prefetchPosters(for: Array(scenes.prefix(8)))
                    return
                } catch {
                    RemoteLog.shared.event("glasses-rail", [("recent", "retry"),
                                                            ("err", String("\(error)".prefix(60)))])
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(30, delay * 1.6)
                }
            }
        }
    }

    private func setRecentRail(_ scenes: [StashScene]) {
        guard !scenes.isEmpty else { return }
        if let idx = rails.firstIndex(where: { $0.id == "recent" }) {
            rails[idx].scenes = scenes
        } else {
            rails.append(Rail(id: "recent", title: "Recent", scenes: scenes))
        }
        clampFocus()
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
            focusMemory[rails[railIndex].id] = itemIndex
            railIndex = target
            itemIndex = min(focusMemory[rails[target].id] ?? 0, max(0, rails[target].scenes.count - 1))
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
        stopPlayback()
        let model = ScenePlayerModel(route: route, sceneID: scene.id)
        model.glassesActive = true          // slow-mo stays gated off in glasses mode
        player = model
        playingScene = scene
        mode = .playing
        model.start(autoplay: true)
        // Owner decision: glasses playback restores the last glasses volume (models start muted by
        // design — that rule is the PHONE's; the wearer expects sound in their ears).
        model.setVolume(Self.storedVolume)
        rehost()
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

    /// Back to the rails (BROWSE chip, or end-of-video). Focus lands on the scene that was playing.
    func returnToBrowse() {
        if let played = playingScene {
            for (r, rail) in rails.enumerated() {
                if let i = rail.scenes.firstIndex(where: { $0.id == played.id }) {
                    railIndex = r; itemIndex = i; break
                }
            }
        }
        stopPlayback()
    }

    private func stopPlayback() {
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

    func setVolume(_ v: Double) {
        guard let player else { return }
        player.setVolume(v)
        if v > 0 { Self.storedVolume = v }
        volumePulse += 1
    }

    func toggleMute() {
        player?.toggleMute()
        volumePulse += 1
    }
}
