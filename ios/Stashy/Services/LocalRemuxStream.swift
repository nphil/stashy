import Foundation

/// The on-device remux → AVPlayer feed. Streams the source (remuxed to a fragmented MP4) into a temp
/// file in the background, serves that *growing* file over a loopback HTTP server with Range support,
/// and hands back the local URL for AVPlayer. The remux runs ahead of playback at copy speed; the
/// server blocks a range request until the bytes it needs have been produced — giving AVPlayer fast
/// start (it can begin as soon as the moov + first fragment are written) plus seeking.
@MainActor
final class LocalRemuxStream {
    private let remuxer: FFmpegRemuxer
    private let server: LoopbackServer
    private let tempURL: URL
    private var localURL: URL?

    init(source: URL) {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stashy-stream-\(UUID().uuidString).mp4")
        let r = FFmpegRemuxer(url: source, fileURL: tempURL, cap: .max, timeout: 3600)
        remuxer = r
        server = LoopbackServer(
            fileURL: tempURL,
            availableBytes: { Int64(r.producedBytes) },
            totalBytes: { r.sourceByteSize },
            isComplete: { r.isFinished }
        )
    }

    /// Begin remuxing + serving; returns the loopback URL AVPlayer should play. Throws only if the
    /// server can't bind (the caller then falls back to HLS).
    func start() throws -> URL {
        if let localURL { return localURL }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let url = try server.start()
        localURL = url
        let r = remuxer
        Task.detached { _ = await r.remuxSummary() }   // runs the full remux to the temp file
        return url
    }

    func stop() {
        remuxer.abort()   // promptly aborts the in-flight remux via the interrupt deadline
        server.stop()
        try? FileManager.default.removeItem(at: tempURL)
    }
}
