import UIKit

actor ImageCache {
    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 512 * 1024 * 1024
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    func image(for url: URL) async throws -> UIImage {
        let key = url.absoluteString as NSString
        if let hit = memoryCache.object(forKey: key) { return hit }

        let (data, _) = try await session.data(from: url)
        guard let img = UIImage(data: data) else { throw ImageCacheError.invalidData }
        memoryCache.setObject(img, forKey: key, cost: data.count)
        return img
    }

    func prefetch(urls: [URL]) {
        for url in urls {
            let key = url.absoluteString as NSString
            guard memoryCache.object(forKey: key) == nil else { continue }
            // Capture only Sendable values (self + url); `image(for:)` populates the cache.
            Task.detached(priority: .background) { [weak self] in
                _ = try? await self?.image(for: url)
            }
        }
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
