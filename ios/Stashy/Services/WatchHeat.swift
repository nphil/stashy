import Foundation

/// Local watch-heat ("most replayed") tracking — the data source for the YouTube-style heat curve on the
/// scrubber. Zero server involvement, fully private: per scene, watched playback is accumulated into a
/// fixed number of duration-relative **bins** (media-seconds watched at each position), so re-watched
/// stretches grow hot. Persisted to one JSON file in Application Support; keys are scoped by the current
/// server's host so two servers' scene IDs can't collide.
///
/// Feeding: `ScenePlayerModel`'s time tick calls `record` with the small media delta of natural forward
/// playback (seeks/scrubs are guarded out by the caller's delta window). Reading: the player controls
/// fetch `curve(sceneID:)` per body evaluation — a dictionary lookup plus a 100-element pass, cheap
/// enough to recompute at tick cadence with no caching/observability machinery.
@MainActor
final class WatchHeat {
    static let shared = WatchHeat()
    /// Bins per scene. 100 ≈ one bin per 0.6s-worth of scrubber width on an iPhone — plenty for a curve.
    static let binCount = 100
    /// The Settings toggle gating both collection and display (default ON).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "watchHeatEnabled") == nil
            || UserDefaults.standard.bool(forKey: "watchHeatEnabled")
    }

    private var data: [String: [Double]] = [:]   // "host|sceneID" → binCount accumulated seconds
    private var lastSave = Date.distantPast
    private var dirty = false
    /// The current server host, cached once per launch (Keychain reads aren't free and record() runs
    /// at tick cadence; server switches are rare and take a reconnect anyway).
    private lazy var serverHost: String = {
        guard let url = KeychainService.read("serverURL"),
              let host = URLComponents(string: url)?.host else { return "server" }
        return host
    }()

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stashy", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("watch-heat.json")
    }

    private init() {
        if let raw = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: [Double]].self, from: raw) {
            data = decoded
        }
    }

    private func key(_ sceneID: String) -> String { "\(serverHost)|\(sceneID)" }

    /// Accumulate `seconds` of watched playback at `position` of a `duration`-long scene.
    func record(sceneID: String, position: Double, duration: Double, seconds: Double) {
        guard Self.isEnabled, duration > 10, seconds > 0, position >= 0, position <= duration else { return }
        let k = key(sceneID)
        var bins = data[k] ?? Array(repeating: 0, count: Self.binCount)
        guard bins.count == Self.binCount else { return }   // defensive against a corrupt file entry
        let idx = min(Self.binCount - 1, max(0, Int(position / duration * Double(Self.binCount))))
        bins[idx] += seconds
        data[k] = bins
        saveSoon()
    }

    /// The normalised (0…1), outlier-capped, lightly-smoothed curve for drawing — or nil until the scene
    /// has accumulated enough watch time for the shape to mean anything (~20 watched seconds).
    func curve(sceneID: String) -> [Double]? {
        guard Self.isEnabled, let bins = data[key(sceneID)], bins.count == Self.binCount else { return nil }
        let nonzero = bins.filter { $0 > 0 }
        guard nonzero.reduce(0, +) > 20, nonzero.count > 2 else { return nil }
        // Cap outliers at 4× the nonzero mean so one looped moment doesn't flatten the rest of the curve.
        let cap = nonzero.reduce(0, +) / Double(nonzero.count) * 4
        let capped = bins.map { min($0, cap) }
        // 3-tap smoothing so single-bin spikes read as bumps, not needles.
        var smooth = capped
        for i in capped.indices {
            let a = capped[max(0, i - 1)], b = capped[i], c = capped[min(capped.count - 1, i + 1)]
            smooth[i] = (a + 2 * b + c) / 4
        }
        guard let peak = smooth.max(), peak > 0 else { return nil }
        return smooth.map { $0 / peak }
    }

    /// Wipe all heat data (Settings action).
    func clearAll() {
        data = [:]
        dirty = true
        flush(force: true)
    }

    /// Debounced persistence: record() fires every playback tick, so writes are batched (~10 s apart) and
    /// dispatched off the main actor with a value snapshot — mirrors the LoadEstimator pattern.
    private func saveSoon() {
        dirty = true
        flush(force: false)
    }

    private func flush(force: Bool) {
        guard dirty, force || Date().timeIntervalSince(lastSave) > 10 else { return }
        dirty = false
        lastSave = Date()
        let snapshot = data
        let url = Self.fileURL
        Task.detached(priority: .utility) {
            if let encoded = try? JSONEncoder().encode(snapshot) {
                try? encoded.write(to: url, options: .atomic)
            }
        }
    }
}
