import Foundation

/// Walks the whole scene library and pre-caches every thumbnail to disk, so a fast flick into scenes you've
/// never opened hits the disk cache instead of the network — and so thumbnails are available offline. As a
/// side effect it also builds the on-device ThumbHash map (blur placeholders) for the whole library.
///
/// Deliberately **manual** (started from Settings) and **sequential** (one request at a time) to respect the
/// "minimal server load" priority — it trickles rather than floods Stash. Cancellable, and effectively
/// resumable: a re-run reuses the disk cache (already-fetched thumbs don't hit the network) and skips scenes
/// that already have a hash.
@MainActor @Observable
final class ThumbnailPrefetcher {
    static let shared = ThumbnailPrefetcher()
    private init() {}

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0
    /// Advances only after a run has fully unwound, including cancellation. Settings observes this
    /// terminal signal to measure the final on-disk cache size after the last image write has settled.
    private(set) var completionRevision = 0
    private var task: Task<Void, Never>?

    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }

    func start(client: StashClient, imageCache: ImageCache) {
        guard !isRunning else { return }
        isRunning = true
        done = 0
        total = 0
        task = Task { await run(client: client, imageCache: imageCache) }
    }

    func cancel() {
        task?.cancel()
        // Keep the job visibly running until `run` reaches its defer. Besides making completion
        // reporting exact, this prevents a replacement run from starting while cancelled work is
        // still unwinding and then having the old run clear the new task's state.
    }

    private func run(client: StashClient, imageCache: ImageCache) async {
        defer {
            isRunning = false
            task = nil
            completionRevision &+= 1
        }
        let apiKey = client.apiKey
        var page = 1
        let perPage = 100
        while !Task.isCancelled {
            guard let result = try? await client.findScenes(SceneQuery(), page: page, perPage: perPage),
                  !result.scenes.isEmpty else { break }
            total = result.count
            for scene in result.scenes {
                if Task.isCancelled { break }
                // The `await` yields the main actor between scenes, so the UI stays responsive; the heavy
                // work (downsample + off-main decode in the cache, hash compute in ingest) never runs here.
                if let url = scene.thumbnailURL(apiKey: apiKey),
                   let image = try? await imageCache.image(for: url) {
                    ThumbHashStore.shared.ingest(image, for: scene.id)
                }
                done += 1
            }
            if done >= total { break }
            page += 1
        }
    }
}
