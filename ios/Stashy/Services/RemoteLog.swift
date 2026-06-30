import UIKit
import Darwin

/// Lightweight remote logger for on-device debugging. Buffers log lines and POSTs them (batched) to a
/// public **ntfy.sh** topic that can be read back over HTTP — so playback/remux behaviour streams off the
/// device in near real time while testing. It also samples the process memory footprint (the metric iOS
/// jetsam terminates on), so a "climbs then dies" pattern is visible right up to the last flush before a
/// kill. Intended for the sideloaded debug build only.
///
/// The topic is obscure but **public** — anything logged is readable by anyone who knows it, so don't log
/// secrets (API keys, tokens). Read the stream with:
///   curl -s "https://ntfy.sh/stashy-dbg-n7x2k9q/json?poll=1&since=all"
final class RemoteLog: @unchecked Sendable {
    static let shared = RemoteLog()

    static let topic = "stashy-dbg-n7x2k9q"
    private static let settingKey = "stashy.debugLogging"
    /// Whether debug log streaming is enabled (off by default — it broadcasts to a public ntfy topic).
    static var isLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }
    private let endpoint = URL(string: "https://ntfy.sh/\(topic)")!
    private let session: URLSession
    private let queue = DispatchQueue(label: "stashy.remotelog")
    private var buffer: [String] = []
    private var enabled = false
    private var timer: DispatchSourceTimer?
    private var memTimer: DispatchSourceTimer?
    private let start = Date()
    /// Rolling tail of recent lines, mirrored to disk so a *hard* crash's final moment (which the periodic
    /// network flush can't catch) is recovered and re-sent on the next launch.
    private var tail: [String] = []
    private let tailFile = FileManager.default.temporaryDirectory.appendingPathComponent("stashy-crashtail.txt")

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
    }

    func enable() {
        queue.async {
            guard !self.enabled else { return }
            self.enabled = true
            // Recover + re-send the previous session's tail (captures a hard crash the live flush missed).
            if let prev = try? String(contentsOf: self.tailFile, encoding: .utf8), !prev.isEmpty {
                self.post("=== PREVIOUS SESSION TAIL (recovered) ===\n" + prev, wait: nil)
                try? FileManager.default.removeItem(at: self.tailFile)
            }
            // Flush every 6s: ntfy.sh free rate-limits per device IP (~1 request / 5s sustained), so a
            // faster cadence gets posts dropped (429) and blacks out the stream. One batched post per 6s
            // stays under the limit. (Transport is ntfy because it's the only HTTPS/443 endpoint readable
            // back from the agent sandbox — MQTT brokers' wss ports and kvdb.io weren't reachable/usable.)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 6, repeating: 6)
            t.setEventHandler { [weak self] in self?.flushLocked() }
            t.resume()
            self.timer = t

            let m = DispatchSource.makeTimerSource(queue: self.queue)
            m.schedule(deadline: .now() + 5, repeating: 5)
            m.setEventHandler { RemoteLog.shared.log("mem \(Int(RemoteLog.memoryMB()))MB") }
            m.resume()
            self.memTimer = m
        }
        log("=== RemoteLog enabled (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)) ===")
        observeMemoryWarning()
        installExceptionHandler()
    }

    func disable() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.memTimer?.cancel(); self.memTimer = nil
            self.buffer.removeAll()
            self.enabled = false
        }
    }

    func log(_ message: String) {
        let line = String(format: "%7.2f  %@", Date().timeIntervalSince(start), message)
        queue.async {
            guard self.enabled else { return }
            self.buffer.append(line)
            if self.buffer.count > 400 { self.buffer.removeFirst(self.buffer.count - 400) }
            self.tail.append(line)
            if self.tail.count > 60 { self.tail.removeFirst(self.tail.count - 60) }
        }
    }

    private func flushLocked() {
        // Persist the rolling tail to disk so a hard crash's final moment is recovered next launch.
        if !tail.isEmpty {
            try? tail.joined(separator: "\n").write(to: tailFile, atomically: true, encoding: .utf8)
        }
        guard !buffer.isEmpty else { return }
        let body = buffer.joined(separator: "\n")
        buffer.removeAll()
        // Resilient post: if the request fails (e.g. a rate-limit 429), re-queue the batch so it's
        // retried on the next flush instead of being lost.
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: req) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error != nil || !(200..<300).contains(code) else { return }
            self?.queue.async {
                guard let self else { return }
                self.buffer.insert(body, at: 0)
                if self.buffer.count > 400 { self.buffer.removeLast(self.buffer.count - 400) }
            }
        }.resume()
    }

    /// Best-effort synchronous flush — for the memory-warning / uncaught-exception paths, where the
    /// process may be about to die and we want the tail of the log to actually leave the device.
    func flushSync(timeout: TimeInterval = 2) {
        queue.sync {
            guard !self.buffer.isEmpty else { return }
            let body = self.buffer.joined(separator: "\n")
            self.buffer.removeAll()
            self.post(body, wait: timeout)
        }
    }

    private func post(_ body: String, wait: TimeInterval?) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        if let wait {
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + wait)
        } else {
            session.dataTask(with: req).resume()
        }
    }

    private func observeMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            RemoteLog.shared.log("⚠️ MEMORY WARNING at \(Int(RemoteLog.memoryMB()))MB")
            RemoteLog.shared.flushSync(timeout: 1)
        }
    }

    private func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { ex in
            RemoteLog.shared.log("💥 EXCEPTION \(ex.name.rawValue): \(ex.reason ?? "") \(ex.callStackSymbols.prefix(8).joined(separator: " | "))")
            RemoteLog.shared.flushSync()
        }
    }

    /// Resident physical footprint in MB (the value iOS jetsam compares against the per-app limit).
    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}
