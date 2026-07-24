import Foundation
import Network
import UIKit

/// Answers "is multi-threading actually faster against MY server on THIS network?" with measurements
/// from the real file over the real link, instead of assumptions.
///
/// The method matters more than the code here — a naive A/B is worse than no test:
///  • **Counterbalanced A B C C B A order.** The server's page cache warms as the run proceeds, so a
///    straight A-then-B hands B a free RAM-speed read and calls it a win. Running every configuration
///    once in each half cancels drift that accumulates over the run.
///  • **Disjoint slices.** Each run reads a different region of the file, so no run is served bytes a
///    previous run just pulled into cache.
///  • **Bytes are counted and discarded.** Nothing is written to disk, so this measures network and
///    server, not the phone's flash.
///  • **Slow-start is excluded per connection.** The measurement window opens only once EVERY stream
///    has moved a quarter of its own range. A threshold on the combined byte count would be unfair in
///    the opposite direction to the obvious one: eight streams each reach 1/8 of the total while all
///    eight congestion windows are still ramping, so the parallel arms would be measured mid-ramp.
///  • **A short run is discarded, never averaged.** A cut-off slice still yields a plausible-looking
///    MB/s, which would quietly corrupt the comparison the whole feature exists to make.
///
/// Interpretation caveat the result carries with it: over HTTPS, URLSession negotiates HTTP/2 and
/// multiplexes every request onto ONE connection, so all three configurations become the same
/// transport and the numbers will agree for a reason that has nothing to do with the network. The
/// negotiated protocol is captured from `URLSessionTaskMetrics` and reported.
@MainActor
@Observable
final class TransferBenchmark {
    struct Run: Identifiable {
        let id = UUID()
        let label: String
        let megabytesPerSecond: Double
    }

    /// Averaged result per configuration. A struct, not a tuple: Swift has no key paths into tuple
    /// elements, so `ForEach(_:id: \.label)` over an array of tuples doesn't compile.
    struct Summary: Identifiable {
        var id: String { label }
        let label: String
        let megabytesPerSecond: Double
    }

    private struct Config {
        let label: String
        let connections: Int
        let raiseConnectionCap: Bool
    }

    private(set) var runs: [Run] = []
    private(set) var summary: [Summary] = []
    private(set) var verdict: String?
    private(set) var status = ""
    private(set) var isRunning = false
    private(set) var error: String?
    /// Bytes this run pulled, so the sheet can report what was spent.
    private(set) var totalMegabytes = 0
    /// Negotiated transport ("h2", "http/1.1") and the per-host connection limit actually in force —
    /// both are needed to read the numbers honestly, and neither can be assumed.
    private(set) var transportNote: String?

    @ObservationIgnored private var liveSession: URLSession?
    @ObservationIgnored private var cancelled = false

    private let configs = [
        Config(label: "1 connection", connections: 1, raiseConnectionCap: false),
        Config(label: "8 requests (default cap)", connections: 8, raiseConnectionCap: false),
        Config(label: "8 requests, cap lifted", connections: 8, raiseConnectionCap: true)
    ]

    /// Stop immediately and release the sockets. The sheet calls this on dismissal — without it, an
    /// abandoned run keeps pulling hundreds of megabytes with no UI attached.
    func cancel() {
        cancelled = true
        liveSession?.invalidateAndCancel()
        liveSession = nil
    }

