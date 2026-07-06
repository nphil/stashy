import Foundation

/// A tiny on-disk cache of the unfiltered scene library's first page, so the grid still shows something
/// when the server is unreachable (travel / flaky cellular) — "quick access to my library" offline.
///
/// Deliberately minimal and cost-free on the hot path: `save` writes on a background queue (never blocks a
/// load), `load` is only read on an offline failure, and it's capped so the file stays small. All static /
/// stateless, so it's safe to call from the loader's `@Sendable` fetch closure. Thumbnails come from the
/// existing image cache; this only persists the scene metadata (`StashScene` is already `Codable`).
enum LibraryCache {
    /// Keep the file small — this is a convenience snapshot, not a full mirror.
    private static let cap = 300

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("library-cache.json")
    }

    /// Persist the (capped) scene list off the main thread. Called after a successful first-page load.
    static func save(_ scenes: [StashScene]) {
        guard let url = fileURL else { return }
        let slice = Array(scenes.prefix(cap))
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(slice) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// The cached scenes, or `[]` if none. Decoded on the caller's (background) task, never on the main actor.
    static func load() -> [StashScene] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let scenes = try? JSONDecoder().decode([StashScene].self, from: data) else { return [] }
        return scenes
    }
}
