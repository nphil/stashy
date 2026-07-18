import Foundation

/// Reads the Stashy Companion plugin's served `vmaf-map.json` (written by the "Compute VMAF Map" task) and
/// caches it in memory. The map stores, per scene per output resolution, the VMAF-optimal CRF **and** the
/// per-preset target **bitrate** (bits/sec) that hit each quality target on the server's encoder.
///
/// We consume only the bitrate here: an **on-device** transcode has no CRF knob (VideoToolbox is
/// average-bitrate controlled), so instead of re-running any analysis on the phone we feed the server's
/// already-computed, perceptually-calibrated bitrate straight into the local encoder. The heavy VMAF work
/// stays on the server (P40); the phone just consumes a number.
///
/// Absent file / unmapped scene / missing bitrates ⇒ `targetBitrate` returns nil ⇒ the transcoder falls
/// back to its existing preset bitrate ladder (exactly the pre-map behaviour). Fetched lazily and cached;
/// refreshed at most every few minutes, alongside `PlayabilityStore`.
@MainActor @Observable
final class VmafMapStore {
    static let shared = VmafMapStore()
    private init() {}

    // Only `bitrates` is consumed; the rest of each res entry (crf/vmaf/curve/…) is ignored. `bitrates`
    // is keyed by preset name ("high"/"balanced"/"small") → bits per second.
    private struct ResEntry: Decodable { var bitrates: [String: Int]? }
    private struct SceneEntry: Decodable { var res: [String: ResEntry]? }
    private struct Payload: Decodable { var scenes: [String: SceneEntry]? }

    private var scenes: [String: SceneEntry] = [:]
    private var lastFetch: Date?

    var isAvailable: Bool { !scenes.isEmpty }

    /// The server-calibrated HEVC target bitrate (bits/sec) for a scene at a given OUTPUT height and quality
    /// preset, or nil if unmapped. `outputHeight` must be the actual encoded height (Original ⇒ source
    /// height) — the map keys entries by even output height, matching the plugin's `_out_height`. The stored
    /// bitrates are HEVC (the map's encoder), so callers must only apply this to an HEVC on-device encode.
    func targetBitrate(sceneID: String, outputHeight: Int, quality: TranscodeQuality) -> Int? {
        guard outputHeight > 0, let res = scenes[sceneID]?.res else { return nil }
        let key = String(outputHeight - outputHeight % 2)              // even height, e.g. "1080"
        guard let bitrates = res[key]?.bitrates else { return nil }
        let preset: String
        switch quality {
        case .high: preset = "high"
        case .medium: preset = "balanced"
        case .low: preset = "small"
        }
        guard let bps = bitrates[preset], bps > 0 else { return nil }
        return bps
    }

    /// Fetch the served map (skipped if fetched within ~5 min and already populated, unless `force`).
    /// Silent on any failure — the feature simply stays off. No auth beyond the Stash apikey.
    func refresh(serverURL: String, apiKey: String, force: Bool = false) async {
        if !force, isAvailable, let last = lastFetch, Date().timeIntervalSince(last) < 300 { return }
        guard var comps = URLComponents(string: "\(serverURL)/plugin/\(StashCompanion.pluginID)/assets/cache/vmaf-map.json") else { return }
        if !apiKey.isEmpty { comps.queryItems = [URLQueryItem(name: "apikey", value: apiKey)] }
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        scenes = payload.scenes ?? [:]
        lastFetch = Date()
    }
}
