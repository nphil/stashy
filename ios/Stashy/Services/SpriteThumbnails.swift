import UIKit

/// Loads a Stash scene's sprite sheet + WebVTT index and produces scrub-preview
/// thumbnails by cropping the sprite for the cue covering a given time. No video
/// decoding — instant previews that match the speed priority.
@MainActor
final class SpriteThumbnails {
    struct Cue {
        let start: TimeInterval
        let end: TimeInterval
        let rect: CGRect
    }

    private var cues: [Cue] = []
    private var sprite: UIImage?
    private var cropCache: [Int: UIImage] = [:]
    private(set) var isReady = false

    func load(vttURL: URL, spriteURL: URL, imageCache: ImageCache) async {
        let parsed = await Self.fetchCues(vttURL)
        let image = try? await imageCache.image(for: spriteURL)
        sprite = image
        cues = parsed
        isReady = sprite != nil && !cues.isEmpty
    }

    /// Cropped sprite tile for the cue covering `time` (clamped to the last cue).
    func thumbnail(at time: TimeInterval) -> UIImage? {
        guard let sprite, !cues.isEmpty else { return nil }
        let index = cues.firstIndex { time >= $0.start && time < $0.end } ?? cues.count - 1
        if let cached = cropCache[index] { return cached }
        let rect = cues[index].rect
        guard let cropped = sprite.cgImage?.cropping(to: rect) else { return nil }
        let image = UIImage(cgImage: cropped)
        cropCache[index] = image
        return image
    }

    // MARK: - Parsing

    private static func fetchCues(_ url: URL) async -> [Cue] {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ vtt: String) -> [Cue] {
        var cues: [Cue] = []
        let lines = vtt.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            if lines[i].contains("-->") {
                let times = lines[i].components(separatedBy: "-->")
                if times.count == 2,
                   let start = parseTimestamp(times[0]),
                   let end = parseTimestamp(times[1]) {
                    var j = i + 1
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count, let rect = parseXYWH(lines[j]) {
                        cues.append(Cue(start: start, end: end, rect: rect))
                    }
                    i = j
                }
            }
            i += 1
        }
        return cues
    }

    /// Parses "HH:MM:SS.mmm" or "MM:SS.mmm" into seconds.
    static func parseTimestamp(_ string: String) -> TimeInterval? {
        let parts = string.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        let nums = parts.compactMap { Double($0) }
        guard nums.count == parts.count, !nums.isEmpty else { return nil }
        switch nums.count {
        case 3: return nums[0] * 3600 + nums[1] * 60 + nums[2]
        case 2: return nums[0] * 60 + nums[1]
        case 1: return nums[0]
        default: return nil
        }
    }

    /// Parses a `…#xywh=x,y,w,h` fragment into a pixel CGRect.
    static func parseXYWH(_ string: String) -> CGRect? {
        guard let range = string.range(of: "xywh=") else { return nil }
        let nums = string[range.upperBound...]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }
}
