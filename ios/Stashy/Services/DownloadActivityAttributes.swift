import ActivityKit
import Foundation

/// Shared contract between the app and its WidgetKit extension. Keep this deliberately small: ActivityKit
/// limits an activity's combined static and dynamic payload to 4 KB.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case downloading
            case waitingForNetwork
            case preparing
        }

        var phase: Phase
        /// What is being downloaded. Empty means "don't show a name" — either nothing is known, or
        /// Privacy Mode is on, in which case `DownloadManager` deliberately sends nothing rather than
        /// something redactable. Clamped to 48 characters at the source: ActivityKit caps an activity's
        /// combined static + dynamic payload at 4 KB.
        var title: String = ""
        /// Bytes on disk and the file's full size, so the card can say "744 MB of 4.0 GB" rather than
        /// only a percentage. 0 total means the source had no Content-Length.
        var receivedBytes: Int64 = 0
        var totalBytes: Int64 = 0
        /// Latest measured bytes/sec. 0 when not moving; the card then omits the speed rather than
        /// freezing a stale figure.
        var speed: Double = 0
        /// Real progress at `updatedAt`. nil means the source has no Content-Length.
        var progress: Double?
        /// A time projection derived from the latest measured byte speed. The Live Activity can animate this
        /// interval while the app is suspended; every real URLSession update replaces the projection.
        var estimatedStart: Date?
        var estimatedEnd: Date?
        var updatedAt: Date
        var status: String
        var activeJobCount: Int
    }

    /// A single activity follows the current highest-priority transfer and may switch between queued jobs.
    let sessionID: UUID
}