    func run(scene: StashScene, apiKey: String) async {
        guard !isRunning else { return }
        isRunning = true
        cancelled = false
        defer { isRunning = false; status = ""; liveSession = nil }
        runs = []; summary = []; verdict = nil; error = nil
        totalMegabytes = 0; transportNote = nil

        guard let url = scene.directFileURL(apiKey: apiKey) else {
            error = "This scene has no direct file URL to measure."
            return
        }

        // A B C C B A: each configuration runs once in each half of the sequence.
        let order = [configs[0], configs[1], configs[2], configs[2], configs[1], configs[0]]
        let network = await networkLabel()
        // Six runs of the Wi-Fi slice would be ~576 MB — fine over the LAN, expensive on a metered
        // cellular plan, which is exactly where this test is most worth running. Shrink it there;
        // cellular is slow enough that a smaller slice still clears TCP slow-start comfortably.
        let cap: Int64 = network == "cellular" ? 24 << 20 : 96 << 20
        let fileSize = Int64(scene.files.first?.size ?? 0)
        let slice = min(cap, fileSize / 8)
        guard slice >= 8 << 20 else {
            error = "Pick a scene larger than about 70 MB — smaller files finish before the transfer settles."
            return
        }
        var measured: [String: [Double]] = [:]

        for (index, config) in order.enumerated() {
            if cancelled || Task.isCancelled { return }
            status = "\(config.label) — \(index + 1) of \(order.count)"
            let offset = (fileSize / Int64(order.count)) * Int64(index)
            guard let result = await measure(url: url, config: config, offset: offset, slice: slice) else {
                if error == nil, !cancelled { error = "A measurement run didn't complete." }
                return
            }
            totalMegabytes += Int(slice / (1 << 20))
            runs.append(Run(label: config.label, megabytesPerSecond: result.rate))
            measured[config.label, default: []].append(result.rate)
            if transportNote == nil, let proto = result.networkProtocol {
                transportNote = "\(proto), per-host limit \(result.connectionLimit)"
            }
            RemoteLog.shared.event("dl-bench", [
                ("net", network), ("conns", config.connections),
                ("cap", result.connectionLimit), ("proto", result.networkProtocol),
                ("run", index + 1), ("mbps", String(format: "%.1f", result.rate)),
                ("slice_mb", slice / (1 << 20))])
            try? await Task.sleep(for: .seconds(1))   // let sockets close so runs don't overlap
        }

        summary = configs.map { config in
            let samples = measured[config.label] ?? []
            let mean = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
            return Summary(label: config.label, megabytesPerSecond: mean)
        }
        buildVerdict(network: network)
    }

    private func buildVerdict(network: String) {
        guard let best = summary.max(by: { $0.megabytesPerSecond < $1.megabytesPerSecond }),
              let single = summary.first(where: { $0.label == "1 connection" }),
              single.megabytesPerSecond > 0 else { return }
        let ratio = best.megabytesPerSecond / single.megabytesPerSecond
        let place = network == "cellular" ? "on cellular" : "on \(network)"
        // Over HTTP/2 every request rides one connection, so the arms are the same transport and an
        // "they tie" result says nothing about parallelism. Say so rather than let it read as a finding.
        let multiplexed = transportNote?.contains("h2") == true
        if multiplexed && ratio < 1.15 {
            verdict = "All three tie \(place), but the connection negotiated HTTP/2 — it multiplexes every "
                + "request onto one connection, so this can't tell you whether parallelism helps. Test "
                + "against a plain-HTTP URL to compare properly."
        } else if best.label == "1 connection" || ratio < 1.15 {
            verdict = "One connection is as fast as eight \(place) — multi-threading buys nothing here, "
                + "and single-connection downloads also finish while the app is closed."
        } else {
            verdict = String(format: "%@ is %.1f× faster than a single connection %@.",
                             best.label, ratio, place)
        }
        RemoteLog.shared.event("dl-bench-result", [
            ("net", network), ("transport", transportNote),
            ("best", best.label.replacingOccurrences(of: " ", with: "_")),
            ("ratio", String(format: "%.2f", ratio))])
    }

    private struct Measurement {
        let rate: Double
        let networkProtocol: String?
        let connectionLimit: Int
    }

    /// One configuration, one slice. Returns nil (with `error` set) rather than a number whenever the
    /// run didn't transfer its whole slice — a truncated run must never reach the average.
    private func measure(url: URL, config: Config, offset: Int64, slice: Int64) async -> Measurement? {
        let sessionConfig = URLSessionConfiguration.default
        // A benchmark must fail fast, not wait. The download engine sets waitsForConnectivity because
        // it is a long-lived transfer with a UI that can cancel and resume; here it would park the
        // continuation forever on a dropped link — the run would never finish and the sheet would be
        // stuck "running" for the life of the object.
        sessionConfig.waitsForConnectivity = false
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 180
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfig.urlCache = nil
        if config.raiseConnectionCap {
            sessionConfig.httpMaximumConnectionsPerHost = config.connections
        }
        let effectiveLimit = sessionConfig.httpMaximumConnectionsPerHost
        let per = slice / Int64(config.connections)

        let sample: BenchmarkProbe.Sample = await withCheckedContinuation { continuation in
            let probe = BenchmarkProbe(tasks: config.connections, perTaskSettle: per / 4) { sample in
                continuation.resume(returning: sample)
            }
            let session = URLSession(configuration: sessionConfig, delegate: probe, delegateQueue: nil)
            liveSession = session
            for i in 0..<config.connections {
                let low = offset + Int64(i) * per
                let high = i == config.connections - 1 ? offset + slice - 1 : low + per - 1
                var request = URLRequest(url: url)
                request.setValue("bytes=\(low)-\(high)", forHTTPHeaderField: "Range")
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                session.dataTask(with: request).resume()
            }
            session.finishTasksAndInvalidate()   // releases the delegate once the tasks end
        }
        liveSession = nil

        if let failure = sample.error {
            if !cancelled { error = failure }
            return nil
        }
        // Completeness, not just success: a slice that stopped early still divides into a believable
        // rate, and averaging it would silently skew the comparison.
        guard sample.bytes >= slice else {
            if !cancelled {
                error = "A run was cut short — keep Stashy open and in the foreground while it measures."
            }
            return nil
        }
        let from = sample.settle ?? sample.start
        let elapsed = sample.end.timeIntervalSince(from)
        let counted = sample.bytes - sample.bytesAtSettle
        guard elapsed > 0.05, counted > 0 else { return nil }
        return Measurement(rate: Double(counted) / elapsed / 1_048_576,
                           networkProtocol: sample.networkProtocol,
                           connectionLimit: effectiveLimit)
    }

