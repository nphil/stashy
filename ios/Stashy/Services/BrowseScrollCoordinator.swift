import Foundation

/// One app-wide idle boundary for the library grids. Structural work such as a next-page append may wait
/// here while the user's finger or inertial deceleration is active. Thumbnail work deliberately does not:
/// cards must always show their ThumbHash immediately and replace it with the real cached image as soon as
/// available.
///
/// Deliberately not Observable. Changing scroll phase must not itself invalidate every visible card.
@MainActor
final class BrowseScrollCoordinator {
    static let shared = BrowseScrollCoordinator()

    private(set) var isScrolling = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func setScrolling(_ scrolling: Bool, surface: String, phase: String) {
        // The monitor is a no-op unless the owner's opt-in RemoteLog switch is enabled.
        BrowseScrollPerformanceMonitor.shared.setScrolling(
            scrolling, surface: surface, phase: phase
        )
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
        guard !scrolling else { return }

        let waiters = idleWaiters
        idleWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilIdle() async {
        guard isScrolling else { return }
        await withCheckedContinuation { continuation in
            // Re-check inside the synchronous registration closure so an idle transition can never be
            // missed between the guard and storage.
            if isScrolling {
                idleWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    func recordThumbnailPublication(loadMilliseconds: Double, memoryHit: Bool) {
        BrowseScrollPerformanceMonitor.shared.recordThumbnailPublication(
            loadMilliseconds: loadMilliseconds,
            memoryHit: memoryHit
        )
    }
}
