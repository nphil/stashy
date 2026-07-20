import Foundation

/// Reads the Stashy Companion plugin's served `playability.json` (written by the "Library Codec Report"
/// task) and caches it in memory. The plugin makes **zero** scene writes — no tags, no custom_fields, so
/// no `Scene.Update` hooks / queued Sync tasks — so this single HTTP-fetched file is how the app learns
/// each scene's playability, for two uses:
///  • **Smarter routing** — skip a doomed on-device remux on an Apple-undecodable file (4:2:2/4:4:4 HEVC
///    that reads as plain "hevc") and go straight to transcode/server.
///  • **Playability filter** — page the scene list by the direct-play / needs-transcode buckets.
/// Absent file ⇒ empty store ⇒ everything behaves exactly as before the plugin (routing unchanged, filter
/// row hidden). Fetched lazily and cached; refreshed at most every few minutes.
@MainActor @Observable
final class PlayabilityStore {
    static let shared = PlayabilityStore()
    private init() {}

    // Mirrors the plugin's per-scene entry in playability.json. Only `tier` (filter) and `needs_transcode`
    // (routing hint) are consumed today; the rest are decoded and retained for future use (e.g. an HDR
    // filter bucket) and cost nothing to keep.
    struct Info: Decodable, Sendable, Equatable {
        var tier: String = "remux"            // direct | remux | transcode
        var needs_transcode: Bool = false
        var direct_play: Bool = false
        var hdr: Bool = false
        var ten_bit: Bool = false
        var codec: String = ""
        var pix_fmt: String = ""
        // Resolution / fps / quality (plugin ≥0.1.22). Optional so older reports still decode; a scene
        // missing them is simply excluded from those filters (nil height / fps, "unknown" quality).
        var height: Int? = nil
        var fps: Double? = nil
        var quality: String = "unknown"
        var qscore: Double = 0        // codec-normalized bits-per-pixel (continuous), for Quality sort
    }

    private struct Payload: Decodable, Sendable { let scenes: [String: Info] }

    private(set) var scenes: [String: Info] = [:]
    private var lastFetch: Date?

    var isAvailable: Bool { !scenes.isEmpty }

    /// The continuous quality score (codec-normalized bits-per-pixel) for a scene, or 0 if unknown — used to
    /// sort a report-filtered list by Quality client-side.
    func qscore(_ id: String) -> Double { scenes[id]?.qscore ?? 0 }

    /// Routing hint: the plugin's ffprobe verdict that Apple can't decode this scene at all. Unknown ⇒ false
    /// ⇒ routing falls back to the codec-based heuristic (unchanged behaviour).
    func needsTranscode(_ id: String) -> Bool { scenes[id]?.needs_transcode ?? false }

    /// Scene IDs in a playability tier (`direct` / `remux` / `transcode`), numeric-ascending — used to page
    /// the filtered scene list.
    func ids(tier: String) -> [String] {
        scenes.filter { $0.value.tier == tier }
            .keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    /// Scene IDs matching ALL active report filters (playability tier ∩ min-resolution ∩ fps bucket ∩
    /// min-quality), numeric-ascending — used to page the filtered scene list.
    func matchingIDs(playability: Playability, resolution: ResolutionFilter,
                     fps: FPSFilter, quality: QualityFilter) -> [String] {
        scenes.filter { (_, info) in
            if let tier = playability.tier, info.tier != tier { return false }
            if let minH = resolution.minHeight, (info.height ?? 0) < minH { return false }
            if fps != .any, !fps.passes(info.fps) { return false }
            if let minRank = quality.minRank, QualityFilter.rank(info.quality) < minRank { return false }
            return true
        }
        .keys.sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
    }

    /// Reorder scene IDs by a report-derived sort key (resolution height / fps / quality score), applying
    /// direction, with a stable numeric-id tiebreak. Non-report sorts are returned unchanged.
    func ordered(_ ids: [String], by sort: SceneSort, direction: SortDirection) -> [String] {
        guard sort.isReportSort else { return ids }
        func key(_ id: String) -> Double {
            guard let info = scenes[id] else { return -1 }
            switch sort {
            case .resolution: return Double(info.height ?? 0)
            case .framerate: return info.fps ?? 0
            case .quality: return info.qscore
            default: return 0
            }
        }
        let asc = direction == .asc
        return ids.sorted { a, b in
            let ka = key(a), kb = key(b)
            if ka == kb { return (Int(a) ?? 0) < (Int(b) ?? 0) }
            return asc ? ka < kb : ka > kb
        }
    }

    /// Fetch the served file (skipped if fetched within ~5 min and already populated, unless `force`).
    /// Silent on any failure — the feature simply stays off. No auth beyond the Stash apikey.
    func refresh(serverURL: String, apiKey: String, force: Bool = false) async {
        if !force, isAvailable, let last = lastFetch, Date().timeIntervalSince(last) < 300 { return }
        guard var comps = URLComponents(string: "\(serverURL)/plugin/\(StashCompanion.pluginID)/assets/cache/playability.json") else { return }
        if !apiKey.isEmpty { comps.queryItems = [URLQueryItem(name: "apikey", value: apiKey)] }
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let payload = await Task.detached(priority: .utility) {
            try? JSONDecoder().decode(Payload.self, from: data)
        }.value
        guard let payload else { return }
        scenes = payload.scenes
        lastFetch = Date()
    }
}
