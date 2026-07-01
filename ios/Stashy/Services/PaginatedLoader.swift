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

    let pageSize: Int
    private var page = 1
    private var hasMore = true
    private var fetch: (@Sendable (Int, Int) async throws -> (items: [T], total: Int))?

    init(pageSize: Int) { self.pageSize = pageSize }

    /// (Re)configure with a fetch closure and load the first page. Call on appear and on every query
    /// change; the closure should capture the current query/client (both must be Sendable).
    func reload(using fetch: @escaping @Sendable (Int, Int) async throws -> (items: [T], total: Int)) async {
        self.fetch = fetch
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        page = 1
        items = []
        hasMore = true
        await fetchPage()
        isLoading = false
    }

    /// Load the next page once `triggerID` reaches the back half of the loaded items.
    func loadNextIfNeeded(triggerID: T.ID) async {
        guard hasMore, !isLoading, fetch != nil,
              items.suffix(max(1, pageSize / 2)).contains(where: { $0.id == triggerID })
        else { return }
        isLoading = true
        page += 1
        await fetchPage()
        isLoading = false
    }

    private func fetchPage() async {
        guard let fetch else { return }
        do {
            let result = try await fetch(page, pageSize)
            let existing = Set(items.map(\.id))
            let newItems = result.items.filter { !existing.contains($0.id) }
            items.append(contentsOf: newItems)
            hasMore = items.count < result.total && !newItems.isEmpty
        } catch {
            if page > 1 { page -= 1 }
            errorMessage = error.localizedDescription
        }
    }
}
