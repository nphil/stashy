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
    let bit_rate: Int?
    let frame_rate: Double?
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

extension SceneStreamEndpoint {
    /// Stash labels the transcoded playlist stream "HLS" and sets mime `application/vnd.apple.mpegurl`
    /// (matching the literal `application/x-mpegURL` is unreliable — different Stash builds vary).
    var isHLS: Bool {
        (label?.caseInsensitiveCompare("HLS") == .orderedSame)
            || (mime_type?.lowercased().contains("mpegurl") ?? false)
    }

    var isDASH: Bool {
        (label?.caseInsensitiveCompare("DASH") == .orderedSame)
            || (mime_type?.lowercased().contains("dash") ?? false)
    }
}

extension StashScene {
    /// Resolve which stream to play, on which backend, and *why*. We direct-play (no server transcode):
    /// AVPlayer for files it can decode natively (H.264/HEVC in MP4/MOV) — which unlocks the live blur —
    /// and KSPlayer/FFmpeg for everything else (exotic containers/codecs), preserving codec support.
    /// `reason` records the exact AVPlayer-incompatibility so the Stats overlay can show it.
    func playbackRoute(apiKey: String) -> PlaybackRoute? {
        // TEST (temporary): route the AVPlayer path through Stash's HLS (transcoded) stream. AVPlayer
        // plays HLS reliably, so this confirms whether the black-video direct-stream files are an
        // AVPlayer input-probing issue (to be fixed by the local FFmpeg remux) rather than AVPlayer
        // being unable to render the content. Revert to direct-play once the FFmpeg pipeline lands.
        if let hls = sceneStreams.first(where: { $0.isHLS }), let url = appendingAPIKey(apiKey, to: hls.url) {
            return PlaybackRoute(url: url, engine: .avPlayer,
                                 streamType: "HLS (transcoded)", reason: "TEST: AVPlayer via Stash HLS")
        }

        // No HLS stream offered → fall back to direct-play routing.
        let direct = sceneStreams.first { !$0.isHLS && !$0.isDASH }
        let chosen = direct ?? sceneStreams.first
        guard let urlString = chosen?.url, let url = appendingAPIKey(apiKey, to: urlString) else { return nil }

        let container = fileContainer
        let codec = (files.first?.video_codec ?? "").lowercased()
        let okContainer = ["mp4", "m4v", "mov"].contains(container)
        let okCodec = ["h264", "avc", "avc1", "hevc", "h265", "hvc1"].contains(codec)

        if okContainer && okCodec {
            return PlaybackRoute(url: url, engine: .avPlayer, streamType: "Direct",
                                 reason: "H.264/HEVC in MP4/MOV — AVPlayer direct")
        }

        let reason: String
        if codec.isEmpty || container.isEmpty {
            reason = "No codec/container metadata — using KSPlayer"
        } else if !okCodec {
            reason = "Codec \(codec.uppercased()) not AVPlayer-compatible"
        } else {
            reason = "Container .\(container) not AVPlayer-compatible"
        }
        return PlaybackRoute(url: url, engine: .ksPlayer, streamType: "Direct", reason: reason)
    }

    /// Lowercased container extension from the primary file's basename (e.g. "mp4", "mkv").
    var fileContainer: String {
        guard let basename = files.first?.basename,
              let ext = basename.split(separator: ".").last, basename.contains(".") else { return "" }
        return ext.lowercased()
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

    /// Width / height of the primary file, when known (used to lay out the player without waiting
    /// for the first decoded frame).
    var videoAspect: CGFloat? {
        guard let w = files.first?.width, let h = files.first?.height, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    /// True when the video is taller than it is wide (shot in portrait).
    var isPortraitVideo: Bool {
        guard let aspect = videoAspect else { return false }
        return aspect < 1
    }

    var resolutionLabel: String? {
        guard let h = files.first?.height, h > 0 else { return nil }
        return "\(h)p"
    }

    /// Simplified display aspect ratio, e.g. "16:9" or "9:16".
    var aspectRatioLabel: String? {
        guard let w = files.first?.width, let h = files.first?.height, w > 0, h > 0 else { return nil }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(w, h)
        guard g > 0 else { return nil }
        return "\(w / g):\(h / g)"
    }

    var codecLabel: String? {
        files.first?.video_codec?.uppercased()
    }

    var bitrateLabel: String? {
        guard let br = files.first?.bit_rate, br > 0 else { return nil }
        return String(format: "%.1f Mbps", Double(br) / 1_000_000)
    }

    var frameRateLabel: String? {
        guard let fr = files.first?.frame_rate, fr > 0 else { return nil }
        return String(format: "%.0f fps", fr)
    }

    var fileSizeLabel: String? {
        guard let s = files.first?.size, s > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)
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
