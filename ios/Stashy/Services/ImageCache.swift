import UIKit
import ImageIO
import CryptoKit

/// Two-tier image cache: an in-memory `NSCache` of decoded images plus a persistent on-disk store
/// of downsampled, JPEG-compressed copies. Images are downsampled to roughly the size they're shown
/// at (a grid card is small), so each cached file is only a few KB — that lets us keep thousands of
/// thumbnails locally and serve them from memory/disk instead of re-fetching from Stash over the
/// network, which is what keeps scrolling smooth. A size-capped LRU eviction keeps disk bounded.
actor ImageCache {
    // `nonisolated(unsafe)` so the synchronous `cachedImage(for:)` peek can read it off the actor — NSCache
    // is itself thread-safe, so the unsafe opt-out is honest here.
    nonisolated(unsafe) private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        // Cost is now the decoded bitmap size (see `memoryCost`), not the compressed JPEG size, so this
        // budget finally binds. Raised from 64MB to soften the scroll-back regression from honest costing
        // (still an order of magnitude under the ~400-700MB the mis-costed cache could hold).
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    private let directory: URL
    private let session: URLSession
    /// Soft cap for the on-disk thumbnail store; LRU-evicted past this. Sized to hold a full-library
    /// thumbnail pre-cache (see `ThumbnailPrefetcher`) — downsampled thumbs are only a few KB each, so this
    /// fits tens of thousands. Normal browsing never approaches it; it only binds when pre-caching.
    private let maxBytes = 800 * 1024 * 1024
    /// Running total of on-disk bytes, tracked incrementally so a write doesn't re-scan the whole
    /// directory each time (that scan on every cached thumbnail added up during fast scrolling).
    private var diskBytes = 0
    private var diskBytesReady = false
    /// In-flight fetches keyed by cache key, so concurrent requests for the same image (a cell asking
    /// twice + a prefetch a row ahead) share ONE download/decode instead of each doing its own. See
    /// `image(for:)` for the cancellation-shield reasoning.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    /// Ahead-of-scroll work is intentionally small and bounded. The old implementation launched one
    /// detached task per URL from every appearing cell, which could produce hundreds of tasks, duplicate
    /// file probes and network/decode contention during a fast fling — exactly when the render thread needs
    /// the most headroom.
    private struct PrefetchRequest: Sendable {
        let url: URL
        let maxPixel: CGFloat
        let priority: Bool
        let key: String
    }
    private var prefetchQueue: [PrefetchRequest] = []
    private var queuedPrefetchKeys: Set<String> = []
    private var activePrefetchWorkers = 0
    private let maxPrefetchWorkers = 2
    private let maxQueuedPrefetches = 48

    private func ensureDiskBytesLoaded() {
        guard !diskBytesReady else { return }
        diskBytes = totalSize()   // one full scan on first use, then kept up to date incrementally
        diskBytesReady = true
    }

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        // We do our own (downsampled) disk cache, so don't also keep raw responses on disk.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    /// Returns a downsampled image sized to ~`maxPixel` on its longest edge. Served from memory,
    /// then disk, then network (downsampling + persisting on the way back).
    ///
    /// `priority` marks images we want to keep on device the longest and show at the best quality —
    /// performer portraits, which appear on cards throughout the app and look noticeably worse when
    /// re-compressed hard. Priority images are stored at a higher JPEG quality and are the *last* to be
    /// evicted when the disk cache is over its budget (see `enforceLimit`). The priority flag is baked
    /// into the on-disk filename (a `-p` marker) so eviction can recognise them from the directory
    /// listing alone, without tracking any separate index.
    func image(for url: URL, maxPixel: CGFloat = 600, priority: Bool = false) async throws -> UIImage {
        let key = cacheKey(url, maxPixel, priority: priority)
        if let hit = memoryCache.object(forKey: key as NSString) { return hit }
        // Coalesce: if this key is already being fetched, await that shared work instead of starting a
        // second identical download/decode. The shared Task is *unstructured* (`Task { }`), so it is NOT
        // a child of any caller — one caller's `.task` being cancelled (its cell scrolled off) can't tear
        // the fetch down for the others. Checking then inserting `inFlight` happens with no `await`
        // between, so the actor runs it atomically and two callers can't both create a task.
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { try await self.fetchDownsampled(url: url, key: key, maxPixel: maxPixel, priority: priority) }
        inFlight[key] = task
        // Clear on BOTH success and failure (a failed fetch must not permanently poison the key); guard by
        // identity so we never clobber a newer task that replaced ours.
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        return try await task.value
    }

    /// Load a LOCAL thumbnail file (a completed download's saved cover) — downsampled + decoded OFF the main
    /// thread (we're in the actor) and memoized in the same in-memory cache. `DownloadCard` used to load these
    /// with `UIImage(contentsOfFile:)` on the main actor, which defers its bitmap decode to first render — so
    /// the decode landed on the render thread as the card scrolled into view (the Downloads-tab hitch). This
    /// gives the local path the exact off-main treatment that keeps the grid smooth. Keyed by path+size; no
    /// disk copy (the file already IS the local store). Returns nil on any failure so the caller can fall back
    /// to the remote URL.
    func localImage(at fileURL: URL, maxPixel: CGFloat = 600) async -> UIImage? {
        let key = "local-\(Int(maxPixel))-\(fileURL.path)" as NSString
        if let hit = memoryCache.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: fileURL),
              let downsized = Self.downsample(data: data, maxPixel: maxPixel) else { return nil }
        let image = await downsized.byPreparingForDisplay() ?? downsized
        memoryCache.setObject(image, forKey: key, cost: Self.memoryCost(image, fallback: data.count))
        return image
    }

    /// The disk-then-network body of `image(for:)`, run inside the coalesced Task so joiners share it.
    private func fetchDownsampled(url: URL, key: String, maxPixel: CGFloat, priority: Bool) async throws -> UIImage {
        let nsKey = key as NSString
        let file = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let raw = UIImage(data: data) {
            // Decode to a display-ready bitmap OFF the main thread (we're in the actor) so the image never
            // decodes on the render thread as its cell scrolls into view — that decode-on-arrival was a
            // mid-scroll hitch. `UIImage(data:)` is otherwise lazily decoded at first draw.
            let image = await raw.byPreparingForDisplay() ?? raw
            memoryCache.setObject(image, forKey: nsKey, cost: Self.memoryCost(image, fallback: data.count))
            touch(file)
            return image
        }

        let (data, _) = try await session.data(from: url)
        guard let downsized = Self.downsample(data: data, maxPixel: maxPixel) else {
            throw ImageCacheError.invalidData
        }
        // Force the full decode off-main (in the actor) so nothing decodes on the render thread mid-scroll.
        let image = await downsized.byPreparingForDisplay() ?? downsized
        // Higher quality for priority (performer) images so they stay crisp on the cards; the ordinary
        // 0.7 keeps grid thumbnails small.
        if let jpeg = image.jpegData(compressionQuality: priority ? 0.85 : 0.7) {
            if (try? jpeg.write(to: file, options: .atomic)) != nil {
                ensureDiskBytesLoaded()
                diskBytes += jpeg.count
                enforceLimit()
            }
            memoryCache.setObject(image, forKey: nsKey, cost: Self.memoryCost(image, fallback: jpeg.count))
        } else {
            memoryCache.setObject(image, forKey: nsKey)
        }
        return image
    }

    /// Full-resolution fetch (no downsampling) for images whose exact pixels matter — e.g. sprite
    /// sheets, where WebVTT crop coordinates are in the original pixel space.
    func originalImage(for url: URL) async throws -> UIImage {
        let key = cacheKey(url, 0) // 0 == "original" (distinct key namespace from image(for:), safe to
                                   // share the one inFlight dict)
        if let hit = memoryCache.object(forKey: key as NSString) { return hit }
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task { try await self.fetchOriginal(url: url, key: key) }
        inFlight[key] = task
        defer { if inFlight[key] == task { inFlight[key] = nil } }
        return try await task.value
    }

    /// The disk-then-network body of `originalImage(for:)`, run inside the coalesced Task.
    private func fetchOriginal(url: URL, key: String) async throws -> UIImage {
        let nsKey = key as NSString
        let file = directory.appendingPathComponent(key + ".img")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: nsKey, cost: Self.memoryCost(image, fallback: data.count))
            touch(file)
            return image
        }

        let (data, _) = try await session.data(from: url)
        guard let image = UIImage(data: data) else { throw ImageCacheError.invalidData }
        if (try? data.write(to: file, options: .atomic)) != nil {
            ensureDiskBytesLoaded()
            diskBytes += data.count
            enforceLimit()
        }
        memoryCache.setObject(image, forKey: nsKey, cost: Self.memoryCost(image, fallback: data.count))
        return image
    }

    func prefetch(urls: [URL], maxPixel: CGFloat = 600, priority: Bool = false) {
        // Reverse before appending because workers pop from the end: the closest upcoming thumbnail is
        // processed first. Overlapping windows from adjacent cells collapse to one queued request per key.
        for url in urls.reversed() {
            let key = cacheKey(url, maxPixel, priority: priority)
            if memoryCache.object(forKey: key as NSString) != nil { continue }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(key + ".jpg").path) { continue }
            if inFlight[key] != nil || queuedPrefetchKeys.contains(key) { continue }

            if prefetchQueue.count >= maxQueuedPrefetches {
                let dropped = prefetchQueue.removeFirst()
                queuedPrefetchKeys.remove(dropped.key)
            }
            prefetchQueue.append(PrefetchRequest(
                url: url, maxPixel: maxPixel, priority: priority, key: key
            ))
            queuedPrefetchKeys.insert(key)
        }
        startPrefetchWorkersIfNeeded()
    }

    private func startPrefetchWorkersIfNeeded() {
        while activePrefetchWorkers < maxPrefetchWorkers, !prefetchQueue.isEmpty {
            activePrefetchWorkers += 1
            Task(priority: .background) {
                await self.runPrefetchWorker()
            }
        }
    }

    private func runPrefetchWorker() async {
        defer {
            activePrefetchWorkers -= 1
            startPrefetchWorkersIfNeeded()
        }
        while let request = prefetchQueue.popLast() {
            queuedPrefetchKeys.remove(request.key)
            _ = try? await image(
                for: request.url,
                maxPixel: request.maxPixel,
                priority: request.priority
            )
        }
    }

    /// Bytes used by the on-disk thumbnail store.
    func diskUsage() -> Int { ensureDiskBytesLoaded(); return diskBytes }

    func clear() {
        memoryCache.removeAllObjects()
        if let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
        diskBytes = 0
        diskBytesReady = true
    }

    // MARK: - Helpers

    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Approximate resident cost of a decoded image (its bitmap backing store) for NSCache accounting.
    /// The old code passed the compressed JPEG/data size, which under-counted decoded bitmaps 10-20x and
    /// let the memory budget hold hundreds of MB. Falls back to the byte size if there's no CGImage.
    private static func memoryCost(_ image: UIImage, fallback: Int) -> Int {
        image.cgImage.map { $0.bytesPerRow * $0.height } ?? fallback
    }

    private func totalSize() -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
    }

    private func enforceLimit() {
        ensureDiskBytesLoaded()
        guard diskBytes > maxBytes else { return }   // fast path: no directory scan when under the cap
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var entries = urls.compactMap { url -> (url: URL, size: Int, date: Date, priority: Bool)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            // Priority images carry the `-p` filename marker (see `cacheKey`).
            let isPriority = url.deletingPathExtension().lastPathComponent.hasSuffix("-p")
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast, isPriority)
        }
        // Evict non-priority first, then oldest-first within each tier — so performer portraits are the
        // last thing dropped when the cache is over budget.
        // Self-heal the incremental counter from the sizes we just listed — two concurrent fetches of the
        // same thumbnail double-count diskBytes (the file is overwritten once but the counter bumps
        // twice), and that phantom drift would otherwise evict live files to satisfy bytes that don't
        // exist. If the real usage is actually under the cap, there's nothing to evict.
        diskBytes = entries.reduce(0) { $0 + $1.size }
        guard diskBytes > maxBytes else { return }
        entries.sort { ($0.priority ? 1 : 0, $0.date) < ($1.priority ? 1 : 0, $1.date) }
        // Evict to a low-water mark rather than exactly to the cap: otherwise the next write is over the
        // cap again and every new thumbnail triggers a full directory scan+sort at steady state.
        let lowWater = maxBytes * 85 / 100
        for entry in entries where diskBytes > lowWater {
            try? FileManager.default.removeItem(at: entry.url)
            diskBytes -= entry.size
        }
    }

    /// Synchronous memory-cache-only peek (no disk, no network) — used to resolve a long-press preview
    /// poster instantly without awaiting the actor. Returns nil if not resident (caller falls back to black).
    nonisolated func cachedImage(for url: URL, maxPixel: CGFloat = 600, priority: Bool = false) -> UIImage? {
        memoryCache.object(forKey: cacheKey(url, maxPixel, priority: priority) as NSString)
    }

    nonisolated private func cacheKey(_ url: URL, _ maxPixel: CGFloat, priority: Bool = false) -> String {
        var key = url.absoluteString
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = comps.queryItems?.filter { $0.name != "apikey" }
            key = comps.url?.absoluteString ?? url.absoluteString
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        // The trailing `-p` marks a priority (performer) image so eviction can spot it from the
        // filename alone — see `enforceLimit`. Kept after the size so the base hash is unaffected.
        return digest.map { String(format: "%02x", $0) }.joined() + "_\(Int(maxPixel))" + (priority ? "-p" : "")
    }

    /// Memory-efficient downsample via ImageIO — decodes straight to a thumbnail without ever
    /// materializing the full-resolution bitmap.
    static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }

    enum ImageCacheError: Error {
        case invalidData
    }
}

// MARK: - Environment

import SwiftUI

private struct ImageCacheKey: EnvironmentKey {
    static let defaultValue = ImageCache()
}

extension EnvironmentValues {
    var imageCache: ImageCache {
        get { self[ImageCacheKey.self] }
        set { self[ImageCacheKey.self] = newValue }
    }
}
