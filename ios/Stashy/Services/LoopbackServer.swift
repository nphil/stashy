import Foundation
import Network

/// A minimal loopback HTTP/1.1 server (127.0.0.1, OS-assigned port) that feeds AVPlayer an on-device
/// **HLS** stream of a file we're producing live (the remuxed fragmented MP4). It serves two things:
///   • `/index.m3u8` — a growing byte-range media playlist (from `playlist`), and
///   • any other path (`/media.mp4`) — bounded `Range` reads of the growing file (HTTP 206).
/// Because the playlist only ever references already-produced byte ranges, every media request is for
/// bytes that exist, so each response is a normal bounded 206 with a real Content-Length — the request
/// shape AVPlayer understands. (When `playlist` is nil it degrades to a plain single-file range server,
/// used by `LoopbackProbe`.)
final class LoopbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "stashy.loopback", attributes: .concurrent)
    private var listener: NWListener?
    private let fileURL: URL
    private let contentType: String
    /// Bytes safely readable from the file right now (the producer's verified write position).
    private let availableBytes: @Sendable () -> Int64
    /// Whether production is finished (so a range past `availableBytes` is a true EOF, not "wait").
    private let isComplete: @Sendable () -> Bool
    /// Current HLS media playlist, or nil until enough has been produced. Absent → plain file server.
    private let playlist: (@Sendable () -> String?)?

    init(fileURL: URL,
         contentType: String = "video/mp4",
         availableBytes: (@Sendable () -> Int64)? = nil,
         isComplete: (@Sendable () -> Bool)? = nil,
         playlist: (@Sendable () -> String?)? = nil) {
        self.fileURL = fileURL
        self.contentType = contentType
        let onDiskSize: @Sendable () -> Int64 = {
            ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        self.availableBytes = availableBytes ?? onDiskSize
        self.isComplete = isComplete ?? { true }
        self.playlist = playlist
    }

    /// Start listening; returns the URL AVPlayer should open — the playlist in HLS mode, else the file.
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
        let path = playlist != nil ? "/index.m3u8" : "/media"
        return URL(string: "http://127.0.0.1:\(port)\(path)")!
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
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map { String($0).uppercased() } ?? "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"

        if let playlist, path.hasSuffix(".m3u8") {
            servePlaylist(box, method: method, playlist: playlist)
        } else {
            serveMedia(box, method: method, rangeHeader: lines.first { $0.lowercased().hasPrefix("range:") })
        }
    }

    // MARK: - Playlist

    private func servePlaylist(_ box: Conn, method: String, playlist: @escaping @Sendable () -> String?) {
        // Wait until the playlist has its init segment + first complete fragment (bounded).
        let deadline = Date().addingTimeInterval(15)
        var text = playlist()
        while text == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            text = playlist()
        }
        guard let text else {
            note("→503 playlist not ready")
            send(box, Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let body = Data(text.utf8)
        note("→200 m3u8 \(body.count)B")
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/vnd.apple.mpegurl\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        send(box, Data(head.utf8) + (method == "HEAD" ? Data() : body))
    }

    // MARK: - Media (bounded range reads)

    private func serveMedia(_ box: Conn, method: String, rangeHeader: String?) {
        var start: Int64 = 0
        var end: Int64 = -1
        if let rangeHeader, let eq = rangeHeader.firstIndex(of: "=") {
            let spec = rangeHeader[rangeHeader.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let s = bounds.first.flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }) { start = max(0, s) }
            if bounds.count > 1, let e = Int64(bounds[1].trimmingCharacters(in: .whitespaces)) { end = e }
        }

        // Wait until the requested bytes are produced (they should already be, since the playlist only
        // lists complete ranges — this is just a guard against a race at the growing edge).
        let deadline = Date().addingTimeInterval(15)
        let needed = end >= 0 ? end : start
        while availableBytes() <= needed, !isComplete(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let avail = availableBytes()
        guard start < avail else {
            note("→416 \(start) ≥ \(avail)")
            send(box, Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        if end < 0 || end >= avail { end = avail - 1 }     // open-ended → snapshot to what's produced
        let length = Int(end - start + 1)
        guard let data = readFile(offset: start, length: length), !data.isEmpty else {
            note("→500 read \(start)-\(end)")
            send(box, Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        let total = isComplete() ? "\(avail)" : "*"   // RFC 7233 allows '*' when the full size is unknown
        note("RX \(start)-\(end) →206 \(data.count)B/\(total)")
        var head = "HTTP/1.1 206 Partial Content\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Content-Range: bytes \(start)-\(start + Int64(data.count) - 1)/\(total)\r\n"
        head += "Content-Length: \(data.count)\r\n"
        head += "Connection: close\r\n\r\n"
        send(box, Data(head.utf8) + (method == "HEAD" ? Data() : data))
    }

    // MARK: - IO + diagnostics

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
        // isComplete + .finalMessage marks the whole response as one complete message so the framework
        // flushes all of it before we cancel — otherwise cancel() would truncate a large body.
        box.c.send(content: data, contentContext: .finalMessage, isComplete: true,
                   completion: .contentProcessed { _ in box.c.cancel() })
    }

    private let logLock = NSLock()
    private var requestLog: [String] = []

    private func note(_ line: String) {
        // Kept local (shown in the Stats overlay's recent-requests list). Not streamed to RemoteLog —
        // per-byte-range requests are too frequent and would blow past the ntfy rate limit.
        logLock.withLock {
            requestLog.append(line)
            if requestLog.count > 16 { requestLog.removeFirst(requestLog.count - 16) }
        }
    }

    /// A compact log of the most recent AVPlayer requests — reveals e.g. a range the growing file can't
    /// satisfy yet and stalls on.
    func recentRequests() -> [String] { logLock.withLock { requestLog } }
}

/// Self-test for the loopback path: remux a few MB of the source to a temp file, serve it over the
/// loopback server, fetch the opening bytes back over HTTP, and confirm it's a valid (fragmented) MP4.
/// Proves the remux→file→server→client chain end-to-end on-device.
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
