import Foundation

/// A scene whose video file is gone from the server's disk. Stash still lists it, with its cover, previews and
/// sprite sheet (those are cached), but every stream for it answers 404, and the player's own error ("The
/// requested URL was not found on this server.") says neither why nor that trying again is pointless.
enum MissingFile {
    static let title = "Video file missing"
    static let detail = "Stash can't find this video's file on the server. It may have been moved or deleted outside Stash."

    /// The scene file's own stream, whichever stream is being played: a playlist or a transcode can be answered
    /// without the file, but this address can't. Nil for a downloaded file, or an address that isn't Stash's.
    static func probeURL(for stream: URL) -> URL? {
        guard !stream.isFileURL else { return nil }
        let file = stream.deletingPathExtension()
        let parts = file.pathComponents
        guard parts.count >= 3, parts.last == "stream", parts[parts.count - 3] == "scene" else { return nil }
        return file
    }

    /// Whether the server answers 404 for `url`. Asks for one byte and drops the connection as soon as the headers
    /// land, so none of the video is transferred; anything but a clear 404 (no answer, a refusal, a redirect)
    /// counts as "not known to be missing". Only called after playback has failed, never before it.
    static func serverSaysMissing(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request) else { return false }
        stream.task.cancel()
        return (response as? HTTPURLResponse)?.statusCode == 404
    }
}
