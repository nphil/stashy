import Foundation

/// Reads the Companion plugin's served `loudness.json` (per-scene integrated loudness, EBU R128) and turns
/// it into a per-scene playback gain, so scene-to-scene volume is consistent without riding the slider.
///
/// **Attenuation-only** for now: loud scenes are pulled DOWN toward a reference; quiet scenes are left alone
/// (never boosted — so nothing clips and no noise/hiss is amplified). That lets the gain be folded straight
/// into the player's output volume (a value ≤ 1), with no `AVAudioMix`/track-loading. Absent file ⇒ gain 1
/// everywhere ⇒ behaviour is exactly as before. Fetched lazily and cached, refreshed at most every few min —
/// mirrors `PlayabilityStore`.
@MainActor @Observable
final class LoudnessStore {
    static let shared = LoudnessStore()
    private init() {}

    /// Target integrated loudness (LUFS). Scenes louder than this are attenuated toward it; quieter ones are
    /// untouched. −18 is a middle-of-the-road reference (between EBU −23 and streaming −14/−16).
    static let targetLUFS: Double = -18

    // `i` = integrated loudness (LUFS), `tp` = true peak (dBTP). Only `i` is used today; `tp` is retained for
    // a future boost-capable mode (which would need it to avoid clipping) and costs nothing to keep.
    // `i` = integrated loudness (LUFS, required — gain is meaningless without it). `tp` = true peak (dBTP),
    // Optional so a report that ever omits it still decodes (synthesized Decodable throws on a missing
    // NON-optional key, which would blank the whole map). `tp` is unused today; kept for a future
    // boost-capable mode that needs it to avoid clipping.
    struct Info: Decodable, Sendable, Equatable { var i: Double; var tp: Double? = nil }
    private struct Payload: Decodable, Sendable { let scenes: [String: Info] }

    private(set) var scenes: [String: Info] = [:]
    private var lastFetch: Date?

    var isAvailable: Bool { !scenes.isEmpty }

    /// Linear output-volume multiplier (0…1) that normalizes this scene to `target`. Attenuation-only:
    /// the gain is never above 1, so folding it into the player volume can't clip. Unknown/silent ⇒ 1.
    func gain(for id: String, target: Double = LoudnessStore.targetLUFS) -> Float {
        guard let i = scenes[id]?.i, i > -70 else { return 1 }   // no data / silent → leave it alone
        let gainDB = min(0, target - i)                          // only ever pull loud scenes DOWN
        return Float(pow(10.0, max(-24, gainDB) / 20.0))         // floor the attenuation for safety
    }

    /// Fetch the served file (skipped if fetched within ~5 min and already populated, unless `force`).
    /// Silent on any failure — the feature simply stays off. No auth beyond the Stash apikey.
    func refresh(serverURL: String, apiKey: String, force: Bool = false) async {
        if !force, isAvailable, let last = lastFetch, Date().timeIntervalSince(last) < 300 { return }
        guard var comps = URLComponents(string: "\(serverURL)/plugin/\(StashCompanion.pluginID)/assets/cache/loudness.json") else { return }
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
