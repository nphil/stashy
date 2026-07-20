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
        // A person can dismiss the card, or the system can end it under resource pressure. Don't retain a
        // dead handle forever and silently send every later update to an activity that no longer renders.
        if let activity {
            switch activity.activityState {
            case .dismissed, .ended:
                self.activity = nil
                lastState = nil
            case .active, .stale:
                break
            @unknown default:
                self.activity = nil
                lastState = nil
            }
        }
        guard state != lastState else { return nil }
        lastState = state

        // Local background URLSession progress may be coalesced while the app is suspended. The ETA drives
        // system-side interpolation, so don't mark a healthy long download stale merely because its first
        // estimate elapsed before iOS delivered another byte snapshot.
        let staleDate = Date.now.addingTimeInterval(8 * 60 * 60)
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
