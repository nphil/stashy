import Foundation
import Network

/// A minimal loopback HTTP/1.1 server (127.0.0.1, OS-assigned port) that serves a single local file
/// with `Range` support. It's how AVPlayer will stream + seek a file we produce on-device (the remuxed
/// fragmented MP4) over a normal HTTP URL — localhost is microsecond latency, and a server is simply the
/// most robust way to give AVPlayer standard range/seek semantics without a third-party dependency.
///
/// This first cut serves a *fully-written* file (validated via `LoopbackProbe`). Serving a still-growing
/// file (block a range request until the remux produces it) is the next step, alongside AVPlayer wiring.
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stashy.loopback", attributes: .concurrent)
    private var listener: NWListener?
    private let fileURL: URL
    private let contentType: String
    /// Bytes safely readable from the file right now. Defaults to the on-disk size (static file); for a
    /// progressively-remuxed file this returns the producer's verified write position.
    private let availableBytes: @Sendable () -> Int64
    /// Best-known total content length (the source size estimate for a remux, exact once finished).
    private let totalBytes: @Sendable () -> Int64
    /// Whether production is finished (so a range past `availableBytes` is a true EOF, not "wait").
    private let isComplete: @Sendable () -> Bool

    init(fileURL: URL,
         contentType: String = "video/mp4",
         availableBytes: (@Sendable () -> Int64)? = nil,
         totalBytes: (@Sendable () -> Int64)? = nil,
         isComplete: (@Sendable () -> Bool)? = nil) {
        self.fileURL = fileURL
        self.contentType = contentType
        let onDiskSize: @Sendable () -> Int64 = {
            ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        self.availableBytes = availableBytes ?? onDiskSize
        self.totalBytes = totalBytes ?? onDiskSize
        self.isComplete = isComplete ?? { true }
    }

    /// Start listening; returns the URL a client should request. Blocks briefly until the OS assigns a port.
    func start() throws -> URL {
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)

        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "LoopbackServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no port assigned"])
        }
        return URL(string: "http://127.0.0.1:\(port)/media")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    /// Carries an NWConnection through Network's (@Sendable) handler closures under strict concurrency
    /// without depending on NWConnection's own Sendable conformance.
    private struct Conn: @unchecked Sendable { let c: NWConnection }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(Conn(c: conn), accumulated: Data())
    }

    /// Read until the end of the HTTP headers (\r\n\r\n), then respond. We don't need the body.
    private func readRequest(_ box: Conn, accumulated: Data) {
        box.c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { box.c.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(box, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil, !isComplete, buffer.count < 64 * 1024 {
                self.readRequest(box, accumulated: buffer)
            } else {
                box.c.cancel()
            }
        }
    }

    private func respond(_ box: Conn, header: String) {
        let t0 = Date()
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let method = requestLine.split(separator: " ").first.map { String($0).uppercased() } ?? "GET"
        // Parse "Range: bytes=start-end" (end optional).
        var start: Int64 = 0
        var requestedEnd: Int64?
        var partial = false
        if let rangeLine = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.firstIndex(of: "=") {
            let spec = rangeLine[rangeLine.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let first = bounds.first, let s = Int64(first.trimmingCharacters(in: .whitespaces)) {
                start = max(0, s)
                partial = true
                if bounds.count > 1, let e = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) { requestedEnd = e }
            }
        }

        let deadline = Date().addingTimeInterval(30)
        // Phase 1: don't answer until we know a size estimate AND have produced the start byte. Otherwise
        // AVPlayer's first request races ahead of the just-started remux and gets a spurious 416 — which
        // fails the item and (systematically) drops every file to the HLS fallback.
        while !isComplete(), totalBytes() <= 0 || availableBytes() <= start, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        var total = max(totalBytes(), availableBytes())
        if isComplete() { total = availableBytes() }
        var end = min(requestedEnd ?? (total - 1), total - 1)

        // Phase 2: a ranged request may want bytes past what's produced — wait for the remux to reach them.
        while partial, end >= availableBytes(), !isComplete(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let readable = availableBytes()
        if isComplete() { total = readable }
        end = min(end, readable - 1)

        let reqEnd = requestedEnd.map { String($0) } ?? "end"
        let waited = Int(Date().timeIntervalSince(t0) * 1000)

        guard readable > 0, start < readable, start <= end else {
            note("\(method) \(start)-\(reqEnd) →416 avail=\(readable) \(waited)ms")
            send(box, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }

        let length = end - start + 1
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(total)\r\n" }
        head += "Content-Type: \(contentType)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if method != "HEAD", let chunk = readFile(offset: start, length: Int(length)) {
            payload.append(chunk)
        }
        note("\(method) \(start)-\(reqEnd) →\(partial ? 206 : 200) \(length)B/\(total) \(waited)ms")
        send(box, payload)
    }

    // MARK: - Request log (diagnostics)

    private let logLock = NSLock()
    private var requestLog: [String] = []

    private func note(_ line: String) {
        logLock.withLock {
            requestLog.append(line)
            if requestLog.count > 16 { requestLog.removeFirst(requestLog.count - 16) }
        }
    }

    /// A compact log of the most recent AVPlayer requests (range → status, bytes, wait time) — reveals
    /// e.g. a tail/moov seek that the growing file can't satisfy and stalls on.
    func recentRequests() -> [String] { logLock.withLock { requestLog } }

    private func readFile(offset: Int64, length: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: UInt64(offset))
            return try fh.read(upToCount: length)
        } catch {
            return nil
        }
    }

    private func send(_ box: Conn, _ data: Data) {
        box.c.send(content: data, completion: .contentProcessed { _ in box.c.cancel() })
    }
}

/// Self-test for the loopback path: remux a few MB of the source to a temp file, serve it over the
/// loopback server, fetch the opening bytes back over HTTP, and confirm it's a valid (fragmented) MP4.
/// Proves the remux→file→server→client chain end-to-end on-device before AVPlayer is pointed at it.
struct LoopbackProbe {
    let url: URL

    func run() async -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stashy-loopback-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: temp) }

        // Remux ~8 MB to the temp file (enough for moov + first fragments).
        let summary = await FFmpegRemuxer(url: url, fileURL: temp, cap: 1 << 23, timeout: 16).remuxSummary()
        let size = ((try? FileManager.default.attributesOfItem(atPath: temp.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return "no file produced (\(summary))" }

        let server = LoopbackServer(fileURL: temp)
        let serverURL: URL
        do { serverURL = try server.start() } catch { return "server start failed: \(error.localizedDescription)" }
        defer { server.stop() }

        var request = URLRequest(url: serverURL)
        request.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let box = data.count >= 8 ? String(decoding: data[4..<8], as: UTF8.self) : "?"
            let valid = (box == "ftyp" || box == "styp")
            return "HTTP \(code) · first box '\(box)' \(valid ? "✓" : "✗") · file \(size) B"
        } catch {
            return "fetch failed: \(error.localizedDescription)"
        }
    }
}
