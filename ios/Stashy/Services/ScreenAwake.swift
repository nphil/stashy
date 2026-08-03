import UIKit

/// Single owner of `UIApplication.isIdleTimerDisabled`.
///
/// The flag is a global with last-writer-wins semantics, and two features now legitimately hold it:
/// downloads/transcodes (`DownloadManager.keepScreenAwake`) and a connected glasses session — where the
/// phone auto-locking is fatal, because locking kills DisplayPort output and the movie dies mid-scene.
/// With direct writes, a download finishing mid-session would flip `keepScreenAwake` false and re-enable
/// idle sleep while the glasses still needed it. Reason-set semantics make that collision impossible:
/// the display sleeps only when NOBODY needs it awake.
@MainActor
enum ScreenAwake {
    enum Reason: Hashable {
        case downloads
        case glassesSession
    }

    private static var reasons: Set<Reason> = []

    static func set(_ reason: Reason, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
    }
}
