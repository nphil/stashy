import SwiftUI
import AVFoundation

/// A scene card in the grid. Tapping navigates to the scene. When the grid is at rest the card
/// plays the Stash preview clip in place (muted, looping) over its thumbnail; while the grid is
/// scrolling only the static thumbnail is shown. Decoding several videos during a scroll competes
/// for GPU/CPU/memory bandwidth and drops frames, so pausing playback while scrolling is what keeps
/// scrolling smooth. The preview file is served from `PreviewCache` (local disk) so playback starts
/// instantly with no buffering stall, and the thumbnail sits under a transparent player layer so
/// there's no black flash before the first frame.
struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    @Binding var isScrolling: Bool
    @Binding var path: NavigationPath
    var onAppear: () -> Void

    @Environment(\.previewCache) private var previewCache
    @AppStorage("animatedPreviews") private var animatedPreviews = true
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        SceneCard(scene: scene, apiKey: apiKey, player: (animatedPreviews && !isScrolling) ? player : nil)
            .onTapGesture { path.append(scene) }
            .onAppear {
                onAppear()
                updatePlayback()
            }
            .onChange(of: isScrolling) { _, _ in updatePlayback() }
            .onChange(of: animatedPreviews) { _, _ in updatePlayback() }
            .onDisappear { teardown() }
    }

    private func updatePlayback() {
        guard animatedPreviews else { teardown(); return }
        if isScrolling {
            player?.pause()
        } else {
            playPreview()
        }
    }

    private func playPreview() {
        if let player {
            player.play()
            return
        }
        guard let remote = scene.previewURL(apiKey: apiKey) else { return }
        Task {
            guard let local = await previewCache.localURL(for: remote) else { return }
            // Bail if scrolling resumed, previews were disabled, or another task already built the
            // player while downloading.
            guard !isScrolling, animatedPreviews, player == nil else { return }
            let item = AVPlayerItem(url: local)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            // Local file: don't pause to "minimize stalling" at the loop boundary — that re-check
            // is what causes the brief hitch between loops. Off => AVPlayerLooper is gapless.
            queue.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            queue.play()
        }
    }

    private func teardown() {
        player?.pause()
        player = nil
        looper = nil
    }
}
