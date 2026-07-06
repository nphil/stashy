import Foundation

struct StashScene: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let title: String?
    let date: String?
    /// 0–100 rating (Stash's scale). Mutable so optimistic rating updates reflect immediately in the
    /// owning list/detail without a refetch. Identity is id-based, so this never affects hashing/equality.
    var rating100: Int?
    let files: [SceneFile]
    let paths: ScenePaths?
    let studio: Studio?
    let performers: [Performer]
    let tags: [Tag]
    let sceneStreams: [SceneStreamEndpoint]

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: StashScene, rhs: StashScene) -> Bool { lhs.id == rhs.id }

    /// Star rating on a 0–5 scale (Stash stores rating100 as 0–100).
    var ratingStars: Double? {
        guard let rating100 else { return nil }
        return Double(rating100) / 20.0
    }
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
    /// Favorite flag (present when fetched via `findTags`; nil for tags embedded in scenes, which only
    /// select id+name). Mutable for optimistic toggles.
    var favorite: Bool?

    // Tags embedded in scenes carry only id+name; favorite must decode as nil when absent.
    init(id: String, name: String, favorite: Bool? = nil) {
        self.id = id
        self.name = name
        self.favorite = favorite
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Tag, rhs: Tag) -> Bool { lhs.id == rhs.id }
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
    /// Codecs AVPlayer reliably direct-plays from a progressive MP4 (matched loosely vs Stash's
    /// `video_codec`). H.264 only: HEVC also decodes in hardware, but AVPlayer renders the very common
    /// `hev1`-tagged HEVC streams *black* (parameter sets in-band) — those need a remux to `hvc1`
    /// first, so HEVC is handled on the remux path instead.
    static let directPlayCodecs = ["h264", "avc"]
    /// Codecs AVPlayer can decode once repackaged into a clean (hvc1-tagged) fragmented MP4. AV1 is added
    /// at runtime when the device has a hardware AV1 decoder (see `isRemuxClass`).
    static let remuxableCodecs = ["hevc", "h265", "hvc"]
    /// AV1 codec spellings (Stash `video_codec` / FFmpeg names / fourcc).
    static let av1Codecs = ["av1", "av01"]
    /// Containers AVPlayer opens directly.
    static let directPlayContainers = ["mp4", "m4v", "mov", "qt"]

    /// Cheap, plugin-free load weight for this scene's file (resolution × bitrate × codec), fed to the
    /// player's loading-donut estimate so heavier files get a proportionally longer expected fill. All
    /// inputs come free from Stash's scene metadata — the companion plugin adds nothing here.
    var loadProfile: LoadProfile {
        let f = files.first
        let pixels = max(0, (f?.width ?? 0) * (f?.height ?? 0))
        let mbps = max(0, Double(f?.bit_rate ?? 0) / 1_000_000)
        let codec: LoadProfile.Codec
        if let c = f?.video_codec?.lowercased() {
            if Self.av1Codecs.contains(where: { c.contains($0) }) { codec = .av1 }
            else if Self.remuxableCodecs.contains(where: { c.contains($0) }) { codec = .hevc }
            else if Self.directPlayCodecs.contains(where: { c.contains($0) }) { codec = .h264 }
            else { codec = .other }
        } else { codec = .other }
        return LoadProfile(pixels: pixels, bitrateMbps: mbps, codec: codec)
    }

    /// Resolve which stream to play, on which engine, and *why*. The goal is to **direct-play** (native
    /// hardware decode + instant seeks, no server load) whenever AVPlayer can handle the file, and to
    /// fall back only when it can't:
    ///   • H.264 in mp4/mov  → Direct play (the fast path).
    ///   • HEVC (any container), or H.264 in a foreign container (MKV/TS/…) → needs **remux**
    ///     (on-device, next phase) — for HEVC the remux also retags hev1→hvc1.
    ///   • codec AVPlayer can't decode (MPEG4-ASP, VC1, VP9/AV1 on older HW) → needs **transcode**.
    /// Until the on-device remux/transcode engine is wired up, the latter two fall back to Stash's HLS
    /// (server transcode). `reason` records the decision for the Stats overlay.
    /// `pluginNeedsTranscode` = the Companion plugin's ffprobe verdict (from `PlayabilityStore`) that Apple
    /// can't decode this scene at all. Threaded in (not read off the scene) because the data lives in the
    /// plugin's served file, not on the scene. Default false ⇒ routing is exactly the codec-based heuristic.
    func playbackRoute(apiKey: String, pluginNeedsTranscode: Bool = false) -> PlaybackRoute? {
        let codec = files.first?.video_codec?.lowercased()
        let container = fileContainer
        let containerOK = Self.directPlayContainers.contains(container)
        let hlsURL = sceneStreams.first(where: { $0.isHLS }).flatMap { appendingAPIKey(apiKey, to: $0.url) }

        let isH264 = codec.map { c in Self.directPlayCodecs.contains { c.contains($0) } } ?? false
        let isAV1 = codec.map { c in Self.av1Codecs.contains { c.contains($0) } } ?? false
        let isHEVC = codec.map { c in Self.remuxableCodecs.contains { c.contains($0) } } ?? false
        // AVPlayer decodes AV1 natively only with a hardware AV1 decoder (A17 Pro+). When present, AV1
        // behaves like H.264: direct-play from a native container, remux only for a foreign one. (HEVC is
        // different — even in MP4 the common hev1 tag renders black, so it always needs an hvc1 remux.)
        let av1Native = isAV1 && DeviceCapabilities.av1HardwareDecode
        let isDirectClass = isH264 || av1Native

        // Companion-plugin routing hint: the plugin's ffprobe verdict that Apple can't decode this stream
        // at all (e.g. 4:2:2/4:4:4 HEVC that reads as plain "hevc"). When present, skip the direct/remux
        // attempts below — they'd render black and only recover after the 20s watchdog — and fall through
        // to the transcode/server tiers. No tag ⇒ false ⇒ routing is unchanged.
        let flaggedTranscode = pluginNeedsTranscode

        // Fast path: H.264 / native-AV1 in a native container — AVPlayer plays the file as-is (instant
        // seeks, no server). AV1 carries an HLS fallback in case its pixel format (4:2:2/4:4:4/12-bit)
        // isn't hardware-decodable; H.264 is always 4:2:0 so it needs none.
        if isDirectClass, containerOK, !flaggedTranscode, let url = directFileURL(apiKey: apiKey) {
            return PlaybackRoute(url: url, engine: .avPlayer, streamType: "Direct",
                                 reason: "Direct play (\(codec ?? "?") in \(container))",
                                 fallbackURL: av1Native ? hlsURL : nil)
        }

        // Remux class: HEVC (any container → hvc1 retag), or a natively-decodable codec in a foreign
        // container (MKV/WebM) → on-device remux over the loopback, with HLS fallback. The pixel-format
        // probe (in the facade) sends Apple-undecodable 4:2:2/4:4:4 straight to HLS.
        if (isHEVC || (isDirectClass && !containerOK)), !flaggedTranscode, let source = directFileURL(apiKey: apiKey) {
            let why = isHEVC
                ? "\(codec ?? "?") → hvc1 remux (local)"
                : "container .\(container) → remux (local)"
            return PlaybackRoute(url: source, engine: .localFFmpeg, streamType: "Local remux",
                                 reason: why, fallbackURL: hlsURL, duration: files.first?.duration ?? 0)
        }

        // Transcode class (codec Apple can't decode at all: VP9, software-AV1, MPEG4-ASP/VC1, exotic pixel
        // formats, or a plugin-flagged Apple-undecodable file) → the Stash **server** HLS transcode. It's
        // reliable, scrubs well, and on a self-hosted LAN the server (P40) does it in seconds. On-device
        // streaming transcode was removed: it was flaky, its seek-by-reinit made scrubbing glitchy, and it
        // pulled the whole original file over the network to re-encode locally (more bandwidth, not less).
        let why = flaggedTranscode ? "\(codec ?? "?") (plugin: Apple-undecodable)" : (codec ?? "?")
        if let hlsURL {
            return PlaybackRoute(url: hlsURL, engine: .avPlayer, streamType: "HLS (transcoded)",
                                 reason: "codec \(why) → HLS (transcode)")
        }

        // No HLS offered → last-resort direct file (may not render for exotic codecs/containers).
        guard let url = directFileURL(apiKey: apiKey) else { return nil }
        return PlaybackRoute(url: url, engine: .avPlayer, streamType: "Direct",
                             reason: "Last resort: no HLS; on-device path pending")
    }

    /// Playback route for a *downloaded* local file. Same capability decision as `playbackRoute`, but the
    /// source is the local file for both direct play and the on-device remux (so a downloaded HEVC / MKV
    /// plays offline through the same remux path the server stream uses, instead of being force-fed to a
    /// bare AVPlayer that renders black / can't open the container). Server HLS is the online fallback.
    /// `nativeMP4` = this local file was produced by our on-device transcoder, so it's guaranteed a clean
    /// hvc1/avc1 MP4 that AVPlayer plays directly — skip the remux path entirely (the whole point of
    /// transcoding was to make it natively playable).
    func localPlaybackRoute(localURL: URL, apiKey: String, nativeMP4: Bool = false) -> PlaybackRoute {
        let codec = files.first?.video_codec?.lowercased()
        let container = fileContainer
        let containerOK = Self.directPlayContainers.contains(container)
        let hlsURL = apiKey.isEmpty ? nil
            : sceneStreams.first(where: { $0.isHLS }).flatMap { appendingAPIKey(apiKey, to: $0.url) }

        // A file we transcoded on-device is normalised to hvc1/avc1 MP4 → direct play, no remux.
        if nativeMP4 {
            return PlaybackRoute(url: localURL, engine: .avPlayer, streamType: "Downloaded",
                                 reason: "Direct play (transcoded)", fallbackURL: hlsURL)
        }

        let isH264 = codec.map { c in Self.directPlayCodecs.contains { c.contains($0) } } ?? false
        let isAV1 = codec.map { c in Self.av1Codecs.contains { c.contains($0) } } ?? false
        let isHEVC = codec.map { c in Self.remuxableCodecs.contains { c.contains($0) } } ?? false
        let av1Native = isAV1 && DeviceCapabilities.av1HardwareDecode
        let isDirectClass = isH264 || av1Native

        // Direct-playable local file (H.264 / native-AV1 in a native container).
        if isDirectClass, containerOK {
            return PlaybackRoute(url: localURL, engine: .avPlayer, streamType: "Downloaded",
                                 reason: "Direct play (offline)", fallbackURL: av1Native ? hlsURL : nil)
        }
        // HEVC (any container → hvc1) or a native codec in a foreign container → on-device remux of the
        // local file; falls back to server HLS if we're online.
        if isHEVC || (isDirectClass && !containerOK) {
            let why = isHEVC ? "\(codec ?? "?") → hvc1 remux (offline)" : "container .\(container) → remux (offline)"
            return PlaybackRoute(url: localURL, engine: .localFFmpeg, streamType: "Downloaded remux",
                                 reason: why, fallbackURL: hlsURL, duration: files.first?.duration ?? 0)
        }
        // Codec AVPlayer can't decode at all → best-effort direct (may fail) with server HLS fallback.
        return PlaybackRoute(url: localURL, engine: .avPlayer, streamType: "Downloaded",
                             reason: "Offline (codec may need transcode)", fallbackURL: hlsURL)
    }

    /// Manual **server-side** transcode at a chosen resolution — the M-B "gear" override, forcing the
    /// Stash HLS stream (a cellular / limited-bandwidth escape hatch). Returns nil if the server has no
    /// HLS stream for the scene.
    func serverQualityRoute(quality: ServerQuality, apiKey: String) -> PlaybackRoute? {
        guard let base = sceneStreams.first(where: { $0.isHLS })?.url,
              let withKey = appendingAPIKey(apiKey, to: base),
              var comps = URLComponents(url: withKey, resolvingAgainstBaseURL: false) else { return nil }
        // Stash's own HLS stream URL already carries `resolution=ORIGINAL`. Appending our choice made a
        // DUPLICATE (`resolution=ORIGINAL&…&resolution=<pick>`), and Stash's `Form.Get("resolution")`
        // reads the FIRST value — so the pick was silently ignored and playback stayed at the server's
        // default. Replace any existing `resolution` with the single chosen one.
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "resolution" }
        if let res = quality.stashResolution {
            items.append(URLQueryItem(name: "resolution", value: res))
        }
        comps.queryItems = items
        guard let hls = comps.url else { return nil }
        return PlaybackRoute(url: hls, engine: .avPlayer, streamType: "HLS · \(quality.label)",
                             reason: "Manual server quality", duration: files.first?.duration ?? 0)
    }

    /// Progressive server-transcoded **download** URL: Stash's `/scene/{id}/stream.mp4?resolution=…`, a live
    /// H.264/AAC MP4 (iPhone-native). Derived from the HLS stream URL by swapping the `.m3u8` path suffix
    /// for `.mp4`. Stash's live transcode is H.264-only (no HEVC) and has no per-request quality knob — only
    /// resolution — so `ServerQuality` here selects resolution only. Returns nil if no HLS stream is known.
    func serverTranscodeDownloadURL(resolution: ServerQuality, apiKey: String) -> URL? {
        guard let base = sceneStreams.first(where: { $0.isHLS })?.url,
              let withKey = appendingAPIKey(apiKey, to: base),
              var comps = URLComponents(url: withKey, resolvingAgainstBaseURL: false),
              comps.path.hasSuffix(".m3u8") else { return nil }
        comps.path = String(comps.path.dropLast(5)) + ".mp4"   // "stream.m3u8" → "stream.mp4"
        var items = comps.queryItems ?? []
        items.removeAll { $0.name == "resolution" }
        if let res = resolution.stashResolution {
            items.append(URLQueryItem(name: "resolution", value: res))
        }
        comps.queryItems = items
        return comps.url
    }

    /// The direct (non-HLS/DASH) file stream URL — the actual media file the FFmpeg pipeline reads,
    /// used by the demux probe and (later) the on-device remux/transcode path.
    func directFileURL(apiKey: String) -> URL? {
        let direct = sceneStreams.first { !$0.isHLS && !$0.isDASH } ?? sceneStreams.first
        guard let urlString = direct?.url else { return nil }
        return appendingAPIKey(apiKey, to: urlString)
    }

    /// Absolute URL (same scheme/host/port as this scene's streams, with the API key) for a file the
    /// Stashy Companion plugin serves at a `/plugin/<id>/assets/…` path. The plugin records that path on
    /// the scene's custom_fields after a transcode; the app turns it into a downloadable URL here.
    func companionFileURL(path: String, apiKey: String) -> URL? {
        guard let base = sceneStreams.first?.url,
              var comps = URLComponents(string: base) else { return nil }
        comps.path = path
        comps.fragment = nil
        var items = (comps.queryItems ?? []).filter { $0.name != "apikey" && $0.name != "resolution" }
        if !apiKey.isEmpty { items.append(URLQueryItem(name: "apikey", value: apiKey)) }
        comps.queryItems = items.isEmpty ? nil : items
        return comps.url
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

    /// Numeric source frame rate (fps) from the primary file — used by the Stats overlay's decode-health
    /// row to compare what the decoder is actually presenting against what the file should deliver.
    var sourceFrameRate: Double? {
        guard let fr = files.first?.frame_rate, fr > 0 else { return nil }
        return fr
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

    /// Return a copy with the primary file's media specs replaced — used after an on-device transcode
    /// rewrites the offline file in place, so the detail view and player stats reflect the transcoded
    /// output (new container/codec/resolution/size) instead of the original's. Duration and frame rate
    /// are preserved from the source. All model fields are `let`, so this reconstructs rather than mutates.
    func replacingPrimaryFileSpecs(container: String, codec: String?, width: Int?, height: Int?,
                                   bitRate: Int?, size: Int?) -> StashScene {
        guard let first = files.first else { return self }
        let newName: String? = first.basename.map { name in
            if let dot = name.lastIndex(of: ".") { return String(name[..<dot]) + "." + container }
            return name + "." + container
        }
        let updatedFile = SceneFile(duration: first.duration, video_codec: codec, width: width,
                                    height: height, basename: newName, size: size, bit_rate: bitRate,
                                    frame_rate: first.frame_rate)
        var updatedFiles = files
        updatedFiles[0] = updatedFile
        return StashScene(id: id, title: title, date: date, rating100: rating100, files: updatedFiles,
                          paths: paths, studio: studio, performers: performers, tags: tags,
                          sceneStreams: sceneStreams)
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
