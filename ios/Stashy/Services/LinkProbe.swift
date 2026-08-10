import Foundation

/// What a pasted link actually points at, decided by ASKING THE HOST for headers rather than trusting
/// the path extension. A `.mp4` URL that 302s onto a login wall, a signed link whose extension is
/// hidden in a query string, a CDN that serves video as `application/octet-stream` — the extension
/// gets all three wrong, and a wrong verdict means the server happily fetches an HTML page into the
/// library. `.page` is the safe default: everything that isn't provably a media byte stream lands
/// there, and the browser resolver can still send it on.
enum LinkKind: Sendable, Equatable {
    /// Nothing usable typed yet.
    case empty
    /// A probe is in flight.
    case checking
    /// A media byte stream the server can fetch as-is. `verified` is false when the host never
    /// answered and the verdict is only the path extension talking.
    case direct(filename: String?, verified: Bool)
    /// Anything else: an HTML page, a gate, an error shell. Needs the browser (or the server's
    /// extractor) rather than a straight byte fetch.
    case page(verified: Bool)

    var isChecking: Bool { self == .checking }
}

/// Header-only classifier for the fetch sheet. Never reads a response body: the probe cancels the
/// task the moment the headers land, so pointing this at a 4 GB file costs one round trip.
enum LinkProbe {
    /// Extensions that stand in for a verdict when the host refuses to answer at all.
    static let mediaExtensions: Set<String> = [
        "mp4", "m4v", "mkv", "webm", "mov", "avi", "ts", "m2ts", "mpg", "mpeg", "wmv", "flv", "ogv",
        "m3u8", "mpd", "mp3", "m4a", "aac", "flac", "wav", "opus"
    ]
    /// Playlist/manifest content types: not a single file, but still a stream the server can pull.
    static let manifestTypes: Set<String> = [
        "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl", "audio/x-mpegurl",
        "application/dash+xml"
    ]
    /// Same Safari UA the resolver browses with, so a host that varies its response by client can't
    /// tell the probe apart from the browse that follows it.
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    private enum Outcome {
        case verdict(LinkKind)
        /// The host answered, but with an error status — worth one retry by another method.
        case refused
        /// No answer at all (offline, DNS, timeout). Retrying costs another full timeout for nothing.
        case unreachable
    }

    /// HEAD first; hosts that answer it with 403/405 (plenty do) get a second look with a ranged GET.
    /// A host that never answers is not retried — the sheet would sit on "Checking" for two timeouts —
    /// and the extension has the last word, flagged `verified: false`.
    static func classify(_ url: URL) async -> LinkKind {
        switch await probe(url, method: "HEAD") {
        case .verdict(let kind): return kind
        case .unreachable: return guess(url)
        case .refused:
            if case .verdict(let kind) = await probe(url, method: "GET") { return kind }
            return guess(url)
        }
    }

    private static func guess(_ url: URL) -> LinkKind {
        guard mediaExtensions.contains(url.pathExtension.lowercased()) else {
            return .page(verified: false)
        }
        return .direct(filename: url.lastPathComponent, verified: false)
    }

    private static func probe(_ url: URL, method: String) async -> Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        // The GET pass asks for one byte, and the stream is cancelled below before it is read anyway:
        // belt and braces against a host that ignores Range and starts spooling the whole file.
        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }

        // `bytes(for:)` returns as soon as the HEADERS land; cancelling the task then means no body is
        // ever transferred. `data(for:)` would buffer the whole response — i.e. download the movie.
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request) else {
            return .unreachable
        }
        stream.task.cancel()
        guard let http = response as? HTTPURLResponse else { return .unreachable }
        guard http.statusCode < 400 else { return .refused }
        return .verdict(kind(for: http, requested: url))
    }

    private static func kind(for http: HTTPURLResponse, requested: URL) -> LinkKind {
        // `http.url` is the FINAL url — after every redirect the host applied, which is the one whose
        // extension is worth reading.
        let finalURL = http.url ?? requested
        let type = (http.mimeType ?? "").lowercased()
        let disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "")
        let name = filename(fromDisposition: disposition)
            ?? (finalURL.pathExtension.isEmpty ? nil : finalURL.lastPathComponent)
        let ext = (name.map { ($0 as NSString).pathExtension } ?? finalURL.pathExtension).lowercased()

        // Markup first and unconditionally: an HTML body is a page no matter what the URL ends in.
        if type.contains("html") || (type.contains("xml") && !manifestTypes.contains(type)) {
            return .page(verified: true)
        }
        if type.hasPrefix("video/") || type.hasPrefix("audio/") || manifestTypes.contains(type) {
            return .direct(filename: name, verified: true)
        }
        // Playlists served as text/plain are common enough to be worth catching; any other text is a page.
        if type.hasPrefix("text/") {
            return ["m3u8", "mpd"].contains(ext)
                ? .direct(filename: name, verified: true)
                : .page(verified: true)
        }
        // Opaque bytes (octet-stream, or any type served as an attachment): a file, unless the name
        // it wants to be saved under is itself markup.
        let isAttachment = disposition.lowercased().contains("attachment")
        if isAttachment || type == "application/octet-stream" || type == "binary/octet-stream" {
            if ["html", "htm", "xhtml", "php", "asp", "aspx"].contains(ext) { return .page(verified: true) }
            return .direct(filename: name, verified: true)
        }
        // A host that sends no type at all decides nothing; let the extension speak, unverified.
        if type.isEmpty {
            return mediaExtensions.contains(ext)
                ? .direct(filename: name, verified: false)
                : .page(verified: false)
        }
        // Everything left (json, images, fonts) is not a media stream. Page is the safe verdict.
        return .page(verified: true)
    }

    /// `filename="clip.mp4"` / `filename*=UTF-8''clip.mp4` out of a Content-Disposition header.
    private static func filename(fromDisposition header: String) -> String? {
        for part in header.split(separator: ";") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            let lower = piece.lowercased()
            var value: String?
            if lower.hasPrefix("filename*=") {
                // RFC 5987: charset'language'percent-encoded-name
                let raw = String(piece.dropFirst("filename*=".count))
                value = raw.split(separator: "'", omittingEmptySubsequences: false).last
                    .map(String.init)?.removingPercentEncoding
            } else if lower.hasPrefix("filename=") {
                value = String(piece.dropFirst("filename=".count))
            }
            guard var name = value else { continue }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            // Never let a host's suggested name climb out of the download directory.
            name = (name as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return nil
    }
}
