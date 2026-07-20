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
