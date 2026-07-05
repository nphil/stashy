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
/// A cheap, plugin-free descriptor of how heavy a file is to *start* playing — used to scale the loading
/// donut's expected time (and seek re-buffer) so a 4K HEVC file and a 720p H.264 file don't share one
/// estimate. Every input comes free from Stash's normal scene metadata: no companion plugin, no probe.
/// The companion plugin's ffprobe stats add nothing the app doesn't already have for this purpose.
struct LoadProfile: Sendable, Equatable {
    var pixels: Int = 0          // width × height (0 = unknown → weight 1)
    var bitrateMbps: Double = 0  // source video bitrate, Mbps (0 = unknown → neutral)
    var codec: Codec = .other

    enum Codec: Sendable, Equatable { case h264, hevc, av1, other }

    /// Reference file — 1080p (2.07 Mpx) H.264 @ 8 Mbps → weight ≈ 1.0. Resolution and bitrate scale the
    /// weight *sub-linearly* (a bigger file isn't proportionally slower to *begin*), and codec adds a decode
    /// cost multiplier. Clamped to a sane band so one outlier can't send the donut to either extreme.
    var weight: Double {
        guard pixels > 0 else { return 1 }
        let res = pow(Double(pixels) / 2_073_600, 0.6)                 // 1080p = 1.0
        let br  = bitrateMbps > 0 ? pow(bitrateMbps / 8, 0.4) : 1      // 8 Mbps = 1.0
        let cx: Double
        switch codec {
        case .h264:  cx = 1.0
        case .hevc:  cx = 1.35
        case .av1:   cx = 1.6
        case .other: cx = 1.2
        }
        return min(4, max(0.3, res * br * cx))
    }
}

@MainActor
final class LoadEstimator {
    static let shared = LoadEstimator()

    private let window = 6
    // v2: samples now store seconds *per unit of file weight* (see LoadProfile), not raw seconds — so the
    // v1 raw samples must be discarded rather than misread under the new normalized semantics.
    private let defaultsKey = "loadEstimatorSamples.v2"
    private var samples: [Int: [Double]] = [:]   // bucket key → recent normalized load durations (s / weight)

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [Double]] {
            for (k, v) in raw { if let i = Int(k) { samples[i] = v } }
        }
    }

    /// Sanitise a caller-supplied file weight; `LoadProfile.weight` already clamps, this just guards NaN/0.
    private func clean(_ weight: Double) -> Double { (weight.isFinite && weight > 0) ? weight : 1 }

    /// Expected load seconds for a tier and a file of `weight` (1 = a ~1080p H.264 reference). The learned
    /// samples are seconds-*per-weight*, so a 4K/HEVC file (heavier) scales the same learning up and a 720p
    /// file scales it down — the donut stops sharing one estimate across wildly different files.
    func expected(for tier: PlaybackTier, weight: Double = 1) -> Double {
        let perWeight: Double
        if let s = samples[tier.rawValue], !s.isEmpty {
            perWeight = s.reduce(0, +) / Double(s.count)
        } else {
            perWeight = Self.seedDefault(tier: tier, expensive: NetworkStatus.shared.isExpensive)
        }
        return min(20, max(0.25, perWeight * clean(weight)))
    }

    /// Seek-reinit re-buffers get their OWN per-tier bucket (`seekKey`, disjoint from the cold-start keys)
    /// so a warm re-seek — the source is already open on the server / device — is judged against, and
    /// learns from, past seeks rather than the slower first-load average. Keeping the two separate is what
    /// lets the donut fill at a believable *seek* rate instead of crawling on the cold-start estimate.
    private func seekKey(_ tier: PlaybackTier) -> Int { -(tier.rawValue + 1) }   // -1…-4, disjoint from 0…3

    /// Expected seconds for a seek-reinit re-buffer on this tier and file weight — warm, so the defaults sit
    /// well under the equivalent cold start; the rolling window then adapts to the real device/server.
    func expectedSeek(for tier: PlaybackTier, weight: Double = 1) -> Double {
        let perWeight: Double
        if let s = samples[seekKey(tier)], !s.isEmpty {
            perWeight = s.reduce(0, +) / Double(s.count)
        } else {
            switch tier {
            case .direct:         perWeight = 0.3
            case .remux:          perWeight = 0.7   // av_seek_frame → one GOP remuxed, already-open input
            case .localTranscode: perWeight = 1.4   // re-encode spin-up from the seek keyframe
            case .server:         perWeight = 1.2
            }
        }
        let seed = NetworkStatus.shared.isExpensive && samples[seekKey(tier)] == nil ? 1.8 : 1.0
        return min(12, max(0.15, perWeight * seed * clean(weight)))
    }

    /// Record an actual load duration; implausible values are ignored so a stall can't skew the window.
    /// `record` is called exactly as `isLoading` clears — i.e. as the first frames start playing — so the
    /// persistence is pushed **off the main thread** to guarantee it never delays playback start.
    func record(tier: PlaybackTier, seconds: Double, weight: Double = 1) {
        record(key: tier.rawValue, rawSeconds: seconds, weight: weight)
    }

    /// Record a seek-reinit re-buffer into its own per-tier bucket. A warm seek can complete faster than a
    /// cold start, so the plausibility floor is lower here.
    func recordSeek(tier: PlaybackTier, seconds: Double, weight: Double = 1) {
        record(key: seekKey(tier), rawSeconds: seconds, weight: weight, minSeconds: 0.12)
    }

    private func record(key: Int, rawSeconds: Double, weight: Double, minSeconds: Double = 0.3) {
        guard rawSeconds >= minSeconds, rawSeconds <= 30 else { return }
        let normalized = rawSeconds / clean(weight)   // store seconds-per-unit-weight so any file can apply it
        var s = samples[key] ?? []
        s.append(normalized)
        if s.count > window { s.removeFirst(s.count - window) }
        samples[key] = s
        let snapshot = samples        // Sendable value copy — nothing main-actor is captured below
        let defaults = defaultsKey
        Task.detached(priority: .utility) {
            var raw: [String: [Double]] = [:]
            for (i, v) in snapshot { raw[String(i)] = v }
            UserDefaults.standard.set(raw, forKey: defaults)
        }
    }

    /// Reasonable first-load guesses (seconds *for a reference-weight file*) before any samples exist;
    /// doubled on an expensive link. `expected(for:weight:)` scales these by the file's weight.
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

    /// Curve for a seek-reinit re-buffer — fills *ahead* of real time (high pace/knee) so the ring reads as
    /// "almost there" quickly, matching a warm re-seek. Independent of the playback tier; the *timing* comes
    /// from `expectedSeek(for:)`, this only shapes the fill.
    static let seek = LoadCurveParams(knee: 0.94, cap: 0.995, tailFrac: 0.40, pace: 1.6)
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
