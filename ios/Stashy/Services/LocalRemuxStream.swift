import Foundation

/// The on-device remux → AVPlayer feed. Remuxes the source to a *fragmented MP4* temp file in the
/// background, indexes that growing file into an **HLS byte-range playlist** (`FMP4Index`), and serves
/// both the playlist and the file's byte ranges over a loopback HTTP server. AVPlayer opens the loopback
/// `.m3u8` and streams it natively — discrete bounded segment requests + a growing playlist — which is
/// the model AVPlayer actually supports (a single open-ended progressive download is not).
@MainActor
final class LocalRemuxStream {
    private let remuxer: FFmpegRemuxer
    private let index: FMP4Index
    private let server: LoopbackServer
    private let tempURL: URL
    private var localURL: URL?

    init(source: URL, duration: Double) {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stashy-stream-\(UUID().uuidString).mp4")
        let r = FFmpegRemuxer(url: source, fileURL: tempURL, cap: .max, timeout: 3600)
        remuxer = r
        let idx = FMP4Index(
            fileURL: tempURL,
            available: { Int64(r.producedBytes) },
            isComplete: { r.isFinished },
            totalDuration: duration
        )
        index = idx
        server = LoopbackServer(
            fileURL: tempURL,
            availableBytes: { Int64(r.producedBytes) },
            isComplete: { r.isFinished },
            playlist: { idx.playlist(mediaName: "media.mp4") }
        )
    }

    /// Begin remuxing + serving; returns the loopback `.m3u8` URL AVPlayer should play. Throws only if the
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

    /// Snapshot of remux + index progress + the server's recent requests, for the Stats overlay when
    /// diagnosing a stall/fallback.
    func diagnostics() -> [String] {
        ["produced \(remuxer.producedBytes)B · src \(remuxer.sourceByteSize)B · done=\(remuxer.isFinished)",
         index.debugSummary()]
            + server.recentRequests()
    }
}
