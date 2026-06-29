import SwiftUI
import AVFoundation

/// A scene card in the grid. Tapping navigates to the scene. The card plays the Stash preview clip
/// in place (muted, looping) over its thumbnail. Once a preview is playing it keeps playing through
/// scrolling — it's never paused or swapped back to the thumbnail, so videos don't visibly restart
/// when you stop. To keep fast flicks smooth, *new* players aren't created while flinging quickly;
/// those cells show their thumbnail and begin playing when the scroll slows or stops. Preview files
/// come from `PreviewCache` (local disk) so playback starts instantly with no buffering stall, and
/// the thumbnail sits under a transparent player layer so there's no black flash.
struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    @Binding var isFastScrolling: Bool
    @Binding var path: NavigationPath
    var onAppear: () -> Void

    @Environment(\.previewCache) private var previewCache
    @AppStorage("animatedPreviews") private var animatedPreviews = true
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        SceneCard(scene: scene, apiKey: apiKey, player: animatedPreviews ? player : nil)
            .onTapGesture { path.append(scene) }
            .onAppear {
                onAppear()
                startPreviewIfNeeded()
            }
            // When a fast flick settles, start previews for cells that deferred creation.
            .onChange(of: isFastScrolling) { _, fast in
                if !fast { startPreviewIfNeeded() }
            }
            .onChange(of: animatedPreviews) { _, on in
                if on { startPreviewIfNeeded() } else { teardown() }
            }
            .onDisappear { teardown() }
    }

    private func startPreviewIfNeeded() {
        // Already playing, previews off, or flinging too fast to reasonably load — skip. Crucially
        // we never pause an existing player, so playback is continuous and never restarts on stop.
        guard animatedPreviews, player == nil, !isFastScrolling else { return }
        guard let remote = scene.previewURL(apiKey: apiKey) else { return }
        Task {
            guard let local = await previewCache.localURL(for: remote) else { return }
            // Re-check after the (possibly slow) download: don't create if state changed meanwhile.
            guard animatedPreviews, player == nil, !isFastScrolling else { return }
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
