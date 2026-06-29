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
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private let directory: URL
    private let session: URLSession
    /// Soft cap for the on-disk thumbnail store; LRU-evicted past this.
    private let maxBytes = 200 * 1024 * 1024

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
    func image(for url: URL, maxPixel: CGFloat = 600) async throws -> UIImage {
        let key = cacheKey(url, maxPixel)
        let nsKey = key as NSString
        if let hit = memoryCache.object(forKey: nsKey) { return hit }

        let file = directory.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memoryCache.setObject(image, forKey: nsKey, cost: data.count)
            touch(file)
            return image
        }

        let (data, _) = try await session.data(from: url)
        guard let image = Self.downsample(data: data, maxPixel: maxPixel) else {
            throw ImageCacheError.invalidData
        }
        if let jpeg = image.jpegData(compressionQuality: 0.7) {
            try? jpeg.write(to: file, options: .atomic)
            memoryCache.setObject(image, forKey: nsKey, cost: jpeg.count)
            enforceLimit()
        } else {
            memoryCache.setObject(image, forKey: nsKey)
        }
        return image
    }

    func prefetch(urls: [URL], maxPixel: CGFloat = 600) {
        for url in urls {
            let key = cacheKey(url, maxPixel)
            if memoryCache.object(forKey: key as NSString) != nil { continue }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(key + ".jpg").path) { continue }
            // Capture only Sendable values (self + url); `image(for:)` populates the cache.
            Task.detached(priority: .background) { [weak self] in
                _ = try? await self?.image(for: url, maxPixel: maxPixel)
            }
        }
    }

    /// Bytes used by the on-disk thumbnail store.
    func diskUsage() -> Int { totalSize() }

    func clear() {
        memoryCache.removeAllObjects()
        if let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in urls { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: - Helpers

    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    private func totalSize() -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(0) { $0 + (((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0) }
    }

    private func enforceLimit() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        var entries = urls.compactMap { url -> (url: URL, size: Int, date: Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date } // oldest first
        for entry in entries where total > maxBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func cacheKey(_ url: URL, _ maxPixel: CGFloat) -> String {
        var key = url.absoluteString
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = comps.queryItems?.filter { $0.name != "apikey" }
            key = comps.url?.absoluteString ?? url.absoluteString
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + "_\(Int(maxPixel))"
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
