import Foundation

/// One app-wide idle boundary for the two library grids. Work that changes grid structure or publishes
/// new image textures waits here while the user's finger or inertial deceleration is active. This keeps
/// frame delivery even: a cold thumbnail or next-page response can finish at any time, but it cannot land
/// in SwiftUI halfway through a scroll frame.
///
/// Deliberately not Observable. Changing scroll phase must not itself invalidate every visible card.
@MainActor
final class BrowseScrollCoordinator {
    static let shared = BrowseScrollCoordinator()

    private(set) var isScrolling = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    func setScrolling(_ scrolling: Bool) {
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
}
