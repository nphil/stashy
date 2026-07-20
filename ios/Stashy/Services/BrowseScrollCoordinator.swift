import Foundation

/// One app-wide motion flag for the library grids, plus the entry point for debug-only cadence telemetry.
/// Cards and pagination deliberately remain live during inertia; DownloadManager alone reads `isScrolling`
/// to skip its frequent UI-only progress publication while the grid is moving.
///
/// Deliberately not Observable. Changing scroll phase must not itself invalidate every visible card.
@MainActor
final class BrowseScrollCoordinator {
    static let shared = BrowseScrollCoordinator()

    private(set) var isScrolling = false
    private init() {}

    func setScrolling(_ scrolling: Bool, surface: String, phase: String) {
        // The monitor is a no-op unless the owner's opt-in RemoteLog switch is enabled.
        BrowseScrollPerformanceMonitor.shared.setScrolling(
            scrolling, surface: surface, phase: phase
        )
        guard scrolling != isScrolling else { return }
        isScrolling = scrolling
    }

    func recordThumbnailPublication(loadMilliseconds: Double, memoryHit: Bool) {
        BrowseScrollPerformanceMonitor.shared.recordThumbnailPublication(
            loadMilliseconds: loadMilliseconds,
            memoryHit: memoryHit
        )
    }

    func recordPageAppend(itemCount: Int, loadMilliseconds: Double) {
        BrowseScrollPerformanceMonitor.shared.recordPageAppend(
            itemCount: itemCount,
            loadMilliseconds: loadMilliseconds
        )
    }
}
