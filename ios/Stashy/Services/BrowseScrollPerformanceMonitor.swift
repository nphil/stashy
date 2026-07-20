import UIKit
import QuartzCore

/// Debug-only frame-cadence probe for the library grids. It is armed only while RemoteLog streaming is
/// enabled and a browse ScrollView is moving, so normal users pay no display-link or logging cost.
///
/// The link explicitly requests the screen's maximum cadence (120 Hz on ProMotion). That makes a result
/// below 120 meaningful: it reflects main-run-loop stalls/callback gaps rather than ProMotion idling down.
/// This cannot see a compositor-only missed presentation, but it does quantify the main-thread frame-time
/// spikes responsible for the great majority of SwiftUI scroll judder.
@MainActor
final class BrowseScrollPerformanceMonitor {
    static let shared = BrowseScrollPerformanceMonitor()

    private struct FrameSample {
        let interval: Double
        let targetInterval: Double
        let phase: String
    }

    private struct ThumbnailSample {
        let loadMilliseconds: Double
        let memoryHit: Bool
        let phase: String
    }

    private var displayLink: CADisplayLink?
    private var linkProxy: BrowseScrollDisplayLinkProxy?
    private var samples: [FrameSample] = []
    private var thumbnailSamples: [ThumbnailSample] = []
    private var surface = ""
    private var phase = ""
    private var lastTimestamp = 0.0
    private var maximumHz = 60

    private init() {}

    func setScrolling(_ scrolling: Bool, surface: String, phase: String) {
        guard RemoteLog.isLoggingEnabled else {
            if displayLink != nil { stop(reason: "logging-off") }
            return
        }

        if scrolling {
            if displayLink == nil {
                start(surface: surface, phase: phase)
            } else if self.surface != surface {
                stop(reason: "surface-change")
                start(surface: surface, phase: phase)
            } else if self.phase != phase {
                self.phase = phase
            }
        } else if displayLink != nil {
            stop(reason: "idle")
        }
    }

    /// Called at the exact point a card publishes a real texture. These counts let the frame report show
    /// whether a bad interval coincided with a burst of image arrivals.
    func recordThumbnailPublication(loadMilliseconds: Double, memoryHit: Bool) {
        guard displayLink != nil else { return }
        thumbnailSamples.append(ThumbnailSample(
            loadMilliseconds: loadMilliseconds,
            memoryHit: memoryHit,
            phase: phase
        ))
    }

    private func start(surface: String, phase: String) {
        self.surface = surface
        self.phase = phase
        samples.removeAll(keepingCapacity: true)
        thumbnailSamples.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        maximumHz = max(60, UIScreen.main.maximumFramesPerSecond)

        let proxy = BrowseScrollDisplayLinkProxy(target: self)
        let link = CADisplayLink(target: proxy, selector: #selector(BrowseScrollDisplayLinkProxy.tick))
        proxy.link = link
        let maximum = Float(maximumHz)
        let minimum = min(Float(80), maximum)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: minimum,
            maximum: maximum,
            preferred: maximum
        )
        link.add(to: .main, forMode: .common)
        linkProxy = proxy
        displayLink = link

        RemoteLog.shared.event("scroll-start", [
            ("surface", surface),
            ("phase", phase),
            ("requested_hz", maximumHz)
        ])
    }

    private func stop(reason: String) {
        // Do all sorting/percentile/string work after ScrollView has reported idle. During motion the probe
        // only appends two Doubles + a short phase string per callback, keeping measurement perturbation tiny.
        var phaseOrder: [String] = []
        for sample in samples where !phaseOrder.contains(sample.phase) {
            phaseOrder.append(sample.phase)
        }
        for phase in phaseOrder {
            emit(
                samples.filter { $0.phase == phase },
                thumbnails: thumbnailSamples.filter { $0.phase == phase },
                tag: "scroll-segment",
                phase: phase,
                reason: nil
            )
        }
        emit(
            samples,
            thumbnails: thumbnailSamples,
            tag: "scroll-end",
            phase: "all",
            reason: reason
        )
        displayLink?.invalidate()
        displayLink = nil
        linkProxy = nil
        samples.removeAll(keepingCapacity: true)
        thumbnailSamples.removeAll(keepingCapacity: true)
        lastTimestamp = 0
    }

