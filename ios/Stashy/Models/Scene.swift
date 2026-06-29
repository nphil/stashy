import Foundation

struct StashScene: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let title: String?
    let date: String?
    let files: [SceneFile]
    let paths: ScenePaths?
    let studio: Studio?
    let performers: [Performer]
    let tags: [Tag]
    let sceneStreams: [SceneStreamEndpoint]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: StashScene, rhs: StashScene) -> Bool { lhs.id == rhs.id }
}

// Modern Stash exposes duration (and other media metadata) on the file, not the scene.
struct SceneFile: Codable, Sendable, Hashable {
    let duration: Double?
    let video_codec: String?
    let width: Int?
    let height: Int?
    let basename: String?
    let size: Int?
}

struct ScenePaths: Codable, Sendable {
    let screenshot: String?
    let preview: String?
    let sprite: String?
    let vtt: String?
}

struct SceneStreamEndpoint: Codable, Sendable {
    let url: String
    let mime_type: String?
    let label: String?
}

struct Tag: Codable, Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
}

extension StashScene {
    func preferredStreamURL(apiKey: String) -> URL? {
        let stream = sceneStreams.first { $0.mime_type == "application/x-mpegURL" }
            ?? sceneStreams.first
        guard let urlString = stream?.url else { return nil }
        return appendingAPIKey(apiKey, to: urlString)
    }

    func thumbnailURL(apiKey: String) -> URL? {
        guard let screenshot = paths?.screenshot else { return nil }
        return appendingAPIKey(apiKey, to: screenshot)
    }

    func previewURL(apiKey: String) -> URL? {
        guard let preview = paths?.preview else { return nil }
        return appendingAPIKey(apiKey, to: preview)
    }

    func spriteURL(apiKey: String) -> URL? {
        guard let sprite = paths?.sprite else { return nil }
        return appendingAPIKey(apiKey, to: sprite)
    }

    func vttURL(apiKey: String) -> URL? {
        guard let vtt = paths?.vtt else { return nil }
        return appendingAPIKey(apiKey, to: vtt)
    }

    var resolutionLabel: String? {
        guard let h = files.first?.height, h > 0 else { return nil }
        return "\(h)p"
    }

    var codecLabel: String? {
        files.first?.video_codec?.uppercased()
    }

    func formattedDuration() -> String? {
        guard let d = files.first?.duration else { return nil }
        let h = Int(d) / 3600
        let m = Int(d) % 3600 / 60
        let s = Int(d) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

private func appendingAPIKey(_ key: String, to urlString: String) -> URL? {
    guard var components = URLComponents(string: urlString) else { return nil }
    var items = components.queryItems ?? []
    items.removeAll { $0.name == "apikey" }
    items.append(URLQueryItem(name: "apikey", value: key))
    components.queryItems = items
    return components.url
}
