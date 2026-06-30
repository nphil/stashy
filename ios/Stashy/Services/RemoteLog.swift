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
    private let endpoint = URL(string: "https://ntfy.sh/\(topic)")!
    private let session: URLSession
    private let queue = DispatchQueue(label: "stashy.remotelog")
    private var buffer: [String] = []
    private var enabled = false
    private var timer: DispatchSourceTimer?
    private var memTimer: DispatchSourceTimer?
    private let start = Date()

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        session = URLSession(configuration: cfg)
    }

    func enable() {
        queue.async {
            guard !self.enabled else { return }
            self.enabled = true
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1.5, repeating: 1.5)
            t.setEventHandler { [weak self] in self?.flushLocked() }
            t.resume()
            self.timer = t

            let m = DispatchSource.makeTimerSource(queue: self.queue)
            m.schedule(deadline: .now() + 2, repeating: 2)
            m.setEventHandler { RemoteLog.shared.log("mem \(Int(RemoteLog.memoryMB()))MB") }
            m.resume()
            self.memTimer = m
        }
        log("=== RemoteLog enabled (\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)) ===")
        observeMemoryWarning()
        installExceptionHandler()
    }

    func log(_ message: String) {
        let line = String(format: "%7.2f  %@", Date().timeIntervalSince(start), message)
        queue.async {
            self.buffer.append(line)
            if self.buffer.count > 400 { self.buffer.removeFirst(self.buffer.count - 400) }
        }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        let body = buffer.joined(separator: "\n")
        buffer.removeAll()
        post(body, wait: nil)
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
