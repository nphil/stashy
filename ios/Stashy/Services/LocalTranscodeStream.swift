import Foundation

/// On-device **streaming transcode** → AVPlayer feed (roadmap M-A). The sibling of `LocalRemuxStream`:
/// same delivery — a growing fragmented MP4 indexed into a byte-range HLS playlist and served over the
/// loopback — but the producer is `FFmpegStreamTranscoder` (decode → scale → H.264 re-encode) instead of
/// a stream-copy remux. Used for the "Apple can't decode it at all" bucket (VP9, AV1 without a HW
/// decoder, 10-bit 4:2:2/4:4:4 HEVC) when the on-device transcode is preferred over loading the server.
///
/// Dormant until routing (Stage 3) starts building it; nothing references it yet.
@MainActor
final class LocalTranscodeStream: LocalPlaybackStream {
    private let transcoder: FFmpegStreamTranscoder
    private let index: FMP4Index
    private let server: LoopbackServer
    private let tempURL: URL
    private var localURL: URL?
    /// Live local playhead (written ~10 Hz by the model, read by the transcoder to pace production).
    private let playheadBox = AtomicDouble()

    init(source: URL, duration: Double, startTime: Double = 0, maxDimension: Int?) {
        // Prefix begins with "stashy-stream-" so the existing stale-temp sweep at launch cleans it too.
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stashy-stream-xcode-\(UUID().uuidString).mp4")
        let box = playheadBox
        let t = FFmpegStreamTranscoder(url: source, fileURL: tempURL, startTime: startTime,
                                       maxDimension: maxDimension, playhead: { box.value })
        transcoder = t
        // Zero-based from `startTime`, so this stream's own timeline runs for the remaining duration.
        let idx = FMP4Index(
            fileURL: tempURL,
            available: { Int64(t.producedBytes) },
            isComplete: { t.isFinished },
            totalDuration: max(0, duration - startTime)
        )
        index = idx
        server = LoopbackServer(
            fileURL: tempURL,
            availableBytes: { Int64(t.producedBytes) },
            isComplete: { t.isFinished },
            playlist: { idx.playlist(mediaName: "media.mp4") }
        )
    }

    /// Begin transcoding + serving; returns the loopback `.m3u8` URL AVPlayer should play. Throws only if
    /// the server can't bind (the caller then falls back to HLS).
    func start() throws -> URL {
        if let localURL { return localURL }
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let url = try server.start()
        localURL = url
        let t = transcoder
        Task.detached { _ = await t.transcodeSummary() }   // runs the full streaming transcode
        return url
    }

    func stop() {
        transcoder.abort()
        server.stop()
        try? FileManager.default.removeItem(at: tempURL)
    }

    func updatePlayhead(_ seconds: Double) { playheadBox.value = seconds }

    func diagnostics() -> [String] {
        let ahead = transcoder.producedSeconds - playheadBox.value
        return ["transcoded \(transcoder.producedBytes)B · \(Int(transcoder.producedSeconds))s · ahead \(Int(ahead))s · done=\(transcoder.isFinished)",
                index.debugSummary()]
            + server.recentRequests()
    }
}
