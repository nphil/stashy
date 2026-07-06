import Foundation

/// A single download choice applied to a whole batch (see `DownloadManager.bulkDownload`). Mirrors the
/// per-scene staging options, but chosen ONCE for many scenes. Purely a value type consumed by the engine
/// and the bulk options sheet — it adds nothing to the existing per-scene download flow.
struct BulkDownloadOptions: Equatable {
    enum Source: Equatable {
        /// The original file, multi-connection (largest, fastest on good WiFi, no server work).
        case original
        /// Stash's built-in server transcode to H.264 at a resolution.
        case serverH264(ServerQuality)
        /// A Stashy Companion (plugin) iPhone-native transcode — HEVC/AV1, small, runs on the server.
        case companion(StashCompanion.Codec, ServerQuality, CompanionQuality)
    }

    var source: Source

    // MARK: Friendly presets (one-tap chips in the sheet)

    /// Keep the original file. Biggest, but no server transcode wait — good over home WiFi.
    static let original = BulkDownloadOptions(source: .original)
    /// iPhone-native HEVC at 1080p, balanced quality. The everyday travel pick.
    static let iphone1080 = BulkDownloadOptions(source: .companion(.hevc, .p1080, .medium))
    /// 720p HEVC, small files — best for lots of clips / tight storage / slow links.
    static let dataSaver720 = BulkDownloadOptions(source: .companion(.hevc, .p720, .low))

    /// True when this batch involves a server-side transcode (serialised on the server, one at a time).
    var isTranscode: Bool {
        if case .original = source { return false }
        return true
    }

    /// A compact human summary for the confirm button / header.
    var summary: String {
        switch source {
        case .original: return "Original file"
        case .serverH264(let r): return "Stash H.264 · \(r.label)"
        case .companion(let c, let r, let q): return "\(c.label) · \(r.label) · \(q.label)"
        }
    }
}
