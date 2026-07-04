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
        case .direct:         base = 0.4   // native file — near-instant on LAN
        case .remux:          base = 1.2   // on-device container rewrite of the first GOP
        case .localTranscode: base = 2.2   // on-device re-encode spin-up
        case .server:         base = 1.8   // server transcode + first segment over the network
        }
        return expensive ? base * 2.0 : base
    }
}

/// Per-mode shaping for the loading-donut curve — applied *on top of* the real, learned `expected` time
/// so the fill rate is tuned to how each mode actually behaves, not a single made-up curve:
/// - **Fast local modes (direct / remux)** fill *ahead* of real time (`pace` > 1) so the ring is
///   near-full almost immediately — a sub-second local seek shouldn't crawl.
/// - **Slow modes (server transcode)** fill close to real time but with a **brisk tail** so when the
///   server takes a beat longer than expected, the ring keeps climbing toward ~99% (reads as "finishing")
///   instead of sitting flat at the knee and then snapping.
struct LoadCurveParams {
    let knee: Double      // fill fraction reached at the (paced) expected time
    let cap: Double       // asymptote held until the real ready-snap to 100%
    let tailFrac: Double  // overrun ease time-constant, as a fraction of the paced expected
    let pace: Double      // > 1 fills faster than real elapsed (snappier); 1 = real time

    static func forTier(_ tier: PlaybackTier) -> LoadCurveParams {
        switch tier {
        case .direct:         return .init(knee: 0.96, cap: 0.995, tailFrac: 0.35, pace: 1.7)
        case .remux:          return .init(knee: 0.95, cap: 0.995, tailFrac: 0.40, pace: 1.5)
        case .localTranscode: return .init(knee: 0.90, cap: 0.99,  tailFrac: 0.50, pace: 1.1)
        case .server:         return .init(knee: 0.90, cap: 0.99,  tailFrac: 0.35, pace: 1.05)
        }
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