    fileprivate func tick(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        if lastTimestamp > 0 {
            let interval = timestamp - lastTimestamp
            let fallback = 1.0 / Double(maximumHz)
            let target = max(fallback, targetTimestamp - timestamp)
            // A runaway session should not retain memory forever. Ten minutes at 120 Hz is far beyond a
            // normal fling; keep the newest samples if a ScrollView somehow never reports idle.
            if samples.count >= 72_000 {
                samples.removeFirst(12_000)
            }
            samples.append(FrameSample(interval: interval, targetInterval: target, phase: phase))
        }
        lastTimestamp = timestamp
    }

    private func emit(
        _ frames: [FrameSample],
        thumbnails: [ThumbnailSample],
        tag: String,
        phase: String,
        reason: String?
    ) {
        guard !frames.isEmpty else { return }
        let intervals = frames.map(\.interval)
        let ordered = intervals.sorted()
        let elapsed = intervals.reduce(0, +)
        let average = elapsed / Double(intervals.count)
        let variance = intervals.reduce(0) { $0 + (($1 - average) * ($1 - average)) } / Double(intervals.count)
        let target = median(frames.map(\.targetInterval))
        let base120 = 1.0 / Double(maximumHz)
        let hitches = frames.filter { $0.interval > max($0.targetInterval * 1.5, base120 * 1.5) }.count
        let severe = frames.filter { $0.interval >= 0.05 }.count
        let missedAtMaximum = frames.reduce(0) { partial, sample in
            partial + max(0, Int((sample.interval / base120).rounded()) - 1)
        }
        let cadence = cadenceBuckets(intervals)
        let loads = thumbnails.filter { !$0.memoryHit }.map(\.loadMilliseconds).sorted()
        let loadP95 = loads.isEmpty ? nil : percentile(loads, 0.95)

        RemoteLog.shared.event(tag, [
            ("surface", surface),
            ("phase", phase),
            ("reason", reason),
            ("sec", format(elapsed, digits: 2)),
            ("fps", format(Double(intervals.count) / max(elapsed, 0.001), digits: 1)),
            ("target_hz", format(1.0 / max(target, 0.001), digits: 0)),
            ("avg_ms", format(average * 1_000, digits: 2)),
            ("p95_ms", format(percentile(ordered, 0.95) * 1_000, digits: 2)),
            ("p99_ms", format(percentile(ordered, 0.99) * 1_000, digits: 2)),
            ("max_ms", format((ordered.last ?? 0) * 1_000, digits: 2)),
            ("hitch_pct", format(Double(hitches) * 100 / Double(intervals.count), digits: 1)),
            ("severe", severe),
            ("missed_\(maximumHz)", missedAtMaximum),
            ("judder_pct", format(sqrt(variance) / max(average, 0.001) * 100, digits: 1)),
            ("gaps_8_12_16_25_34p", cadence),
            ("thumb_publishes", thumbnails.count),
            ("thumb_mem_hits", thumbnails.filter { $0.memoryHit }.count),
            ("thumb_load_p95_ms", loadP95.map { format($0, digits: 0) })
        ])
    }

    private func cadenceBuckets(_ intervals: [Double]) -> String {
        var buckets = [0, 0, 0, 0, 0]
        for milliseconds in intervals.map({ $0 * 1_000 }) {
            switch milliseconds {
            case ...10.5: buckets[0] += 1       // approximately 120 Hz
            case ...14.5: buckets[1] += 1       // approximately 80 Hz
            case ...20.5: buckets[2] += 1       // approximately 60 Hz / one missed 120 Hz interval
            case ...30.0: buckets[3] += 1
            default: buckets[4] += 1
            }
        }
        return buckets.map(String.init).joined(separator: "/")
    }

    private func percentile(_ ordered: [Double], _ fraction: Double) -> Double {
        guard !ordered.isEmpty else { return 0 }
        let index = min(ordered.count - 1, Int((Double(ordered.count - 1) * fraction).rounded()))
        return ordered[index]
    }

    private func median(_ values: [Double]) -> Double {
        percentile(values.sorted(), 0.5)
    }

    private func format(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

/// The run loop retains CADisplayLink and CADisplayLink retains its target. Keep only a weak monitor target
/// so ending a diagnostic session never creates a retain cycle.
private final class BrowseScrollDisplayLinkProxy: NSObject {
    weak var target: BrowseScrollPerformanceMonitor?
    var link: CADisplayLink?

    init(target: BrowseScrollPerformanceMonitor) {
        self.target = target
        super.init()
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let target else {
            self.link?.invalidate()
            self.link = nil
            return
        }
        let timestamp = link.timestamp
        let targetTimestamp = link.targetTimestamp
        MainActor.assumeIsolated {
            target.tick(timestamp: timestamp, targetTimestamp: targetTimestamp)
        }
    }
}
