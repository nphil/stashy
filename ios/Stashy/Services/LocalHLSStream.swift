import Foundation

/// A local on-device stream feeding AVPlayer over the loopback server. Two implementations:
///   • `LocalHLSStream`   — on-demand, seekable VOD HLS (mp4/mov sources). Preferred.
///   • `LocalRemuxStream` — linear growing-file byte-range HLS (any container; forward-only).
@MainActor
protocol LocalPlaybackStream: AnyObject {
    /// Begin serving; returns the loopback URL AVPlayer should open. Throws only if the server can't bind.
    func start() throws -> URL
    func stop()
    /// Diagnostics for the Stats overlay.
    func diagnostics() -> [String]
}

/// On-demand, **seekable** local HLS: a full VOD playlist (every segment + the total duration known up
/// front) backed by an `HLSSegmentProducer` that remuxes each CMAF segment on demand by input-seeking the
/// source. AVPlayer can seek anywhere instantly — a far-forward scrub fetches one segment (~1–2 s) instead
/// of waiting for a linear remux to grind there. Requires an already-prepared producer (segments known).
@MainActor
final class LocalHLSStream: LocalPlaybackStream {
    private let producer: HLSSegmentProducer
    private let server: LoopbackServer
    private var localURL: URL?

    init(producer: HLSSegmentProducer) {
        self.producer = producer
        let p = producer
        // dataHandler runs on the server's background queue; segment bodies are produced on demand.
        server = LoopbackServer(
            fileURL: URL(fileURLWithPath: "/dev/null"),   // unused in dataHandler mode
            dataHandler: { path in
                if path.hasSuffix(".m3u8") {
                    return ("application/vnd.apple.mpegurl", Data(LocalHLSStream.playlist(for: p).utf8))
                }
                if path == "/init.mp4" {
                    return p.initSegment().map { ("video/mp4", $0) }
                }
                if path.hasPrefix("/seg/"), let i = LocalHLSStream.segmentIndex(path) {
                    return p.segment(i).map { ("video/mp4", $0) }
                }
                return nil
            }
        )
    }

    func start() throws -> URL {
        if let localURL { return localURL }
        let url = try server.start()
        localURL = url
        return url
    }

    func stop() {
        server.stop()
        producer.teardown()
    }

    func diagnostics() -> [String] { producer.diagnostics() + server.recentRequests() }

    // MARK: - VOD playlist (all segments known up front → seek anywhere instantly)

    nonisolated static func playlist(for p: HLSSegmentProducer) -> String {
        let segs = p.segments
        let target = max(1, Int((segs.map(\.duration).max() ?? 6).rounded(.up)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for (i, seg) in segs.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", seg.duration))
            lines.append("seg/\(i).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Parse the segment index from `/seg/<n>.m4s`.
    nonisolated static func segmentIndex(_ path: String) -> Int? {
        guard let last = path.split(separator: "/").last else { return nil }
        let name = last.split(separator: ".").first ?? last
        return Int(name)
    }
}
