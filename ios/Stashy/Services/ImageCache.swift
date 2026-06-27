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
            Task.detached(priority: .background) { [session] in
                guard let (data, _) = try? await session.data(from: url),
                      let img = UIImage(data: data) else { return }
                await self.store(img, data: data, key: key)
            }
        }
    }

    private func store(_ image: UIImage, data: Data, key: NSString) {
        memoryCache.setObject(image, forKey: key, cost: data.count)
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
