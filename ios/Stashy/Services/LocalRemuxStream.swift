import Foundation

/// A local on-device stream feeding AVPlayer over the loopback server. Currently the only conformer is
/// `LocalRemuxStream` (linear continuous remux → byte-range HLS). Kept as a protocol so the facade can
/// hold `any LocalPlaybackStream` and an alternative delivery can slot in later.
@MainActor
protocol LocalPlaybackStream: AnyObject {
    /// Begin serving; returns the loopback URL AVPlayer should open. Throws only if the server can't bind.
    func start() throws -> URL
    func stop()
    /// Diagnostics for the Stats overlay.
    func diagnostics() -> [String]
    /// Report the current local playback position (seconds) so the remux can pace itself to the playhead.
    func updatePlayhead(_ seconds: Double)
}

/// Thread-safe scalar shared between the main-actor model (writer) and the remux's background thread
/// (reader) so the remuxer can read the live playhead without touching main-actor state.
final class AtomicDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// The on-device remux → AVPlayer feed. Remuxes the source to a *fragmented MP4* temp file in the
/// background, indexes that growing file into an **HLS byte-range playlist** (`FMP4Index`), and serves
/// both the playlist and the file's byte ranges over a loopback HTTP server. AVPlayer opens the loopback
/// `.m3u8` and streams it natively — discrete bounded segment requests + a growing playlist — which is
/// the model AVPlayer actually supports (a single open-ended progressive download is not).
@MainActor
final class LocalRemuxStream: LocalPlaybackStream {
    private let remuxer: FFmpegRemuxer
    private let index: FMP4Index
    private let server: LoopbackServer
    private let tempURL: URL
    private var localURL: URL?
    /// Live local playhead, written by the model (~10 Hz) and read by the remux to pace production.
    private let playheadBox = AtomicDouble()

    init(source: URL, duration: Double, startTime: Double = 0) {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stashy-stream-\(UUID().uuidString).mp4")
        let box = playheadBox
        let r = FFmpegRemuxer(url: source, fileURL: tempURL, cap: .max, timeout: 3600, startTime: startTime,
                              playhead: { box.value })
        remuxer = r
        // This stream is zero-based from `startTime`, so its own timeline runs for the remaining duration.
        let idx = FMP4Index(
            fileURL: tempURL,
            available: { Int64(r.producedBytes) },
            isComplete: { r.isFinished },
            totalDuration: max(0, duration - startTime)
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

    /// Delete stale remux/probe temp files left behind by a crash or force-quit (normal teardown removes
    /// its own). Safe to call at launch — nothing is in use yet.
    nonisolated static func sweepStaleTempFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
        else { return }
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("stashy-stream-") || name.hasPrefix("stashy-loopback-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Snapshot of remux + index progress + the server's recent requests, for the Stats overlay when
    /// diagnosing a stall/fallback.
    func updatePlayhead(_ seconds: Double) { playheadBox.value = seconds }

    func diagnostics() -> [String] {
        let ahead = remuxer.producedSeconds - playheadBox.value
        return ["produced \(remuxer.producedBytes)B · \(Int(remuxer.producedSeconds))s · ahead \(Int(ahead))s · done=\(remuxer.isFinished)",
                index.debugSummary()]
            + server.recentRequests()
    }
}
