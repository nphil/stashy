import ActivityKit
import Foundation

/// Owns Stashy's single transfer Live Activity. A single activity avoids flooding the Lock Screen during a
/// bulk download; its content switches to the most relevant active item and reports the total active count.
@MainActor
final class DownloadLiveActivityCoordinator {
    private var activity: Activity<DownloadActivityAttributes>?
    private var lastState: DownloadActivityAttributes.ContentState?
    var hasActivity: Bool { activity != nil }

    init() {
        // Reattach after a system/background relaunch instead of starting a duplicate activity.
        activity = Activity<DownloadActivityAttributes>.activities.first
    }

    /// Returns a user-displayable diagnostic only when ActivityKit rejects the request. Updates to an
    /// existing activity are fire-and-forget and therefore return nil.
    func sync(_ state: DownloadActivityAttributes.ContentState?) -> String? {
        guard let state else {
            end()
            return nil
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "ActivityKit reports that Live Activities are disabled for Stashy."
        }
        guard state != lastState else { return nil }
        lastState = state

        // A known-size transfer carries a system-animated ETA projection, so keep it fresh through that
        // estimate even if iOS suspends the app. Unknown-size streams become explicitly stale sooner.
        let staleDate = min(
            state.estimatedEnd?.addingTimeInterval(60) ?? Date.now.addingTimeInterval(90),
            Date.now.addingTimeInterval(8 * 60 * 60)
        )
        let content = ActivityContent(
            state: state,
            staleDate: staleDate,
            relevanceScore: 100
        )
        if let activity {
            Task { await activity.update(content) }
            return nil
        } else {
            do {
                activity = try Activity.request(
                    attributes: DownloadActivityAttributes(sessionID: UUID()),
                    content: content,
                    pushType: nil
                )
                return nil
            } catch {
                // Live Activities may be disabled per-app or unavailable under the current signing/profile.
                // The transfer itself must never depend on this optional presentation layer.
                lastState = nil
                let nsError = error as NSError
                return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
