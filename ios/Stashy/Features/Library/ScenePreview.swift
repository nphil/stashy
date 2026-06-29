import SwiftUI
import AVFoundation

/// A scene card in the grid. Tapping navigates to the scene. The grid always shows static
/// (downsampled, cached) thumbnails for smooth scrolling at any speed — preview video is only
/// shown on press-and-hold, via a native context menu so we get the standard long-press delay,
/// haptic, elevation, and dimmed background for free. The preview clip is cropped to fill (no
/// black bars) and served from `PreviewCache` (local disk) so it starts quickly.
struct SceneGridCell: View {
    let scene: StashScene
    let apiKey: String
    @Binding var path: NavigationPath
    var onAppear: () -> Void

    @AppStorage("animatedPreviews") private var animatedPreviews = true

    var body: some View {
        SceneCard(scene: scene, apiKey: apiKey)
            .onTapGesture { path.append(scene) }
            .modifier(ScenePreviewMenu(scene: scene, apiKey: apiKey, enabled: animatedPreviews, path: $path))
            .onAppear(perform: onAppear)
    }
}

/// Adds the press-and-hold preview menu when previews are enabled; otherwise leaves the card alone.
private struct ScenePreviewMenu: ViewModifier {
    let scene: StashScene
    let apiKey: String
    let enabled: Bool
    @Binding var path: NavigationPath

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu {
                Button { path.append(scene) } label: {
                    Label("Open Scene", systemImage: "play.rectangle.fill")
                }
            } preview: {
                ScenePreviewPopup(scene: scene, apiKey: apiKey)
            }
        } else {
            content
        }
    }
}

/// Looping, muted preview clip shown inside the long-press menu. Sized 16:9 and filled (cropped),
/// so any letterboxing in the source is trimmed rather than shown as black bars.
private struct ScenePreviewPopup: View {
    let scene: StashScene
    let apiKey: String
    @Environment(\.previewCache) private var previewCache
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    private let width: CGFloat = 340
    private var height: CGFloat { width * 9 / 16 }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerLayerView(player: player) // .resizeAspectFill crops to the frame (no bars)
            }
        }
        .frame(width: width, height: height)
        .task {
            guard let remote = scene.previewURL(apiKey: apiKey),
                  let local = await previewCache.localURL(for: remote) else { return }
            let item = AVPlayerItem(url: local)
            let queue = AVQueuePlayer()
            queue.isMuted = true
            queue.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            queue.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
            looper = nil
        }
    }
}
