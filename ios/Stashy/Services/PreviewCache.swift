import Foundation
import CryptoKit
import SwiftUI

/// On-disk cache for Stash scene preview clips (`paths.preview`). Playing previews from a local
/// file (instead of streaming over the network each time) removes start-up latency and buffering
/// stalls, which is what keeps in-grid preview playback instant and glitch-free. Files persist
/// across launches and can be inspected / cleared from Settings; they re-download on demand.
actor PreviewCache {
    private let directory: URL
    private let session: URLSession
    /// Soft cap on disk used by cached preview clips. Least-recently-used files are evicted past it.
    private let maxBytes = 300 * 1024 * 1024
    /// In-flight downloads keyed by content filename, so a long-press racing its own prefetch (or a
    /// repress) shares one download instead of fetching the whole clip twice.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ScenePreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = URLSession(configuration: .default)
    }

    /// Local file URL for a preview, downloading + caching it on first use. Returns nil on failure.
    func localURL(for remoteURL: URL) async -> URL? {
        let name = filename(for: remoteURL)
        let file = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) {
            touch(file) // mark recently used for LRU
            return file
        }
        // Coalesce concurrent requests for the same clip (a long-press racing its own prefetch, or a
        // repress) onto one download. The shared Task is unstructured and cleared on completion — so a
        // dismissed preview's small clip finishes and caches (making a repress instant) instead of being
        // torn down mid-flight; the caller's own loadTask cancellation still skips the model setup.
        if let existing = inFlight[name] { return await existing.value }
        let task = Task { await self.download(remoteURL, to: file) }
        inFlight[name] = task
        defer { if inFlight[name] == task { inFlight[name] = nil } }
        return await task.value
    }

    private func download(_ remoteURL: URL, to file: URL) async -> URL? {
        do {
            let (tmp, response) = try await session.download(from: remoteURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: tmp, to: file)
            touch(file)
            enforceLimit()
            return file
        } catch {
            return nil
        }
    }

    /// Warm the cache in the background so playback is instant once scrolling stops.
    func prefetch(_ remoteURLs: [URL]) async {
        for url in remoteURLs {
            let file = directory.appendingPathComponent(filename(for: url))
            if FileManager.default.fileExists(atPath: file.path) { continue }
            _ = await localURL(for: url)
        }
    }

    /// Mark a file as just-used so LRU eviction keeps it around.
    private func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    /// Evict least-recently-used files until under the size cap. Newest files (currently playing)
    /// are touched on access, so they're never the ones removed.
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

    func totalSize() -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    func clear() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    /// Stable filename keyed by the URL minus the `apikey` query, so rotating the key doesn't
    /// orphan the whole cache.
    private func filename(for url: URL) -> String {
        var key = url.absoluteString
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = comps.queryItems?.filter { $0.name != "apikey" }
            key = comps.url?.absoluteString ?? url.absoluteString
        }
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".mp4"
    }
}

// MARK: - Environment

private struct PreviewCacheKey: EnvironmentKey {
    static let defaultValue = PreviewCache()
}

extension EnvironmentValues {
    var previewCache: PreviewCache {
        get { self[PreviewCacheKey.self] }
        set { self[PreviewCacheKey.self] = newValue }
    }
}
