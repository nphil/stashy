import Foundation

/// Remembers, per stream, whether Apple's decoder can't handle the pixel format (so the file needs
/// transcode rather than remux). Persisted in UserDefaults so each file is probed at most once, ever —
/// every repeat open is then an instant routing decision with no probe delay.
@MainActor
final class AppleDecodeCache {
    static let shared = AppleDecodeCache()

    private let defaultsKey = "stashy.needsTranscodeByStream"
    private var map: [String: Bool]

    private init() {
        map = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool]) ?? [:]
    }

    /// `true` = needs transcode (Apple can't decode), `false` = remux is fine, `nil` = not yet probed.
    func decision(forKey key: String) -> Bool? { map[key] }

    func setDecision(_ needsTranscode: Bool, forKey key: String) {
        guard map[key] != needsTranscode else { return }
        map[key] = needsTranscode
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }
}
