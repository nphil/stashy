import Foundation

/// The scene→route decision, extracted verbatim from `SceneDetailView` so the glasses-first player can
/// resolve playback without a detail view on screen. Precedence is unchanged and load-bearing:
/// manual server-quality override → completed local download (through the same codec/container
/// capability check as streaming, so a downloaded HEVC/foreign-container file goes through the
/// on-device remux instead of a bare AVPlayer that can't decode it) → normal server routing.
@MainActor
enum PlaybackRouteResolver {
    static func resolve(scene: StashScene, quality: ServerQuality,
                        client: StashClient?, downloads: DownloadManager) -> PlaybackRoute? {
        if quality != .auto, let client,
           let q = scene.serverQualityRoute(quality: quality, apiKey: client.apiKey) {
            return q
        }
        if let local = downloads.localFile(sceneID: scene.id) {
            return scene.localPlaybackRoute(localURL: local, apiKey: client?.apiKey ?? "",
                                            nativeMP4: downloads.wasTranscoded(sceneID: scene.id))
        }
        guard let client else { return nil }
        return scene.playbackRoute(apiKey: client.apiKey,
                                   pluginNeedsTranscode: PlayabilityStore.shared.needsTranscode(scene.id))
    }
}