    /// Label the result with the link it was measured on — the whole point is that the answer differs
    /// between home Wi-Fi and cellular.
    private func networkLabel() async -> String {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "stashy.benchmark.path"))
        try? await Task.sleep(for: .milliseconds(250))
        let path = monitor.currentPath
        monitor.cancel()
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        return "unknown"
    }
}

/// Counts bytes for one benchmark run and throws them away. Separate from the actor because URLSession
/// delivers on its own queue; all state is lock-guarded.
private final class BenchmarkProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Sample: Sendable {
        var bytes: Int64
        var bytesAtSettle: Int64
        var start: Date
        var settle: Date?
        var end: Date
        var error: String?
        var networkProtocol: String?
    }

    private let lock = NSLock()
    private let expectedTasks: Int
    private let perTaskSettle: Int64
    private let start = Date()
    private let finish: @Sendable (Sample) -> Void
    private var perTask: [Int: Int64] = [:]
    private var bytes: Int64 = 0
    private var bytesAtSettle: Int64 = 0
    private var settle: Date?
    private var completed = 0
    private var failure: String?
    private var networkProtocol: String?
    private var refusedRange = false
    private var reported = false

    init(tasks: Int, perTaskSettle: Int64, finish: @escaping @Sendable (Sample) -> Void) {
        self.expectedTasks = tasks
        self.perTaskSettle = max(1, perTaskSettle)
        self.finish = finish
        super.init()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // A server that ignores Range answers 200 with the WHOLE file — every task would then pull
        // gigabytes and the comparison would be meaningless. Refuse loudly instead of measuring noise.
        guard (response as? HTTPURLResponse)?.statusCode == 206 else {
            lock.lock()
            refusedRange = true
            if failure == nil { failure = "The server didn't honor a byte range (no 206 response)." }
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bytes += Int64(data.count)
        perTask[dataTask.taskIdentifier, default: 0] += Int64(data.count)
        // Open the measurement window only once EVERY stream is past its own ramp, so the parallel
        // configurations aren't measured while their congestion windows are still growing.
        if settle == nil, perTask.count >= expectedTasks,
           perTask.values.allSatisfy({ $0 >= perTaskSettle }) {
            settle = Date()
            bytesAtSettle = bytes
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let name = metrics.transactionMetrics.last?.networkProtocolName else { return }
        lock.lock()
        if networkProtocol == nil { networkProtocol = name }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let error {
            let code = (error as NSError).code
            // Cancellation counts as a failure UNLESS we cancelled the task ourselves over a bad
            // status — an externally cancelled run (sheet dismissed, app suspended) has a short,
            // meaningless byte count that must not be reported as a measurement.
            if !(code == NSURLErrorCancelled && refusedRange), failure == nil {
                failure = code == NSURLErrorCancelled
                    ? "The run was interrupted before it finished."
                    : error.localizedDescription
            }
        }
        completed += 1
        guard completed >= expectedTasks, !reported else { lock.unlock(); return }
        reported = true
        let sample = Sample(bytes: bytes, bytesAtSettle: bytesAtSettle, start: start,
                            settle: settle, end: Date(), error: failure,
                            networkProtocol: networkProtocol)
        lock.unlock()
        finish(sample)
    }
}
