import SwiftUI

/// App-wide overlay of user rating/favorite edits, keyed by entity id. Every list, grid, and detail
/// view reads ratings/favorites *through* this store, so a change made anywhere is reflected everywhere
/// instantly and survives navigation — the model values from list fetches (which are never refreshed
/// after a write) are no longer the source of truth once the user has touched a field.
///
/// Edits are optimistic: applied to the store immediately, persisted to Stash in the background, and
/// reverted (visibly) only if the server rejects the change — which surfaces a real write failure
/// instead of hiding it. On app relaunch the store starts empty and the (now-updated) server values
/// take over.
@Observable
@MainActor
final class LibraryEdits {
    // `Int??`: outer .none = no local edit (fall back to the model), .some(nil) = user cleared the
    // rating. Always mutated via `updateValue`/`removeValue` so an explicit "cleared" isn't confused
    // with key removal (the Swift dictionary-of-optionals gotcha).
    private var sceneRatings: [String: Int?] = [:]
    private var performerRatings: [String: Int?] = [:]
    private var performerFavorites: [String: Bool] = [:]
    private var tagFavorites: [String: Bool] = [:]
    /// Ids removed this session — hidden from every list immediately (optimistic), re-shown if the
    /// server delete fails. On relaunch the server is authoritative and these start empty.
    private var deletedScenes: Set<String> = []
    private var deletedPerformers: Set<String> = []

    /// Set briefly when a save fails, for optional UI surfacing; cleared after it's shown.
    var lastError: String?

    // MARK: Resolved reads (local edit wins, else the model's fetched value)

    func rating(for scene: StashScene) -> Int? {
        if let edit = sceneRatings[scene.id] { return edit }
        return scene.rating100
    }
    func rating(for performer: Performer) -> Int? {
        if let edit = performerRatings[performer.id] { return edit }
        return performer.rating100
    }
    func isFavorite(_ performer: Performer) -> Bool {
        performerFavorites[performer.id] ?? (performer.favorite ?? false)
    }
    func isFavorite(_ tag: Tag) -> Bool {
        tagFavorites[tag.id] ?? (tag.favorite ?? false)
    }

    /// Filter out scenes/performers deleted this session — call in every list's `ForEach`.
    func visible(_ scenes: [StashScene]) -> [StashScene] { scenes.filter { !deletedScenes.contains($0.id) } }
    func visible(_ performers: [Performer]) -> [Performer] { performers.filter { !deletedPerformers.contains($0.id) } }

    // MARK: Optimistic writes

    func setSceneRating(_ value: Int?, id: String, client: StashClient?) {
        let previous = sceneRatings[id]
        sceneRatings.updateValue(value, forKey: id)
        guard let client else { return }
        Task {
            do { sceneRatings.updateValue(try await client.setSceneRating(id: id, rating100: value), forKey: id) }
            catch { restore(&sceneRatings, id: id, previous: previous); lastError = "Couldn't save rating" }
        }
    }

    func setPerformerRating(_ value: Int?, id: String, client: StashClient?) {
        let previous = performerRatings[id]
        performerRatings.updateValue(value, forKey: id)
        guard let client else { return }
        Task {
            do { performerRatings.updateValue(try await client.setPerformerRating(id: id, rating100: value), forKey: id) }
            catch { restore(&performerRatings, id: id, previous: previous); lastError = "Couldn't save rating" }
        }
    }

    func setPerformerFavorite(_ value: Bool, id: String, client: StashClient?) {
        let previous = performerFavorites[id]
        performerFavorites[id] = value
        guard let client else { return }
        Task {
            do { performerFavorites[id] = try await client.setPerformerFavorite(id: id, favorite: value) ?? value }
            catch {
                if let previous { performerFavorites[id] = previous } else { performerFavorites.removeValue(forKey: id) }
                lastError = "Couldn't save favorite"
            }
        }
    }

    func setTagFavorite(_ value: Bool, id: String, client: StashClient?) {
        let previous = tagFavorites[id]
        tagFavorites[id] = value
        guard let client else { return }
        Task {
            do { tagFavorites[id] = try await client.setTagFavorite(id: id, favorite: value) ?? value }
            catch {
                if let previous { tagFavorites[id] = previous } else { tagFavorites.removeValue(forKey: id) }
                lastError = "Couldn't save favorite"
            }
        }
    }

    /// Optimistically remove a scene (hides it everywhere), then delete on the server. Returns whether
    /// the server delete succeeded; on failure the scene reappears and an error is surfaced.
    func deleteScene(id: String, deleteFile: Bool = false, client: StashClient?) async -> Bool {
        deletedScenes.insert(id)
        guard let client else { return false }
        do {
            let ok = try await client.deleteScene(id: id, deleteFile: deleteFile)
            if !ok { deletedScenes.remove(id); lastError = "Couldn't delete scene" }
            return ok
        } catch {
            deletedScenes.remove(id)
            lastError = "Couldn't delete scene"
            return false
        }
    }

    /// Optimistically remove a performer, then delete on the server.
    func deletePerformer(id: String, client: StashClient?) async -> Bool {
        deletedPerformers.insert(id)
        guard let client else { return false }
        do {
            let ok = try await client.deletePerformer(id: id)
            if !ok { deletedPerformers.remove(id); lastError = "Couldn't delete performer" }
            return ok
        } catch {
            deletedPerformers.remove(id)
            lastError = "Couldn't delete performer"
            return false
        }
    }

    /// Restore a rating dictionary entry after a failed save (explicit-nil aware).
    private func restore(_ dict: inout [String: Int?], id: String, previous: Int??) {
        if let previous { dict.updateValue(previous, forKey: id) } else { dict.removeValue(forKey: id) }
    }
}
