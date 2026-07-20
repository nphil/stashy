import Foundation
import Observation

/// Generic page-based list loader shared by the scene/performer browse screens (previously three
/// near-identical view models). Holds the accumulated items plus loading/error state, dedupes
/// overlapping pages by id (paginated pages can re-return rows already in the list, which breaks
/// `ForEach` identity), and infinite-scrolls when a near-the-end row appears.
///
/// The query itself lives in the view; the view hands the loader a fresh fetch closure via `reload`
/// whenever the query changes, so the loader stays agnostic of the query type while `loadNextIfNeeded`
/// reuses the most recent fetch to pull the following page.
@Observable
@MainActor
final class PaginatedLoader<T: Identifiable & Sendable> where T.ID: Hashable {
    private(set) var items: [T] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Cheap view hook for page-level prefetch. Incremented only when the item collection is replaced or
    /// appended, so a grid can seed the newest page into its image cache without mapping all IDs per body.
    private(set) var contentRevision = 0

    let pageSize: Int
    private var page = 1
    private var hasMore = true
    private var fetch: (@Sendable (Int, Int) async throws -> (items: [T], total: Int))?
    /// Next-page work is intentionally not observed by SwiftUI. Showing/removing a footer while a fling is
    /// active mutates layout; preemptive pagination should be invisible until the one atomic page append.
    @ObservationIgnored private var nextLoadGeneration: Int?
    /// Bumped on every `reload`. An in-flight fetch whose generation is stale (a newer reload superseded
    /// it) discards its result instead of mutating state — so rapid reloads can't corrupt the list or
    /// leave `isLoading` stuck, which is what crashed the grid under the open filter popover.
    private var generation = 0

    init(pageSize: Int) { self.pageSize = pageSize }

    /// (Re)configure with a fetch closure and load the first page. Call on appear and on every query
    /// change; the closure should capture the current query/client (both must be Sendable). A new reload
    /// supersedes any in-flight load.
    func reload(using fetch: @escaping @Sendable (Int, Int) async throws -> (items: [T], total: Int)) async {
        self.fetch = fetch
        generation += 1
        let gen = generation
        nextLoadGeneration = nil
        isLoading = true
        errorMessage = nil
        page = 1
        hasMore = true
        // Load page 1 WITHOUT clearing the current list first, so a filter/sort change (or pull-to-refresh)
        // doesn't flash an empty grid / full-screen spinner — the old items stay visible until the new page
        // replaces them. (A genuine cold start still shows the spinner, since there are no items yet.) This
        // also removes the flash that showed through the translucent filter panel on a playability switch.
        do {
            let result = try await fetch(1, pageSize)
            guard gen == generation else { return }        // superseded by a newer reload
            items = result.items                            // replace atomically — no blank frame
            contentRevision &+= 1
            hasMore = result.items.count < result.total && !result.items.isEmpty
        } catch {
            guard gen == generation else { return }
            items = []
            contentRevision &+= 1
            hasMore = false
            errorMessage = error.localizedDescription
        }
        if gen == generation { isLoading = false }
    }

    /// Preemptively load the next page once `triggerID` reaches the first quarter of the newest page.
    /// Starting this early gives network + decode enough lead time that a fast fling never hits the end of
    /// the currently materialized content.
    func loadNextIfNeeded(triggerID: T.ID) async {
        guard hasMore, !isLoading, nextLoadGeneration == nil, fetch != nil,
              items.suffix(max(1, pageSize * 3 / 4)).contains(where: { $0.id == triggerID })
        else { return }

        // Device telemetry showed the old idle gate was the visible "scroll stopped" bug: cadence stayed
        // at 120 Hz, but the fling physically reached the end of the 25-item page before its next request
        // was allowed to begin. Fetch immediately; the token coalesces all other near-page triggers.
        let gen = generation
        nextLoadGeneration = gen
        let nextPage = page + 1
        page = nextPage
        let started = Date()
        let appended = await fetchPage(pageNumber: nextPage, gen: gen)
        if nextLoadGeneration == gen { nextLoadGeneration = nil }
        if appended > 0 {
            BrowseScrollCoordinator.shared.recordPageAppend(
                itemCount: appended,
                loadMilliseconds: Date().timeIntervalSince(started) * 1_000
            )
        }
    }

    private func fetchPage(pageNumber: Int, gen: Int) async -> Int {
        guard let fetch else { return 0 }
        do {
            let result = try await fetch(pageNumber, pageSize)
            guard gen == generation else { return 0 }   // superseded by a newer reload — drop these results
            let existing = Set(items.map(\.id))
            let newItems = result.items.filter { !existing.contains($0.id) }
            items.append(contentsOf: newItems)
            contentRevision &+= 1
            hasMore = items.count < result.total && !newItems.isEmpty
            return newItems.count
        } catch {
            guard gen == generation else { return 0 }
            page = max(1, pageNumber - 1)
            errorMessage = error.localizedDescription
            return 0
        }
    }
}
