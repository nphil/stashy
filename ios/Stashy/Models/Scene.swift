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

    /// Codecs AVPlayer decodes natively in hardware (matched loosely against Stash's `video_codec`).
    static let directPlayCodecs = ["h264", "avc", "hevc", "h265", "hvc"]
    /// Containers AVPlayer opens directly.
    static let directPlayContainers = ["mp4", "m4v", "mov", "qt"]

    /// Resolve which stream to play, on which engine, and *why*. The goal is to **direct-play** (native
    /// hardware decode + instant seeks, no server load) whenever AVPlayer can handle the file, and to
    /// fall back only when it can't:
    ///   • H.264/HEVC in mp4/mov  → Direct play (the fast path).
    ///   • right codec, wrong container (MKV/TS/…) → needs **remux** (on-device, next phase).
    ///   • codec AVPlayer can't decode (MPEG4-ASP, VC1, VP9/AV1 on older HW) → needs **transcode**.
    /// Until the on-device remux/transcode engine is wired up, the latter two fall back to Stash's HLS
    /// (server transcode). `reason` records the decision for the Stats overlay.
    func playbackRoute(apiKey: String) -> PlaybackRoute? {
        let codec = files.first?.video_codec?.lowercased()
        let container = fileContainer
        let codecOK = codec.map { c in Self.directPlayCodecs.contains { c.contains($0) } } ?? false
        let containerOK = Self.directPlayContainers.contains(container)

        // Fast path: AVPlayer can decode + demux this as-is.
        if codecOK, containerOK, let url = directFileURL(apiKey: apiKey) {
            return PlaybackRoute(url: url, engine: .avPlayer, streamType: "Direct",
                                 reason: "Direct play (\(codec ?? "?") in \(container))")
        }

        // Fallback (until the on-device path lands): Stash HLS. Record whether the file *would* only
        // need a remux (cheap) or a full transcode (expensive) so it's clear what to build it on.
        if let hls = sceneStreams.first(where: { $0.isHLS }), let url = appendingAPIKey(apiKey, to: hls.url) {
            let why = codecOK
                ? "container .\(container) needs remux"
                : "codec \(codec ?? "?") needs transcode"
            return PlaybackRoute(url: url, engine: .avPlayer, streamType: "HLS (transcoded)",
                                 reason: "Fallback: \(why); on-device path pending")
        }

        // No HLS offered → last-resort direct file (may not render for exotic codecs/containers).
        guard let url = directFileURL(apiKey: apiKey) else { return nil }
        return PlaybackRoute(url: url, engine: .avPlayer, streamType: "Direct",
                             reason: "Last resort: no HLS; on-device path pending")
    }

    /// The direct (non-HLS/DASH) file stream URL — the actual media file the FFmpeg pipeline reads,
    /// used by the demux probe and (later) the on-device remux/transcode path.
    func directFileURL(apiKey: String) -> URL? {
        let direct = sceneStreams.first { !$0.isHLS && !$0.isDASH } ?? sceneStreams.first
        guard let urlString = direct?.url else { return nil }
        return appendingAPIKey(apiKey, to: urlString)
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
