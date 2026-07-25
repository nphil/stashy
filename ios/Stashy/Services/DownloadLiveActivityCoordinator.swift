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
            // DISTINCT from the `.denied` message below, deliberately. These are different faults with
            // different fixes — a switch that is off, versus iOS reporting the switch ON and refusing
            // anyway — and an earlier build returned the same string for both, making the one report
            // that could tell them apart unreadable.
            return "Live Activities are switched off for Stashy. Turn them on in Settings › Stashy › "
                + "Live Activities (reinstalling the app resets this)."
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
                if case ActivityAuthorizationError.denied = error { return Self.deniedMessage }
                let nsError = error as NSError
                return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
            }
        }
    }

    /// ActivityKit reports this as "the user has denied activities for this target", which reads as an
    /// accusation when the cause is usually elsewhere: either the per-app permission (reinstalling
    /// resets it) or, on a sideloaded build, a signer that broke the widget extension.
    /// Only for the case where iOS says activities ARE enabled and ActivityKit refuses anyway. That
    /// combination rules the permission out, so the message points where the fault actually is.
    static var deniedMessage: String {
        "iOS reports Live Activities as enabled for Stashy but refused to start one — which points at "
        + "the widget extension rather than the setting. Bundle: \(bundleDiagnostic())"
    }

    /// What the INSTALLED app actually looks like — the build is only half the story for a sideloaded
    /// app. An on-device signer can rewrite the host's bundle id, strip `PlugIns/`, or re-sign the
    /// extension so its id is no longer nested under the host's. Any of those makes ActivityKit refuse
    /// with `.denied` while iOS Settings still shows Live Activities switched on, which is otherwise
    /// impossible to tell apart from a permission problem.
    static func bundleDiagnostic() -> String {
        let host = Bundle.main.bundleIdentifier ?? "unknown"
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: plugins, includingPropertiesForKeys: nil),
              let appex = entries.first(where: { $0.pathExtension == "appex" }) else {
            return "\(host) — widget extension MISSING from the installed app (the signer stripped it)"
        }
        let extensionID = Bundle(url: appex)?.bundleIdentifier ?? "unreadable"
        guard extensionID.hasPrefix(host + ".") else {
            return "\(host) + \(extensionID) — extension id is NOT nested under the app id, so iOS "
                + "won't pair them (re-sign without changing bundle ids)"
        }
        return "\(host) + \(extensionID) — looks correct"
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
