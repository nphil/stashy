import Foundation
import Network

/// Learns how long the loading donut should take to fill, per playback mode, from a rolling window of
/// recent *actual* load times — so the ring fills at a believable rate instead of sitting at 0 (while
/// Stash transcodes the next segment) or snapping straight from 0→100.
///
/// Design notes:
/// - **Rolling window (last `window` samples) per tier**, persisted in UserDefaults (a handful of doubles
///   — negligible). The window is what makes it adapt to *changing* network conditions: recent samples
///   dominate, so moving from Wi-Fi to cellular self-corrects within a load or two.
/// - **First guess** (no samples yet) is seeded by the tier and whether the link is expensive
///   (cellular / hotspot) — no data-wasting speed probe.
/// - Recorded durations are clamped to a plausible range so a one-off stall can't poison the average.
@MainActor
final class LoadEstimator {
    static let shared = LoadEstimator()

    private let window = 6
    private let defaultsKey = "loadEstimatorSamples.v1"
    private var samples: [Int: [Double]] = [:]   // tier.rawValue → recent load durations (seconds)

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Double]] {
            for (k, v) in raw { if let i = Int(k) { samples[i] = v } }
        }
    }

    /// Expected load seconds for a tier: the mean of recent samples, else a connection-biased default.
    func expected(for tier: PlaybackTier) -> Double {
        if let s = samples[tier.rawValue], !s.isEmpty {
            return min(20, max(0.25, s.reduce(0, +) / Double(s.count)))
        }
        return Self.seedDefault(tier: tier, expensive: NetworkStatus.shared.isExpensive)
    }

    /// Record an actual load duration; implausible values are ignored so a stall can't skew the window.
    func record(tier: PlaybackTier, seconds: Double) {
        guard seconds >= 0.3, seconds <= 30 else { return }
        var s = samples[tier.rawValue] ?? []
        s.append(seconds)
        if s.count > window { s.removeFirst(s.count - window) }
        samples[tier.rawValue] = s
        persist()
    }

    private func persist() {
        var raw: [String: [Double]] = [:]
        for (i, v) in samples { raw[String(i)] = v }
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }

    /// Reasonable first-load guesses (seconds) before any samples exist; doubled on an expensive link.
    private static func seedDefault(tier: PlaybackTier, expensive: Bool) -> Double {
        let base: Double
        switch tier {
        case .direct:         base = 0.5   // native file — near-instant on LAN
        case .remux:          base = 1.6   // on-device container rewrite of the first GOP
        case .localTranscode: base = 3.0   // on-device re-encode spin-up
        case .server:         base = 2.6   // server transcode + first segment over the network
        }
        return expensive ? base * 2.2 : base
    }
}

/// Minimal shared reachability: tracks whether the current network path is expensive (cellular / hotspot)
/// or constrained, so the first load-time guess can be slower on a metered link. Event-driven (no
/// polling), one monitor for the whole app — negligible overhead.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _expensive = false
    var isExpensive: Bool { lock.withLock { _expensive } }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let expensive = path.isExpensive || path.isConstrained
            self.lock.withLock { self._expensive = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "stashy.network.monitor", qos: .utility))
    }
}
