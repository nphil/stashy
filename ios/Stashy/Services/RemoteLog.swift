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

    private static let defaultServer = "https://ntfy.sh"
    private static let defaultTopic = "stashy-dbg-n7x2k9q"
    private static let settingKey = "stashy.debugLogging"
    private static let serverKey = "stashy.debug.server"
    private static let topicKey = "stashy.debug.topic"

    /// Whether debug log streaming is enabled (off by default — it broadcasts to a public ntfy topic).
    static var isLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }
    /// ntfy base URL. Point this at a self-hosted ntfy (e.g. an Unraid container) to keep the stream off
    /// the public server; defaults to `https://ntfy.sh`. Empty/whitespace resets to the default.
    static var server: String {
        get {
            let v = (UserDefaults.standard.string(forKey: serverKey) ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? defaultServer : v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            // Strip a trailing slash so `server + "/" + topic` never doubles up.
            let clean = v.hasSuffix("/") ? String(v.dropLast()) : v
            UserDefaults.standard.set(clean, forKey: serverKey)
        }
    }
    /// ntfy topic (the channel path). Defaults to an obscure-but-public topic.
    static var topic: String {
        get {
            let v = (UserDefaults.standard.string(forKey: topicKey) ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? defaultTopic : v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(v, forKey: topicKey)
        }
    }
    /// The full POST/read URL — computed each use so a Settings change takes effect without a relaunch.
    private var endpoint: URL {
        URL(string: "\(RemoteLog.server)/\(RemoteLog.topic)") ?? URL(string: "\(RemoteLog.defaultServer)/\(RemoteLog.defaultTopic)")!
    }
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

    /// Set once per process; the memory-warning observer + uncaught-exception handler are installed a
    /// single time, regardless of how many enable()/disable() cycles happen.
    private var hasInstalledHooks = false

    func enable() {
        queue.async {
            // Install the process-lifetime hooks exactly once — NOT gated on `enabled`, since a
            // disable→enable toggle would otherwise stack another memory-warning observer each time (and
            // each accumulated observer fires its own main-thread flush on a memory warning).
            if !self.hasInstalledHooks {
                self.hasInstalledHooks = true
                self.observeMemoryWarning()
                self.installExceptionHandler()
            }
            guard !self.enabled else { return }
            self.enabled = true
            // Recover + re-send the previous session's tail (captures a hard crash the live flush missed).
            if let prev = try? String(contentsOf: self.tailFile, encoding: .utf8), !prev.isEmpty {
                self.post("=== PREVIOUS SESSION TAIL (recovered) ===\n" + prev, wait: nil)
                try? FileManager.default.removeItem(at: self.tailFile)
            }
            // ntfy.sh free limits (per publishing IP): 250 messages/day, request bucket 60 burst refilling
            // 1 per 5s, 4096 bytes/message. We flush at most one batched POST per 10s and SKIP empty
            // flushes, so an idle app sends nothing — the 250/day budget is spent only on real events, not a
            // fixed heartbeat. Big bursts are split into ≤4096-byte messages; a daily-budget guard backs off
            // instead of hammering 429s. (Transport is ntfy because it's the only HTTPS/443 endpoint
            // readable back from the agent sandbox — MQTT wss ports and kvdb.io weren't usable.)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 10, repeating: 10)
            t.setEventHandler { [weak self] in self?.flushLocked() }
            t.resume()
            self.timer = t

            // Sample memory every 5s but only *emit* on a meaningful move (≥8 MB) or once a minute — so the
            // jetsam "climbs then dies" trend is still captured without a constant 5s line that would drain
            // the daily message budget in ~25 min.
            let m = DispatchSource.makeTimerSource(queue: self.queue)
            m.schedule(deadline: .now() + 5, repeating: 5)
            m.setEventHandler { [weak self] in self?.sampleMemory() }
            m.resume()
            self.memTimer = m
        }
        // ProcessInfo (not UIDevice.current, which is @MainActor) so this stays legal in the nonisolated
        // enable() under strict concurrency; gives the same "iOS 26.x" string.
        log("=== RemoteLog enabled (\(ProcessInfo.processInfo.operatingSystemVersionString)) ===")
    }

    func disable() {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.memTimer?.cancel(); self.memTimer = nil
            self.buffer.removeAll()
            self.enabled = false
        }
    }

    /// Structured one-liner: `tag  k=v k=v …`. Nil values are dropped so a line only carries what's known.
    /// Keeps diagnostics grep-friendly and compact instead of a multi-line dump per event.
    func event(_ tag: String, _ fields: [(String, Any?)]) {
        let parts = fields.compactMap { key, value -> String? in
            guard let value else { return nil }
            return "\(key)=\(value)"
        }
        log("\(tag)  " + parts.joined(separator: " "))
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

    // ntfy.sh caps: 4096 bytes/message and 250 messages/day per publishing IP. Keep a safety margin.
    private let maxMessageBytes = 3800
    private let dailyMessageBudget = 248
    private var sentToday = 0
    private var sentDayStamp = -1
    private var budgetWarned = false

    /// Emit a memory line only when it moved enough to matter, or once a minute — so the periodic sampler
    /// doesn't turn into a fixed message heartbeat that drains the daily budget.
    private func sampleMemory() {
        let mb = RemoteLog.memoryMB()
        let now = Date()
        guard abs(mb - lastMemLogged) >= 8 || now.timeIntervalSince(lastMemLogAt) >= 60 else { return }
        lastMemLogged = mb
        lastMemLogAt = now
        log("mem \(Int(mb))MB")
    }
    private var lastMemLogged = -1000.0
    private var lastMemLogAt = Date.distantPast

    private func trimBufferKeepingFront() {
        if buffer.count > 400 { buffer.removeLast(buffer.count - 400) }
    }

    private func flushLocked() {
        // Persist the rolling tail to disk so a hard crash's final moment is recovered next launch.
        if !tail.isEmpty {
            try? tail.joined(separator: "\n").write(to: tailFile, atomically: true, encoding: .utf8)
        }
        guard !buffer.isEmpty else { return }

        // Roll the daily message counter over at UTC midnight.
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        if day != sentDayStamp { sentDayStamp = day; sentToday = 0; budgetWarned = false }

        // Pack the buffered lines into as few messages as possible, each ≤ the 4096-byte per-message cap.
        let lines = buffer
        buffer.removeAll()
        var chunks: [String] = []
        var current = ""
        for line in lines {
            let clamped = RemoteLog.clampToBytes(line, maxMessageBytes)
            if current.isEmpty {
                current = clamped
            } else if current.utf8.count + 1 + clamped.utf8.count <= maxMessageBytes {
                current += "\n" + clamped
            } else {
                chunks.append(current); current = clamped
            }
        }
        if !current.isEmpty { chunks.append(current) }

        for (i, chunk) in chunks.enumerated() {
            // Daily budget guard: rather than 429-hammer the public server, re-buffer the remainder and
            // stop for now (it drains on the next UTC day, or immediately on a self-hosted server).
            if sentToday >= dailyMessageBudget {
                if !budgetWarned {
                    budgetWarned = true
                    tail.append("⚠︎ ntfy daily message budget (\(dailyMessageBudget)) reached — pausing sends")
                }
                buffer.insert(contentsOf: chunks[i...], at: 0)
                trimBufferKeepingFront()
                return
            }
            sentToday += 1
            postChunk(chunk)
        }
    }

    /// POST one ≤4096-byte message; on failure (e.g. 429) refund the budget and re-queue it for next flush.
    private func postChunk(_ body: String) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: req) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard error != nil || !(200..<300).contains(code) else { return }
            self?.queue.async {
                guard let self else { return }
                self.sentToday = max(0, self.sentToday - 1)   // it didn't actually land
                self.buffer.insert(body, at: 0)
                self.trimBufferKeepingFront()
            }
        }.resume()
    }

    /// Truncate a string to at most `max` UTF-8 bytes without splitting a multi-byte scalar.
    private static func clampToBytes(_ s: String, _ max: Int) -> String {
        guard s.utf8.count > max else { return s }
        var bytes = Array(s.utf8.prefix(max))
        while let last = bytes.last, last & 0xC0 == 0x80 { bytes.removeLast() }   // back off continuation bytes
        return String(decoding: bytes, as: UTF8.self)
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

    /// Upload a screenshot (or any image) as an ntfy **attachment**. ntfy hosts a PUT body at a public URL
    /// referenced from the message JSON, so on the public server the image can be fetched back off-device
    /// for inspection — the one way an image leaves the phone through the same channel as the text logs.
    /// No-op unless logging is enabled. Best-effort; failures are logged, not surfaced.
    func uploadImage(_ data: Data, caption: String) {
        guard RemoteLog.isLoggingEnabled, !data.isEmpty else { return }
        // ntfy.sh caps attachments at 2 MB (and 200 MB/day, 20 MB/visitor total). The capture path already
        // downscales under this, but guard here too so an oversized image is dropped with a note rather
        // than rejected by the server or silently reinterpreted.
        guard data.count <= 2_000_000 else {
            log("📷 screenshot \(data.count / 1024) KB exceeds ntfy 2 MB cap — skipped")
            return
        }
        let name = "shot-\(Int(Date().timeIntervalSince1970)).jpg"
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.httpBody = data
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.setValue(name, forHTTPHeaderField: "Filename")
        // ntfy header values must be ASCII; strip anything else out of the caption title.
        let asciiCaption = caption.unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
        if !asciiCaption.isEmpty { req.setValue(asciiCaption, forHTTPHeaderField: "Title") }
        log("📷 uploading screenshot \(name) (\(data.count / 1024) KB)…")
        session.dataTask(with: req) { [weak self] respData, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, (200..<300).contains(code) {
                // Echo the hosted attachment URL into the text stream so it can be fetched back.
                let url = respData
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { ($0["attachment"] as? [String: Any])?["url"] as? String }
                self?.log("📷 screenshot posted\(url.map { " → \($0)" } ?? "")")
            } else {
                self?.log("📷 screenshot upload failed (code \(code) \(error?.localizedDescription ?? ""))")
            }
        }.resume()
    }

    private func observeMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            RemoteLog.shared.log("⚠️ MEMORY WARNING at \(Int(RemoteLog.memoryMB()))MB")
            // Async flush — this notification is delivered on the main thread, and the blocking network
            // wait it used to do stalled the main thread up to 1s exactly when the app is under pressure.
            // The tail is already persisted to disk in flushLocked(), so the hard-kill case stays covered.
            RemoteLog.shared.queue.async { RemoteLog.shared.flushLocked() }
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
