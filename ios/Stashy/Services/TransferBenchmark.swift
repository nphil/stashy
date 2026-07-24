import Foundation
import Network
import UIKit

/// Answers "is multi-threading actually faster against MY server on THIS network?" with measurements
/// from the real file over the real link, instead of assumptions.
///
/// The method matters more than the code here — a naive A/B is worse than no test:
///  • **Counterbalanced order (A B C C B A).** The server's page cache warms as the run proceeds, so a
///    straight A-then-B hands B a free RAM-speed read and calls it a win. Running every configuration
///    once in each half cancels any drift that accumulates over the run.
///  • **Disjoint slices.** Each run reads a different region of the file, so no run is served bytes a
///    previous run just pulled into cache.
///  • **Bytes are counted and discarded.** Nothing is written to disk, so this measures network and
///    server, not the phone's flash.
///  • **Slow-start is excluded.** Throughput is taken over the window from 25% of the slice to the end;
///    including ramp-up flatters the parallel configurations, which open their congestion windows
///    concurrently.
///
/// The third configuration exists because `URLSessionConfiguration.default` caps concurrent connections
/// per host at 6, and the download engine never raises it — so the "8-way" engine has really been
/// running six at a time. This measures whether lifting that cap changes anything.
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
    /// Total bytes this run will pull, so the sheet can say so before the user spends them.
    private(set) var totalMegabytes = 0

    private let configs = [
        Config(label: "1 connection", connections: 1, raiseConnectionCap: false),
        Config(label: "8 connections", connections: 8, raiseConnectionCap: false),
        Config(label: "8 conns, cap lifted", connections: 8, raiseConnectionCap: true)
    ]

    func run(scene: StashScene, apiKey: String) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; status = "" }
        runs = []; summary = []; verdict = nil; error = nil

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
        totalMegabytes = Int(slice * Int64(order.count) / (1 << 20))
        var measured: [String: [Double]] = [:]

        for (index, config) in order.enumerated() {
            status = "\(config.label) — \(index + 1) of \(order.count)"
            let offset = (fileSize / Int64(order.count)) * Int64(index)
            guard let rate = await measure(url: url, config: config, offset: offset, slice: slice) else {
                if error == nil { error = "A measurement run didn't complete." }
                return
            }
            runs.append(Run(label: config.label, megabytesPerSecond: rate))
            measured[config.label, default: []].append(rate)
            RemoteLog.shared.event("dl-bench", [
                ("net", network), ("conns", config.connections),
                ("cap", config.raiseConnectionCap ? config.connections : 6),
                ("run", index + 1), ("mbps", String(format: "%.1f", rate)),
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
        if best.label == "1 connection" || ratio < 1.15 {
            verdict = "One connection is as fast as eight \(place) — multi-threading buys nothing here, "
                + "and single-connection downloads also finish while the app is closed."
        } else {
            verdict = String(format: "%@ is %.1f× faster than a single connection %@.",
                             best.label, ratio, place)
        }
        RemoteLog.shared.event("dl-bench-result", [
            ("net", network),
            ("best", best.label.replacingOccurrences(of: " ", with: "_")),
            ("ratio", String(format: "%.2f", ratio))])
    }

    /// One configuration, one slice. Returns MB/s over the post-ramp window, or nil on failure.
    private func measure(url: URL, config: Config, offset: Int64, slice: Int64) async -> Double? {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.waitsForConnectivity = true                        // mirror the real engine
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfig.urlCache = nil
        if config.raiseConnectionCap {
            sessionConfig.httpMaximumConnectionsPerHost = config.connections
        }
        let settleBytes = slice / 4

        let sample: BenchmarkProbe.Sample = await withCheckedContinuation { continuation in
            let probe = BenchmarkProbe(tasks: config.connections, settleBytes: settleBytes) { sample in
                continuation.resume(returning: sample)
            }
            let session = URLSession(configuration: sessionConfig, delegate: probe, delegateQueue: nil)
            let per = slice / Int64(config.connections)
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

        if let failure = sample.error { error = failure; return nil }
        let from = sample.settle ?? sample.start
        let elapsed = sample.end.timeIntervalSince(from)
        let counted = sample.settle != nil ? sample.bytes - settleBytes : sample.bytes
        guard elapsed > 0.05, counted > 0 else { return nil }
        return Double(counted) / elapsed / 1_048_576
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
        var start: Date
        var settle: Date?
        var end: Date
        var error: String?
    }

    private let lock = NSLock()
    private let expectedTasks: Int
    private let settleBytes: Int64
    private let start = Date()
    private let finish: @Sendable (Sample) -> Void
    private var bytes: Int64 = 0
    private var completed = 0
    private var settle: Date?
    private var failure: String?
    private var reported = false

    init(tasks: Int, settleBytes: Int64, finish: @escaping @Sendable (Sample) -> Void) {
        self.expectedTasks = tasks
        self.settleBytes = settleBytes
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
        if settle == nil, bytes >= settleBytes { settle = Date() }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let error, (error as NSError).code != NSURLErrorCancelled, failure == nil {
            failure = error.localizedDescription
        }
        completed += 1
        guard completed >= expectedTasks, !reported else { lock.unlock(); return }
        reported = true
        let sample = Sample(bytes: bytes, start: start, settle: settle, end: Date(), error: failure)
        lock.unlock()
        finish(sample)
    }
}
