import UIKit
import Darwin
import Observation

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
    private static let downloadTraceKey = "stashy.debug.downloadTrace"
    private static let tokenKey = "stashy.debug.token"

    /// Whether debug log streaming is enabled (off by default — it broadcasts to a public ntfy topic).
    static var isLoggingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// Verbose per-slice / per-part download tracing. Structural download events (errors, holds,
    /// geometry wipes, lifecycle transitions) always log when logging is on; this gate adds the
    /// high-frequency ones — every background slice, every part-size census — which are what make a
    /// "the percentage went backwards while minimized" report diagnosable, but which would otherwise
    /// spend the ntfy daily message budget on a single large transfer. Off by default.
    static var isDownloadTracingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: downloadTraceKey) }
        set { UserDefaults.standard.set(newValue, forKey: downloadTraceKey) }
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
            let before = UserDefaults.standard.string(forKey: serverKey)
            UserDefaults.standard.set(clean, forKey: serverKey)
            if before != clean { shared.configChanged() }
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
            let before = UserDefaults.standard.string(forKey: topicKey)
            UserDefaults.standard.set(v, forKey: topicKey)
            if before != v { shared.configChanged() }
        }
    }
    /// ntfy access token (`tk_…` or any bearer token), for a server that isn't open to everyone. Kept in
    /// the Keychain — never in UserDefaults and never logged. Empty = no `Authorization` header.
    static var token: String {
        get { KeychainService.read(tokenKey) ?? "" }
        set {
            let v = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unchanged (e.g. the Settings field loading the stored value) must not reset the delivery status.
            if v == (KeychainService.read(tokenKey) ?? "") { return }
            if v.isEmpty {
                KeychainService.delete(tokenKey)
            } else {
                // Readable while the phone is locked (after first unlock): a download running in the
                // background must still be able to authenticate its log posts.
                KeychainService.write(tokenKey, value: v, afterFirstUnlock: true)
            }
            shared.configChanged(token: v)
        }
    }
    /// The full POST/read URL — computed each use so a Settings change takes effect without a relaunch.
    private var endpoint: URL {
        URL(string: "\(RemoteLog.server)/\(RemoteLog.topic)") ?? URL(string: "\(RemoteLog.defaultServer)/\(RemoteLog.defaultTopic)")!
    }

    // MARK: Delivery health (all queue-confined; published to SwiftUI through `RemoteLogStatus`)
    private var health = RemoteLogHealth()
    /// No flush before this instant — set by a failed send, cleared by a success / config change / test.
    private var backoffUntil = Date.distantPast
    /// The token, cached in memory: the Keychain item is unreadable while the phone is locked (before first
    /// unlock after boot), and a locked phone is exactly when a background download is logging. `nil` =
    /// not loaded yet; an empty string = "no token" (set explicitly).
    private var tokenCache: String?

    /// Queue-confined. Every POST / PUT is built here so the bearer token is attached the same way.
    private func makeRequest(method: String, body: Data, contentType: String,
                             configure: (inout URLRequest) -> Void = { _ in }) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if tokenCache == nil, let stored = KeychainService.read(RemoteLog.tokenKey) { tokenCache = stored }
        if let token = tokenCache, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        configure(&req)
        return req
    }

    /// Record one send's result (queue-confined) and publish it. A failure sets the back-off: exponential
    /// 10 s → 5 min for refusals / outages; for a 429 (quota) start at 1 min, honour `Retry-After`, cap 30 min.
    private func settle(_ outcome: Outcome, wasTest: Bool = false) {
        let now = Date()
        switch outcome {
        case .delivered:
            health.lastSuccess = now
            health.consecutiveFailures = 0
            backoffUntil = .distantPast
        case .failed(let failure, let retryAfter):
            health.lastFailure = failure
            health.consecutiveFailures += 1
            let shift = min(max(health.consecutiveFailures - 1, 0), 8)
            let doublings = Double(Int(1) << shift)
            let delay: TimeInterval
            if case .http(429) = failure.kind {
                delay = min(max(retryAfter ?? 0, 60 * doublings), 1800)
            } else {
                delay = min(10 * doublings, 300)
            }
            backoffUntil = now.addingTimeInterval(delay)
        }
        if wasTest { health.testInFlight = false }
        publish()
    }

    /// Queue-confined: hand the current health to the main actor. `main.async` from a serial queue keeps
    /// snapshots in order, so a stale one can never overwrite a newer one.
    private func publish() {
        let snapshot = health
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RemoteLogStatus.shared.apply(snapshot) }
        }
    }

    private enum Outcome: Sendable {
        case delivered
        case failed(RemoteLogHealth.Failure, retryAfter: TimeInterval?)
    }

    /// Classify a URLSession answer. 2xx = delivered; anything else (HTTP status, or a transport error with
    /// no response) is a failure carrying the host it was addressed to.
    private static func outcome(response: URLResponse?, error: Error?, url: URL?) -> Outcome {
        let host = url?.host ?? ""
        func fail(_ kind: RemoteLogHealth.Failure.Kind, retryAfter: TimeInterval? = nil) -> Outcome {
            .failed(.init(kind: kind, at: Date(), host: host), retryAfter: retryAfter)
        }
        if let error { return fail(.transport(describe(error))) }
        guard let http = response as? HTTPURLResponse else { return fail(.transport("no answer from the server")) }
        if (200..<300).contains(http.statusCode) { return .delivered }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
        return fail(.http(http.statusCode), retryAfter: retryAfter)
    }

    /// A short, plain-English reason for a transport error (the raw `localizedDescription` otherwise).
    private static func describe(_ error: Error) -> String {
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .notConnectedToInternet, .dataNotAllowed: return "no internet connection"
        case .timedOut: return "the server didn't answer in time"
        case .cannotFindHost, .dnsLookupFailed: return "that server name can't be found"
        case .cannotConnectToHost: return "the server refused the connection"
        case .networkConnectionLost: return "the connection dropped"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .appTransportSecurityRequiresSecureConnection:
            return "the secure connection failed"
        default: return e.localizedDescription
        }
    }
    private let session: URLSession
    private let queue = DispatchQueue(label: "stashy.remotelog")
    private var buffer: [String] = []
    /// Lines logged before `enable()` ran, replayed once it does. See the guard in `log(_:)`.
    private var pending: [String] = []
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
            // Replay anything logged before the toggle was read, so launch-time events survive.
            if !self.pending.isEmpty {
                self.buffer.append(contentsOf: self.pending)
                self.tail.append(contentsOf: self.pending)
                self.pending.removeAll()
            }
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
            self.resetDeliveryHealth()
        }
    }

    /// Forget what the last send said — the server, topic or token changed (or logging was turned off), so
    /// an old failure no longer describes the current setup — and lift any back-off. Safe from any thread.
    fileprivate func configChanged(token: String? = nil) {
        queue.async {
            if let token { self.tokenCache = token }
            self.resetDeliveryHealth()
        }
    }

    /// Queue-confined.
    private func resetDeliveryHealth() {
        health.lastSuccess = nil
        health.lastFailure = nil
        health.consecutiveFailures = 0
        backoffUntil = .distantPast
        publish()
    }

    /// Post one line right now — bypassing the buffer, the back-off and the daily budget — and report the
    /// answer through the delivery health (the Settings status line). A success also releases anything held.
    func sendTest() {
        queue.async {
            guard !self.health.testInFlight else { return }
            self.health.testInFlight = true
            self.publish()
            let stamp = Date().formatted(date: .omitted, time: .standard)
            let body = "✅ Stashy test message at \(stamp) — iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            let req = self.makeRequest(method: "POST", body: Data(body.utf8), contentType: "text/plain")
            self.session.dataTask(with: req) { [weak self] _, response, error in
                let outcome = RemoteLog.outcome(response: response, error: error, url: req.url)
                self?.queue.async {
                    guard let self else { return }
                    self.settle(outcome, wasTest: true)
                    if case .delivered = outcome { self.flushLocked() }
                }
            }.resume()
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
            guard self.enabled else {
                // Do NOT drop it. Launch-time events are posted before the toggle is read — the
                // BGTask registration, the legacy-session retirement, the bundle-identity stamp — and
                // silently discarding them has now cost three separate diagnostics, each time reading
                // as "the feature didn't run" when it had run and merely gone unrecorded. Hold a small
                // window and replay on enable; a session that never enables logging just discards it.
                self.pending.append(line)
                if self.pending.count > 80 { self.pending.removeFirst(self.pending.count - 80) }
                return
            }
            self.buffer.append(line)
            if self.buffer.count > 400 { self.buffer.removeFirst(self.buffer.count - 400) }
            self.tail.append(line)
            if self.tail.count > 60 { self.tail.removeFirst(self.tail.count - 60) }
            // Mirror the tail to disk on *every* line (not just the ~10s network flush) so a hard crash's
            // final moments — e.g. the log line right before a VideoToolbox SIGABRT — are always recovered
            // on next launch. The tail is only 60 short lines, so the write is cheap.
            try? self.tail.joined(separator: "\n").write(to: self.tailFile, atomically: true, encoding: .utf8)
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
        // Back off after a failed send (429 / refused / unreachable) instead of hammering the server every
        // 10 s. Lines stay buffered meanwhile; `sendTest()` and a config change clear the back-off.
        guard Date() >= backoffUntil else { return }
        guard !buffer.isEmpty else { return }

        // Roll the daily message counter over at UTC midnight.
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        if day != sentDayStamp {
            sentDayStamp = day; sentToday = 0; budgetWarned = false
            if health.budgetPaused { health.budgetPaused = false; publish() }
        }

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

        // While the last send failed, probe with ONE message — a still-broken server / quota answers one
        // request instead of a burst — and keep the rest buffered until it gets through.
        let probing = health.consecutiveFailures > 0
        for (i, chunk) in chunks.enumerated() {
            if probing && i > 0 {
                buffer.insert(contentsOf: chunks[i...], at: 0)
                trimBufferKeepingFront()
                return
            }
            // Daily budget guard: rather than 429-hammer the public server, re-buffer the remainder and
            // stop for now (it drains on the next UTC day, or immediately on a self-hosted server).
            if sentToday >= dailyMessageBudget {
                if !budgetWarned {
                    budgetWarned = true
                    tail.append("⚠︎ ntfy daily message budget (\(dailyMessageBudget)) reached — pausing sends")
                }
                if !health.budgetPaused { health.budgetPaused = true; publish() }
                buffer.insert(contentsOf: chunks[i...], at: 0)
                trimBufferKeepingFront()
                return
            }
            sentToday += 1
            postChunk(chunk)
        }
    }

    /// POST one ≤4096-byte message; on failure (e.g. 429) refund the budget, re-queue it for the next flush
    /// and record the failure in the delivery health (which also sets the back-off).
    private func postChunk(_ body: String) {
        let req = makeRequest(method: "POST", body: Data(body.utf8), contentType: "text/plain")
        session.dataTask(with: req) { [weak self] _, response, error in
            let outcome = RemoteLog.outcome(response: response, error: error, url: req.url)
            self?.queue.async {
                guard let self else { return }
                if case .failed = outcome {
                    self.sentToday = max(0, self.sentToday - 1)   // it didn't actually land
                    self.buffer.insert(body, at: 0)
                    self.trimBufferKeepingFront()
                }
                self.settle(outcome)
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

    /// Non-blocking "send what's buffered now". The periodic flush runs on a `DispatchSourceTimer`,
    /// which does NOT fire while the app is suspended — so everything logged during a background
    /// transfer sits in the buffer until the app runs again. Call this on the background/foreground
    /// transitions so a minimized download's trace actually leaves the device at the first opportunity
    /// instead of aging out of the 400-line ring buffer.
    func flushNow() {
        queue.async { [weak self] in self?.flushLocked() }
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

    /// POST one message from the log queue. A failure puts the body back in the buffer (it is re-sent on a
    /// later flush) and is recorded in the delivery health; `wait` blocks the caller for the answer.
    private func post(_ body: String, wait: TimeInterval?) {
        let req = makeRequest(method: "POST", body: Data(body.utf8), contentType: "text/plain")
        let sem = wait == nil ? nil : DispatchSemaphore(value: 0)
        session.dataTask(with: req) { [weak self] _, response, error in
            let outcome = RemoteLog.outcome(response: response, error: error, url: req.url)
            self?.queue.async {
                guard let self else { return }
                if case .failed = outcome {
                    self.buffer.insert(body, at: 0)
                    self.trimBufferKeepingFront()
                }
                self.settle(outcome)
            }
            sem?.signal()
        }.resume()
        if let sem, let wait { _ = sem.wait(timeout: .now() + wait) }
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
        // (request is built on the log queue — the access token cache lives there)
        let name = "shot-\(Int(Date().timeIntervalSince1970)).jpg"
        let asciiCaption = caption.unicodeScalars.filter { $0.isASCII }.map(String.init).joined()
        log("📷 uploading screenshot \(name) (\(data.count / 1024) KB)…")
        queue.async {
            let req = self.makeRequest(method: "PUT", body: data, contentType: "image/jpeg") { req in
                req.setValue(name, forHTTPHeaderField: "Filename")
                // ntfy header values must be ASCII; strip anything else out of the caption title.
                if !asciiCaption.isEmpty { req.setValue(asciiCaption, forHTTPHeaderField: "Title") }
            }
            self.session.dataTask(with: req) { [weak self] respData, response, error in
                let outcome = RemoteLog.outcome(response: response, error: error, url: req.url)
                if case .delivered = outcome {
                    // Echo the hosted attachment URL into the text stream so it can be fetched back.
                    let url = respData
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .flatMap { ($0["attachment"] as? [String: Any])?["url"] as? String }
                    self?.log("📷 screenshot posted\(url.map { " → \($0)" } ?? "")")
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self?.log("📷 screenshot upload failed (code \(code) \(error?.localizedDescription ?? ""))")
                }
                self?.queue.async {
                    // 400 / 413 mean "this attachment is not accepted", not "the server is unreachable" —
                    // they say nothing about whether the text log is getting through.
                    if case .failed(let failure, _) = outcome, case .http(let status) = failure.kind,
                       status == 400 || status == 413 { return }
                    self?.settle(outcome)
                }
            }.resume()
        }
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

/// How the log stream's delivery is going — what Settings → Diagnostics shows. A plain value: `RemoteLog`
/// builds it on its own serial queue and hands copies to the main actor (`RemoteLogStatus`).
struct RemoteLogHealth: Sendable, Equatable {
    struct Failure: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            /// The server answered, but not with 2xx.
            case http(Int)
            /// No usable answer (offline, DNS, TLS, timeout …) — a plain-English reason.
            case transport(String)
        }
        var kind: Kind
        var at: Date
        /// Host the post was addressed to, so the wording can name the public server specifically.
        var host: String
    }

    var lastSuccess: Date?
    var lastFailure: Failure?
    /// Sends failed since the last success; 0 = healthy.
    var consecutiveFailures = 0
    /// Today's message budget is used up, so sends are held until UTC midnight.
    var budgetPaused = false
    /// A "Send Test" is waiting for its answer.
    var testInFlight = false

    /// One plain-English status line; `isProblem` is true when nothing is getting through.
    func line(now: Date) -> (text: String, isProblem: Bool) {
        if testInFlight { return ("Sending a test message…", false) }
        if consecutiveFailures > 0, let failure = lastFailure {
            return ("Not sending — " + Self.reason(failure) + ".", true)
        }
        if budgetPaused {
            return ("Paused — today's message limit is used up. Sending resumes at midnight UTC.", true)
        }
        if let lastSuccess {
            return ("Sent " + Self.ago(now.timeIntervalSince(lastSuccess)), false)
        }
        return ("Nothing sent yet. Tap Send Test to check the connection.", false)
    }

    private static func reason(_ failure: Failure) -> String {
        switch failure.kind {
        case .transport(let why):
            return "can't reach the server (\(why))"
        case .http(let status):
            switch status {
            case 429:
                return failure.host == "ntfy.sh"
                    ? "ntfy.sh's daily limit for your internet connection is used up (429). Use your own server"
                    : "the server is limiting how fast this phone can send (429). Retrying shortly"
            case 403:
                return "the server refused this topic (403). It needs permission or an access token"
            case 401:
                return "the server wants an access token, or doesn't accept this one (401)"
            case 404:
                return "the server doesn't know this address (404). Check the server and topic"
            default:
                return "the server answered with an error (\(status)). Retrying shortly"
            }
        }
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 2 { return "just now" }
        if s < 60 { return "\(s) s ago" }
        if s < 3600 { return "\(s / 60) min ago" }
        return "\(s / 3600) h ago"
    }
}

/// Main-actor mirror of `RemoteLog`'s delivery health, for SwiftUI. `RemoteLog` runs on its own serial
/// queue; it only ever writes here through `apply(_:)` on the main actor.
@MainActor
@Observable
final class RemoteLogStatus {
    static let shared = RemoteLogStatus()
    private(set) var health = RemoteLogHealth()
    private init() {}

    func apply(_ snapshot: RemoteLogHealth) {
        if snapshot != health { health = snapshot }
    }
}
