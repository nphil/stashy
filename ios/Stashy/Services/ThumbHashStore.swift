import UIKit

/// Holds a tiny ThumbHash per scene/performer and turns it into an instant blurry placeholder that a card
/// shows *before* its real thumbnail loads — so a fast flick never flashes blank cards. Hashes come from two
/// sources: (1) computed on-device as thumbnails load (persisted, so they survive relaunch and accumulate),
/// and (2) later, the Companion plugin's served `thumbhashes.json` (instant coverage for unseen scenes).
///
/// Deliberately **not** `@Observable`: cards read `placeholder(for:)` imperatively at render time, so
/// recording a hash mid-scroll never invalidates visible cells (scroll perf is paramount). A hash arriving
/// after a cell is on screen simply shows on that cell's *next* appearance — fine, since by then its real
/// thumbnail has usually loaded anyway.
@MainActor
final class ThumbHashStore {
    static let shared = ThumbHashStore()

    private var hashes: [String: Data] = [:]                 // id → raw ThumbHash bytes
    private let decoded = NSCache<NSString, UIImage>()       // id → decoded ≤32px placeholder image
    private let fileURL: URL
    private var persistTask: Task<Void, Never>?
    private var lastRefresh: Date?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("thumbhashes.json")
        decoded.countLimit = 400
        // Load the persisted map off-main, then merge (never clobbering a hash recorded before load finished).
        Task { [fileURL] in
            let loaded = await Self.load(from: fileURL)
            for (k, v) in loaded where hashes[k] == nil { hashes[k] = v }
        }
    }

    /// The decoded blurry placeholder for an id, or nil if we have no hash yet. Memoised. Safe to call every
    /// render — a hit is an NSCache lookup; a miss decodes a ≤32px image once (sub-millisecond).
    func placeholder(for id: String) -> UIImage? {
        if let cached = decoded.object(forKey: id as NSString) { return cached }
        guard let hash = hashes[id], hash.count >= 5 else { return nil }
        let image = thumbHashToImage(hash: hash)
        decoded.setObject(image, forKey: id as NSString)
        return image
    }

    private func hasHash(_ id: String) -> Bool { hashes[id] != nil }

    /// Compute a ThumbHash for `id` from an already-loaded, oriented thumbnail — off the main actor — and
    /// store it. No-op if we already have one. Called by a card once its real thumbnail has loaded.
    func ingest(_ image: UIImage, for id: String) {
        guard !hasHash(id) else { return }
        Task.detached(priority: .utility) {
            guard let cg = image.cgImage, let hash = Self.compute(from: cg) else { return }
            await ThumbHashStore.shared.record(hash, for: id)
        }
    }

    /// Merge externally-provided hashes (e.g. the plugin's served map). Kept hashes win over incoming ones so
    /// a freshly-computed on-device hash is never overwritten.
    func merge(_ incoming: [String: Data]) {
        var changed = false
        for (k, v) in incoming where hashes[k] == nil { hashes[k] = v; changed = true }
        if changed { schedulePersist() }
    }

    /// Fetch the Companion plugin's served `thumbhashes.json` (written by the "Compute ThumbHash Map" task)
    /// and merge it in — instant blur placeholders for scenes the user has never opened. Throttled to ~5 min
    /// once it has succeeded; silent on any failure (plugin not installed / no map yet ⇒ retry next time,
    /// behaviour unchanged). `merge` keeps on-device hashes, so the served map only fills the gaps. Mirrors
    /// `PlayabilityStore.refresh`; JSON + base64 decoding stays off the main actor so even a full-library
    /// map cannot steal a scrolling frame.
    func refresh(serverURL: String, apiKey: String, force: Bool = false) async {
        if !force, let last = lastRefresh, Date().timeIntervalSince(last) < 300 { return }
        guard var comps = URLComponents(string: "\(serverURL)/plugin/\(StashCompanion.pluginID)/assets/cache/thumbhashes.json") else { return }
        if !apiKey.isEmpty { comps.queryItems = [URLQueryItem(name: "apikey", value: apiKey)] }
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let incoming = await Task.detached(priority: .utility) {
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                return [String: Data]()
            }
            return payload.scenes.compactMapValues { Data(base64Encoded: $0) }
        }.value
        guard !incoming.isEmpty else { return }   // no served map yet — don't start the throttle, retry later
        lastRefresh = Date()
        merge(incoming)
    }

    private struct Payload: Decodable, Sendable { let scenes: [String: String] }

    private func record(_ hash: Data, for id: String) {
        guard hashes[id] == nil else { return }
        hashes[id] = hash
        schedulePersist()
    }

    private func schedulePersist() {
        persistTask?.cancel()
        let snapshot = hashes
        let url = fileURL
        persistTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
        }
    }

    // MARK: Off-main helpers

    /// Draw an oriented thumbnail CGImage into a ≤100px RGBA bitmap (thread-safe, off-main) and encode it.
    /// Scene/performer thumbnails are opaque, so premultiplied == straight alpha and no conversion is needed.
    nonisolated private static func compute(from cgImage: CGImage) -> Data? {
        let w0 = cgImage.width, h0 = cgImage.height
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = 100.0 / Double(max(w0, h0))
        let w = max(1, Int((Double(w0) * scale).rounded()))
        let h = max(1, Int((Double(h0) * scale).rounded()))
        var rgba = Data(count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return rgbaToThumbHash(w: w, h: h, rgba: rgba)
    }

    nonisolated private static func write(_ hashes: [String: Data], to url: URL) async {
        let encoded = hashes.mapValues { $0.base64EncodedString() }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func load(from url: URL) async -> [String: Data] {
        guard let data = try? Data(contentsOf: url),
              let encoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return encoded.compactMapValues { Data(base64Encoded: $0) }
    }
}
