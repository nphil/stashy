import UIKit
import ImageIO
import CryptoKit

/// Two-tier image cache: an in-memory `NSCache` of decoded images plus a persistent on-disk store
/// of downsampled, JPEG-compressed copies. Images are downsampled to roughly the size they're shown
/// at (a grid card is small), so each cached file is only a few KB — that lets us keep thousands of
/// thumbnails locally and serve them from memory/disk instead of re-fetching from Stash over the
/// network, which is what keeps scrolling smooth. A size-capped LRU eviction keeps disk bounded.
actor ImageCache {
    private let memoryCache: NSCache<NSString, UIImage> = {
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
    /// Soft cap for the on-disk thumbnail store; LRU-evicted past this.
    private let maxBytes = 200 * 1024 * 1024
    /// Running total of on-disk bytes, tracked incrementally so a write doesn't re-scan the whole
    /// directory each time (that scan on every cached thumbnail added up during fast scrolling).
    private var diskBytes = 0
    private var diskBytesReady = false

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
        let nsKey = key as NSString
        if let hit = memoryCache.object(forKey: nsKey) { return hit }

        let file = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: nsKey, cost: Self.memoryCost(image, fallback: data.count))
            touch(file)
            return image
        }

        let (data, _) = try await session.data(from: url)
        guard let image = Self.downsample(data: data, maxPixel: maxPixel) else {
            throw ImageCacheError.invalidData
        }
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
        let key = cacheKey(url, 0) // 0 == "original"
        let nsKey = key as NSString
        if let hit = memoryCache.object(forKey: nsKey) { return hit }

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
        for url in urls {
            let key = cacheKey(url, maxPixel, priority: priority)
            if memoryCache.object(forKey: key as NSString) != nil { continue }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(key + ".jpg").path) { continue }
            // Capture only Sendable values (self + url); `image(for:)` populates the cache.
            Task.detached(priority: .background) { [weak self] in
                _ = try? await self?.image(for: url, maxPixel: maxPixel, priority: priority)
            }
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

    private func cacheKey(_ url: URL, _ maxPixel: CGFloat, priority: Bool = false) -> String {
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
