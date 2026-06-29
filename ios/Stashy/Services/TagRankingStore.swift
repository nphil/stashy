import SwiftUI

/// Ranks tags by how often the user has filtered by them (local history) and by overall Stash
/// popularity (scene count, a proxy for what gets watched). The popular set is fetched at most
/// once every few hours and cached to UserDefaults, so long tag lists can be truncated to the most
/// relevant tags without a query on every view.
@MainActor
@Observable
final class TagRankingStore {
    static let shared = TagRankingStore()

    private let selectionKey = "tagSelectionCounts"
    private let popularKey = "popularTagsCache"
    private let popularTimeKey = "popularTagsCachedAt"
    private let ttl: TimeInterval = 3 * 3600 // refresh at most every 3 hours

    private var selectionCounts: [String: Int]
    private var popularRank: [String: Int] = [:]
    private(set) var popularTags: [Tag] = []

    private init() {
        selectionCounts = (UserDefaults.standard.dictionary(forKey: selectionKey) as? [String: Int]) ?? [:]
        if let data = UserDefaults.standard.data(forKey: popularKey),
           let tags = try? JSONDecoder().decode([Tag].self, from: data) {
            setPopular(tags)
        }
    }

    /// Refresh the cached popular tags if the cache is stale. Cheap no-op while warm.
    func refreshIfNeeded(client: StashClient) async {
        let last = UserDefaults.standard.double(forKey: popularTimeKey)
        if !popularTags.isEmpty, Date().timeIntervalSince1970 - last < ttl { return }
        guard let tags = try? await client.findTags(query: "", limit: 80, sort: "scenes_count", direction: "DESC") else { return }
        setPopular(tags)
        if let data = try? JSONEncoder().encode(tags) {
            UserDefaults.standard.set(data, forKey: popularKey)
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: popularTimeKey)
    }

    func recordSelection(_ tags: [Tag]) {
        for tag in tags { selectionCounts[tag.id, default: 0] += 1 }
        UserDefaults.standard.set(selectionCounts, forKey: selectionKey)
    }

    /// Order tags so the user's most-used and the most popular surface first.
    func ranked(_ tags: [Tag]) -> [Tag] {
        tags.sorted { a, b in
            let sa = selectionCounts[a.id] ?? 0
            let sb = selectionCounts[b.id] ?? 0
            if sa != sb { return sa > sb }
            let pa = popularRank[a.id] ?? Int.max
            let pb = popularRank[b.id] ?? Int.max
            if pa != pb { return pa < pb }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func setPopular(_ tags: [Tag]) {
        popularTags = tags
        popularRank = Dictionary(uniqueKeysWithValues: tags.enumerated().map { ($0.element.id, $0.offset) })
    }
}
